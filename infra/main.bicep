// W-fit infrastructure — single resource group, scale-to-zero, passwordless.
// Expected cost: ~$0.20–1.20/month (see docs/COSTS.md). Hard cap target: $50/month.
targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Region for Azure SQL (West/North Europe currently reject new SQL servers on this subscription; Sweden Central accepts them).')
param sqlLocation string = 'swedencentral'

@description('Short suffix to make global names unique.')
param suffix string = take(uniqueString(resourceGroup().id), 6)

@description('Object ID of the Entra user that administers the SQL server (the deployer).')
param sqlAdminObjectId string

@description('UPN / display login of the SQL Entra admin.')
param sqlAdminLogin string

@secure()
@description('API key the mobile app sends in X-Api-Key. Stored only in Key Vault.')
param apiKey string

@description('Optional public IP allowed through the SQL firewall (deployment-time T-SQL). Empty = none.')
param clientIp string = ''

@description('Primary chat deployment for the AI coach (reasoning model; the deployment is named after the model).')
param openAiPrimaryModelName string = 'gpt-6-sol'
param openAiPrimaryModelVersion string = '2026-09-22'

@description('Fallback deployment, used once when the primary is throttled (429), fails (5xx) or times out.')
param openAiFallbackModelName string = 'gpt-6-luna'
param openAiFallbackModelVersion string = '2026-09-22'

@description('Deployment SKU. DataZoneStandard keeps inference inside the EU data zone.')
param openAiSku string = 'DataZoneStandard'

@description('Tokens-per-minute capacity in thousands, per deployment. A platform-level throttle on AI spend.')
@minValue(1)
@maxValue(50)
param openAiCapacity int = 50

@description('Model version upgrade policy (matches the existing deployments so redeploying is a no-op).')
@allowed(['OnceNewDefaultVersionAvailable', 'OnceCurrentVersionExpired', 'NoAutoUpgrade'])
param openAiVersionUpgradeOption string = 'OnceNewDefaultVersionAvailable'

@description('Application-level AI limits (cost safeguards).')
param aiDailyCallLimit int = 40
param aiMonthlyTokenLimit int = 3000000
@description('max_completion_tokens per call; includes reasoning tokens.')
param aiMaxOutputTokens int = 8000
@description('Per-attempt model timeout in seconds (the fallback attempt gets its own).')
param aiCallTimeoutSeconds int = 60

@description('Monthly budget in USD for this resource group.')
param budgetAmount int = 50

@description('E-mail address for budget alerts.')
param alertEmail string

@description('First day of the current month (budget start).')
param budgetStartDate string = utcNow('yyyy-MM-01')

var tags = {
  app: 'w-fit'
  costCenter: 'personal'
}
var names = {
  log: 'log-wfit-${suffix}'
  appi: 'appi-wfit-${suffix}'
  storage: 'stwfit${suffix}'
  plan: 'plan-wfit-${suffix}'
  func: 'func-wfit-${suffix}'
  kv: 'kv-wfit-${suffix}'
  sql: 'sql-wfit-${take(uniqueString(resourceGroup().id, sqlLocation), 6)}'
  db: 'wfit'
  openai: 'oai-wfit-${suffix}'
}
var deploymentContainer = 'app-package'
var aiUsageTableName = 'aiusage'

// ---------------- Monitoring (capped ingestion) ----------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.log
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appi
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
    SamplingPercentage: 50
    DisableLocalAuth: false
  }
}

// ---------------- Storage (Functions host + deployment package, identity-only) ----------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: names.storage
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainer
}

// AI usage counters (calls / tokens per UTC day) — always warm, so the stateless AI endpoints never touch SQL.
resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource aiUsageTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: aiUsageTableName
}

// ---------------- Azure OpenAI (pay-per-token, no fixed cost) ----------------
resource openai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: names.openai
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: names.openai
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

// Reasoning models: gpt-6-sol (primary, low effort for interactive calls) and gpt-6-luna (fallback).
// Deployments on one account must not be written concurrently, hence the dependsOn chain.
resource primaryDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openai
  name: openAiPrimaryModelName
  sku: {
    name: openAiSku
    capacity: openAiCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: openAiPrimaryModelName
      version: openAiPrimaryModelVersion
    }
    versionUpgradeOption: openAiVersionUpgradeOption
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

