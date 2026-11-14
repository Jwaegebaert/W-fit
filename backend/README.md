# W-fit backend

.NET 10 isolated-worker Azure Functions API (ASP.NET Core integration) + xUnit tests. Contract: [`docs/API.md`](../docs/API.md).

## Structure
```
backend/
  WFit.sln
  dotnet-tools.json                 # local dotnet-ef tool
  src/WFit.Api/
    Program.cs                      # DI, JSON, logging, App Insights, EF Core (SQL Server, retry, 90 s timeout), AI + usage store
    host.json                       # sampling on (Request excluded), default log level Warning
    local.settings.sample.json      # copy to local.settings.json (git-ignored)
    Functions/                      # HTTP triggers: health, sync, ai/workout, ai/adjust, ai/swap, ai/insights, ai/usage
    Infrastructure/                 # API-key middleware (+ lazy migrate/seed for /sync only), JSON options, results
    Data/                           # DbContext, entities (incl. FeedbackEntries), DatabaseInitializer, Migrations/
    Domain/                         # Catalog (embedded app/assets/data/catalog.json), Vocab, Anatomy, LimitationFilter, ExerciseSelector
    Sync/                           # Sync DTOs, mapper, last-write-wins SyncService
    Ai/                             # OpenAI client, AiGateway (limits, fallback, telemetry), Table/in-memory usage store,
                                    # coach brief DTOs, prompts, schemas, output validator, workout/adjust/swap/insights services
  tests/WFit.Api.Tests/             # xUnit (EF Core InMemory, fake IAiClient, in-memory/fake Table usage store, live eval)
```

The exercise catalog is **not copied**: `app/assets/data/catalog.json` is embedded at build time (`LogicalName=catalog.json`)
and upserted into `CatalogExercises` / `CatalogEquipment` (incl. v3 `stress`) whenever its `version` differs from
`AppMeta.catalogVersion`. Migrations are applied lazily on the first `/sync` request — `/health` and the AI endpoints
never touch SQL.

## AI coach (stateless)
- The app sends a **coach brief** (profile, equipment, preferences, limitations, feedback, program, muscle balance,
  exercise history, recent sessions) with every AI request; the server never reads training data from SQL.
- `Domain/LimitationFilter` mirrors the app's limitation policy (IMPROVEMENT-PLAN §4.3) on top of equipment, bans and
  difficulty, so excluded exercises never reach the model; `Ai/AiOutputValidator` re-checks every id, clamps
  prescriptions (≤ 3 sets on deload weeks) and validates plan meta and feedback.
- Model: Azure OpenAI v1 API via the OpenAI .NET SDK — `gpt-6-sol` (reasoning effort low; medium for insights), one
  fallback attempt on `gpt-6-luna` for 429 / 5xx / network errors / timeouts. Structured outputs (strict JSON schema),
  `max_completion_tokens` 8000, no temperature (reasoning models). Every call logs model, effort, latency and tokens
  (in / out / reasoning) to Application Insights (`AI {Schema}: model=… effort=… latencyMs=… in=… out=… reasoning=…`).
- Usage limits (calls per UTC day, tokens per UTC month) are stored in Azure Table Storage (`aiusage`, PartitionKey
  `usage`, RowKey `yyyy-MM-dd`, ETag optimistic concurrency) — always warm and practically free.

## Run locally
Prerequisites: .NET SDK 10, [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local),
a SQL Server (LocalDB works) for `/sync` and optionally access to the Azure OpenAI deployments with `az login`
(`DefaultAzureCredential`; managed identity is skipped when `AZURE_FUNCTIONS_ENVIRONMENT=Development`).
Without `AZURE_STORAGE_TABLE_ENDPOINT` the usage counters are kept in memory.

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

### Live AI evaluation
`LiveCoachEvalTests` runs five scenario briefs against the real model (neck pain on a push day, biceps deficit on a pull
day, stalled anchor lift, deload week, `/ai/adjust` "the leg press is broken and my left knee feels a bit sore") and
asserts the hard constraints plus that the rationale addresses the scenario. They are skipped unless `WFIT_LIVE_AI=1`;
authentication uses `DefaultAzureCredential` (developer credentials, e.g. `az login`; the account needs
*Cognitive Services OpenAI User*). Latency and tokens are printed per scenario (≈ 10–15 s, ≈ 5.5k in / 1k out each).

```powershell
$env:WFIT_LIVE_AI = "1"
$env:AZURE_OPENAI_ENDPOINT = "https://<your-openai-account>.openai.azure.com/"
# optional: $env:AZURE_OPENAI_DEPLOYMENT = "gpt-6-luna"
dotnet test backend\WFit.sln --filter "FullyQualifiedName~LiveCoachEvalTests" --logger "console;verbosity=detailed"
```

## Migrations
```powershell
cd backend
dotnet tool restore
dotnet ef migrations add <Name> --project src\WFit.Api --output-dir Data\Migrations
```
`MigrationTests` fails when the model has changes that are missing from the migrations. Latest: `CoachV3` (adds
`FeedbackEntries`, `PlannedWorkouts.Meta`, `CatalogExercises.Stress`; drops the unused `AiUsage` and `InsightsCache`).

## App settings
| Setting | Default | Purpose |
|---|---|---|
| `WFIT_API_KEY` | — (required) | Expected `X-Api-Key` value (Key Vault reference in Azure). Unset ⇒ every endpoint except `health` returns 401. |
| `SQL_CONNECTION_STRING` | — (required for `/sync`) | Azure SQL; production uses `Authentication=Active Directory Managed Identity`. |
| `AZURE_OPENAI_ENDPOINT` | — | Azure OpenAI resource endpoint; the client calls `{endpoint}/openai/v1` with Entra ID (`DefaultAzureCredential`). |
| `AZURE_OPENAI_DEPLOYMENT` | `gpt-6-sol` | Primary deployment. |
| `AZURE_OPENAI_FALLBACK_DEPLOYMENT` | `gpt-6-luna` | Fallback deployment (used once on 429 / 5xx / timeout); empty or `none` disables it. |
| `AZURE_STORAGE_TABLE_ENDPOINT` | from `AzureWebJobsStorage__accountName` | Table endpoint for usage counters (table `aiusage`); neither set ⇒ in-memory store. |
| `AI_ENABLED` | `true` | Kill switch (`false` ⇒ 503 `ai_disabled`). |
| `AI_DAILY_CALL_LIMIT` | `40` | Max AI calls per UTC day (⇒ 429 `ai_limit_reached`). |
| `AI_MONTHLY_TOKEN_LIMIT` | `3000000` | Max input + output tokens per calendar month (UTC). |
| `AI_MAX_OUTPUT_TOKENS` | `8000` | `max_completion_tokens` per call (includes reasoning tokens). |
| `AI_CALL_TIMEOUT_SECONDS` | `60` | Per-attempt model timeout (5–300). |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | — | Telemetry (set by infra). |
| `FUNCTIONS_WORKER_RUNTIME` | `dotnet-isolated` | Functions runtime. |
