# W-fit backend

.NET 10 isolated-worker Azure Functions API (ASP.NET Core integration) + xUnit tests. Contract: [`docs/API.md`](../docs/API.md).

## Structure
```
backend/
  WFit.sln
  dotnet-tools.json                 # local dotnet-ef tool
  src/WFit.Api/
    Program.cs                      # DI, JSON, logging, App Insights, EF Core (SQL Server, retry, 90 s timeout)
    host.json                       # sampling on (Request excluded), default log level Warning
    local.settings.sample.json      # copy to local.settings.json (git-ignored)
    Functions/                      # HTTP triggers: health, sync, ai/workout, ai/swap, ai/insights, ai/usage
    Infrastructure/                 # API-key middleware (+ lazy migrate/seed, error mapping), JSON options, results
    Data/                           # DbContext, entities, DatabaseInitializer (migrate + catalog seed), Migrations/
    Domain/                         # Catalog (embedded app/assets/data/catalog.json), vocabulary, ExerciseSelector
    Sync/                           # Sync DTOs, mapper, last-write-wins SyncService
    Ai/                             # Azure OpenAI client (IAiClient), limiter, prompts, schemas, validators, services
  tests/WFit.Api.Tests/             # xUnit (EF Core InMemory, fake IAiClient)
```

The exercise catalog is **not copied**: `app/assets/data/catalog.json` is embedded at build time (`LogicalName=catalog.json`)
and upserted into `CatalogExercises` / `CatalogEquipment` whenever its `version` differs from `AppMeta.catalogVersion`.
Migrations are applied lazily on the first authenticated request (`/health` never touches SQL).

## Run locally
Prerequisites: .NET SDK 10, [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local),
a SQL Server (LocalDB works) and optionally an Azure OpenAI deployment you can reach with `az login` (DefaultAzureCredential).

```powershell
cd backend\src\WFit.Api
Copy-Item local.settings.sample.json local.settings.json   # then edit values
func start
curl http://localhost:7071/api/health
curl -H "X-Api-Key: <local-dev-api-key>" http://localhost:7071/api/ai/usage
```

## Tests
```powershell
dotnet test backend\WFit.sln
```

## Migrations
```powershell
cd backend
dotnet tool restore
dotnet ef migrations add <Name> --project src\WFit.Api --output-dir Data\Migrations
```

## App settings
| Setting | Default | Purpose |
|---|---|---|
| `WFIT_API_KEY` | — (required) | Expected `X-Api-Key` value (Key Vault reference in Azure). Unset ⇒ every endpoint except `health` returns 401. |
| `SQL_CONNECTION_STRING` | — (required) | Azure SQL; production uses `Authentication=Active Directory Default` (managed identity). |
| `AZURE_OPENAI_ENDPOINT` | — | Azure OpenAI endpoint (Entra ID auth via `DefaultAzureCredential`; set `AZURE_CLIENT_ID` for a user-assigned identity). |
| `AZURE_OPENAI_DEPLOYMENT` | `gpt-4.1-mini` | Chat deployment name. |
| `AI_ENABLED` | `true` | Kill switch (`false` ⇒ 503 `ai_disabled`). |
| `AI_DAILY_CALL_LIMIT` | `25` | Max AI calls per UTC day (⇒ 429 `ai_limit_reached`). |
| `AI_MONTHLY_TOKEN_LIMIT` | `2000000` | Max input+output tokens per calendar month (UTC). |
| `AI_MAX_OUTPUT_TOKENS` | `1800` | Per-call output token cap. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | — | Telemetry (set by infra). |
| `FUNCTIONS_WORKER_RUNTIME` | `dotnet-isolated` | Functions runtime. |
