# W-fit: personal AI fitness coach

W-fit is a personal Android training companion built around a beginner-friendly **Push / Pull / Legs** programme
(3× per week, ~60 min including warm-up and cool-down). Goals: get leaner, stronger and more flexible, and get better at
badminton (mobility, explosiveness, stability, injury prevention).

- **Guided workouts.** Warm-up → main lifts → optional core → cool-down (3 stretches). Every exercise shows sets, reps,
  rest, instructions, tips, common mistakes, muscles, badminton benefit and a demo-video link. Plans suit a
  machine-heavy gym with little floor space: standing / station drills are preferred and each warm-up, core block and
  cool-down uses at most one floor exercise; warm-up cardio rotates between the available machines.
- **Built-in visuals.** Exercise screens show an animated start/end demo (photos for 86 exercises from the
  public-domain [free-exercise-db](https://github.com/yuhonas/free-exercise-db)), and tapping a piece of equipment
  shows a line drawing of it. List icons show what you train with (machine, cable, dumbbell, barbell, …).
- **Gym equipment.** Switch off what your gym lacks, or start from a *Quick setup* preset ("Classic machine gym":
  everything except medicine ball, foam roller, jump rope and rowing machine; or "Everything available").
- **Live tracking.** Log weight and reps per set. Weights are pre-filled from your history (double progression).
  Rest timers and timed-exercise timers run automatically, and the screen stays awake.
- **Instant swaps.** Choose *Occupied* (avoided for this visit only), *Not in my gym* (permanently removed from
  plans) or *Prefer another* (disliked or banned). You get equivalent exercises right away, and can optionally ask the
  AI coach for its picks.
- **AI coach (Azure OpenAI).** It generates workouts from your goals, equipment, preferences and recent sessions,
  suggests swaps and writes progress insights. Its output is limited to the exercise catalog and checked against
  beginner-safe limits.
- **Statistics.** History, automatic PRs (heaviest set, estimated 1RM, reps), consistency and volume charts,
  per-exercise progress, muscle focus, and body weight plus optional measurements.
- **Offline-first.** Everything works without network or AI. Data lives in SQLite on the phone and syncs to Azure
  SQL when a connection is available.

## Architecture

```
Flutter app (Android) ──HTTPS + X-Api-Key──▶ Azure Functions (.NET 10, Flex Consumption)
  drift/SQLite, rule engine                    ├─ EF Core ─▶ Azure SQL (free offer, serverless)
  Riverpod, fl_chart                           └─ Entra ID ─▶ Azure OpenAI gpt-4.1-mini (EU data zone)
```

| Path | Contents |
|---|---|
| [app/](app/) | Flutter app: `lib/domain` (catalog, rule engine, progression, stats), `lib/data` (drift DB, repository, API client, sync), `lib/features/*` (screens), `lib/services/coach_service.dart` |
| [backend/](backend/) | Azure Functions API, EF Core migrations, xUnit tests (see [backend/README.md](backend/README.md)) |
| [infra/](infra/) | [main.bicep](infra/main.bicep) and [deploy.ps1](infra/deploy.ps1) |
| [app/assets/data/catalog.json](app/assets/data/catalog.json) | Single source of truth (v2): 34 equipment types (each with a short "how to recognise it" description) and 126 exercises with instructions, tips and common mistakes (embedded in the backend at build time) |
| `app/assets/{exercises,equipment,icons,brand}` | Demo photos + `index.json`, equipment line drawings, equipment-type icons, logo sources |
| [docs/](docs/) | [ARCHITECTURE.md](docs/ARCHITECTURE.md), [API.md](docs/API.md), [COSTS.md](docs/COSTS.md) |

Key design decisions are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md):
- **AI is optional.** On-device rules generate, progress and swap workouts. AI only enhances them.
- **Sync** is one `POST /sync` call that pushes and pulls changes, using client-generated GUIDs and last-write-wins.
- **No passwords or keys in Azure.** Managed identity is used for SQL, OpenAI, Storage and Key Vault. The only
  secret is the app's API key, stored in Key Vault and in Android encrypted storage.

## Expected operating cost

**≈ $0.20–1.20 per month** under normal use. Even with every AI limit maxed out, the worst case is ≈ $6, against a hard
budget of $50. The per-resource breakdown is in [docs/COSTS.md](docs/COSTS.md).

| Resource | Tier | $/month |
|---|---|---|
| Azure SQL Database | Free offer, serverless, **AutoPause when the free allowance runs out** (cannot bill) | 0 |
| Azure Functions | Flex Consumption, max 2 instances, scales to zero | 0 (free grant) |
| Azure OpenAI | gpt-4.1-mini, pay per token, 20K TPM, app caps of 25 calls/day and 2M tokens/month | 0.10–0.50 |
| Storage, Key Vault, Log Analytics (0.1 GB/day cap) | Standard | 0.05–0.30 |

A Cost Management budget (`budget-wfit-monthly`, $50) emails you at 20/50/80 % of actual spend and at 100 % of
forecast. Budgets only alert. The application limits above are what actually cap the spend.

## Azure setup and deployment

Requirements: Azure CLI (logged in to the your own tenant), .NET 10 SDK and PowerShell 7.

```powershell
az login
./infra/deploy.ps1 -AlertEmail you@example.com     # provision + deploy + smoke test (idempotent)
./infra/deploy.ps1 -SkipInfra                       # redeploy backend code only
./infra/deploy.ps1 -WhatIf                          # preview infrastructure changes
```

`deploy.ps1` does the following:
1. Creates `<resource-group>` and deploys the Bicep template.
2. Reuses the API key in Key Vault, or generates one on the first run.
3. Creates the Function App's managed-identity user in SQL.
4. Publishes the API and smoke-tests `/health` and `/ai/usage`.

**Current deployment:**
- API: `https://<your-function-app>.azurewebsites.net/api`
- SQL server: `<sql-server>` (Sweden Central, because West and North Europe currently reject new SQL servers)
- Everything else is in West Europe.

Get the API key:
```powershell
az keyvault secret show --vault-name <key-vault> -n wfit-api-key --query value -o tsv
```

### Operating the AI safeguards
These are Function App settings. Change them in the portal or with the CLI:
```powershell
az functionapp config appsettings set -g <resource-group> -n <function-app> --settings AI_ENABLED=false          # kill switch
az functionapp config appsettings set -g <resource-group> -n <function-app> --settings AI_DAILY_CALL_LIMIT=10
```
`AI_MONTHLY_TOKEN_LIMIT` (default 2,000,000) and `AI_MAX_OUTPUT_TOKENS` (default 1,800) work the same way. The app
shows the current usage under **Settings → Backend connection** and on the **Coach** tab.

> **Model lifecycle:** `gpt-4.1-mini` (2025-04-14) is deployable until **April 2027**. Before then, change
> `openAiModelName`/`openAiModelVersion` in `infra/main.bicep` to a newer non-reasoning model. If you move to a
> reasoning model (gpt-5 family), remove `Temperature` from `backend/src/WFit.Api/Ai/AiClient.cs`, because reasoning
> models don't accept it.

## Install the app on your phone

```powershell
cd app
flutter build apk --release --dart-define=WFIT_API_URL=https://<your-function-app>.azurewebsites.net/api
# → app/build/app/outputs/flutter-apk/app-release.apk  (copy to the phone, or: adb install -r <apk>)
```
Open **Settings → Backend connection**, paste the API key (the URL is pre-filled by the dart-define), then tap
**Save & connect**. Without a connection the app runs fully offline.

The release build is signed with the Flutter debug key, which is fine for sideloading a personal app. To create your
own upload key, follow the [Flutter Android signing guide](https://docs.flutter.dev/deployment/android#sign-the-app);
`key.properties` and `*.jks` are already git-ignored.

## Local development

**App**
```powershell
cd app
flutter pub get
dart run build_runner build      # regenerate drift code after changing lib/data/db/database.dart
flutter analyze
flutter test                     # unit tests + full-flow widget test + layout tests at phone sizes (in-memory SQLite)
flutter test test/screenshots_test.dart --dart-define=SCREENSHOTS=true   # optional: PNGs of every screen in %TEMP%\wfit-shots
flutter run                      # needs an Android device/emulator
```
Regenerate assets: `dart run flutter_launcher_icons -f flutter_launcher_icons.yaml` and
`dart run flutter_native_splash:create --path=flutter_native_splash.yaml` (icon/splash, sources in `assets/brand/source/`);
`node tool/fetch_exercise_media.mjs` (demo photos, needs `sharp`, see the script header).

**Backend**
```powershell
cd backend
dotnet test WFit.sln             # 68 xUnit tests
# Local host: copy src/WFit.Api/local.settings.sample.json to local.settings.json and fill in the settings, then:
cd src/WFit.Api; func start      # or: npx azure-functions-core-tools@4 start
```
To change the database schema, run `dotnet tool restore`, then
`dotnet ef migrations add <Name> --project src/WFit.Api`. Migrations are applied automatically on the first database
request after a deploy.

**Catalog changes:** edit `app/assets/data/catalog.json` and bump `version`. The backend reseeds its SQL catalog
tables when the version changes. Both test suites validate the catalog.

## Troubleshooting
- **First sync of the day takes ~30–60 s.** Serverless SQL is resuming from auto-pause, which is expected. The app
  times out after 120 s and retries on the next sync.
- **Sync fails late in the month.** The SQL free allowance may be used up, so the database is paused until the 1st.
  Nothing is lost: changes stay queued on the phone. (Raising the limit would mean switching to `BillOverUsage`.
  Only do that deliberately.)
- **AI says "limit reached".** The daily or monthly cap was hit. The app falls back to the on-device plan, swaps and
  insights.
- **401 from the API.** The API key on the phone doesn't match Key Vault. Re-enter it in Settings.