resource fallbackDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openai
  name: openAiFallbackModelName
  sku: {
    name: openAiSku
    capacity: openAiCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: openAiFallbackModelName
      version: openAiFallbackModelVersion
    }
    versionUpgradeOption: openAiVersionUpgradeOption
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [primaryDeployment]
}

// ---------------- Key Vault (API key) ----------------
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: names.kv
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource apiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'wfit-api-key'
  properties: {
    value: apiKey
    contentType: 'W-fit mobile app API key'
  }
}

// ---------------- Azure SQL (free offer, cannot bill: AutoPause on exhaustion) ----------------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: names.sql
  location: sqlLocation
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: subscription().tenantId
      principalType: 'User'
    }
  }
}

resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlAllowClient 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (!empty(clientIp)) {
  parent: sqlServer
  name: 'deployer'
  properties: {
    startIpAddress: clientIp
    endIpAddress: clientIp
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: names.db
  location: sqlLocation
  tags: tags
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
    requestedBackupStorageRedundancy: 'Local'
    zoneRedundant: false
  }
}

// ---------------- Functions (Flex Consumption, scale to zero) ----------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: names.plan
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: names.func
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 2
        instanceMemoryMB: 512
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'WFIT_API_KEY', value: '@Microsoft.KeyVault(VaultName=${vault.name};SecretName=${apiKeySecret.name})' }
        {
          name: 'SQL_CONNECTION_STRING'
          value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${names.db};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connect Timeout=90;'
        }
        { name: 'AZURE_OPENAI_ENDPOINT', value: openai.properties.endpoint }
        { name: 'AZURE_OPENAI_DEPLOYMENT', value: primaryDeployment.name }
        { name: 'AZURE_OPENAI_FALLBACK_DEPLOYMENT', value: fallbackDeployment.name }
        { name: 'AZURE_STORAGE_TABLE_ENDPOINT', value: storage.properties.primaryEndpoints.table }
        { name: 'AI_ENABLED', value: 'true' }
        { name: 'AI_DAILY_CALL_LIMIT', value: string(aiDailyCallLimit) }
        { name: 'AI_MONTHLY_TOKEN_LIMIT', value: string(aiMonthlyTokenLimit) }
        { name: 'AI_MAX_OUTPUT_TOKENS', value: string(aiMaxOutputTokens) }
        { name: 'AI_CALL_TIMEOUT_SECONDS', value: string(aiCallTimeoutSeconds) }
      ]
    }
  }
}

// ---------------- RBAC for the Function App's managed identity ----------------
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  openAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

resource funcStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, func.id, roles.storageBlobDataOwner)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataOwner)
  }
}

// AI usage counters in Table Storage (aiusage).
resource funcTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, func.id, roles.storageTableDataContributor)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageTableDataContributor)
  }
}

resource funcVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, func.id, roles.keyVaultSecretsUser)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
  }
}

resource funcOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: openai
  name: guid(openai.id, func.id, roles.openAiUser)
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.openAiUser)
  }
}

// The deployer can read the API key (to configure the phone) and keep it stable across redeployments.
resource deployerVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, sqlAdminObjectId, roles.keyVaultSecretsOfficer)
  properties: {
    principalId: sqlAdminObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
  }
}

// ---------------- Budget (alerts only — app-level limits do the actual capping) ----------------
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-wfit-monthly'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    notifications: {
      actual20: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 20
        thresholdType: 'Actual'
        contactEmails: [alertEmail]
        contactRoles: ['Owner']
      }
      actual50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [alertEmail]
        contactRoles: ['Owner']
      }
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [alertEmail]
        contactRoles: ['Owner']
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [alertEmail]
        contactRoles: ['Owner']
      }
    }
  }
}

output functionAppName string = func.name
output apiBaseUrl string = 'https://${func.properties.defaultHostName}/api'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = names.db
output keyVaultName string = vault.name
output openAiEndpoint string = openai.properties.endpoint
output openAiAccountName string = openai.name
output openAiDeployments array = [primaryDeployment.name, fallbackDeployment.name]
output aiUsageTableEndpoint string = '${storage.properties.primaryEndpoints.table}${aiUsageTable.name}'
