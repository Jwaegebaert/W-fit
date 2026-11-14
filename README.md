# W-fit

W-fit is a personal training companion for Android. It started as a way to stop guessing in the gym and grew into a
small coach that plans your sessions, keeps your muscle groups in balance and learns from how your body responds.

The programme is a beginner-friendly **Push / Pull / Legs** split, three times a week, about an hour per session
including warm-up and cool-down. The main goal is balanced strength and muscle across the whole body. Badminton
(mobility, explosiveness and stability) comes along as a secondary goal.

## What it does

- **Guided workouts.** Every session follows the same rhythm: warm-up, main lifts, optional core, and a cool-down with
  three stretches. Each exercise shows sets, reps, rest, instructions, tips, common mistakes, the muscles it works and
  how it helps your badminton. Plans are built for a machine-heavy gym with little floor space, so standing and
  station drills come first and each block uses at most one floor exercise.
- **Smart, varied programming.** Training runs in 6-week blocks with alternating A/B sessions. Anchor lifts stay for a
  whole block so you can actually progress on them, accessories rotate between blocks, and deload weeks are planned
  (or pulled forward when fatigue builds up). Every plan explains *why* it looks the way it does.
- **Muscle balance.** W-fit counts effective sets for 19 muscle groups (indirect work counts half) and compares them
  with weekly targets over the last 8 weeks. Muscles that fall behind get extra work next session, and over-trained
  ones are trimmed. The balance screen shows this week, an 8-week heatmap and what the coach is focusing on.
- **Feedback memory.** Tell the app about pain, broken equipment or an exercise that just doesn't feel right. The plan
  adapts straight away (neck pain, for example, removes every neck-loading exercise) and keeps respecting it until you
  mark it as resolved.
- **Built-in visuals.** Exercises come with a start/end demo (photos for 172 of 226 exercises, from the public-domain
  [free-exercise-db](https://github.com/yuhonas/free-exercise-db)), and tapping a piece of equipment shows a simple
  line drawing of it.
- **Your gym, your equipment.** Switch off whatever your gym doesn't have, or start from a quick preset.
- **Live tracking.** Log weight and reps per set. Weights are pre-filled from your history, rest timers start on their
  own and the screen stays awake while you train.
- **Instant swaps.** Machine taken? Mark it as *Occupied* for today, *Not in my gym* for good, or *Prefer another* if
  you simply don't like it. You get equivalent alternatives right away.
- **AI coach.** An Azure OpenAI model refines each plan using a coach brief with your full training picture (balance,
  progression, programme phase, limitations and notes). It also reads free-text reports, suggests swaps and writes
  insights. Its output is limited to exercises from the catalog and validated on the server.
- **Statistics.** History, automatic personal records, consistency and volume charts, per-exercise progress, muscle
  focus and body measurements.
- **Offline first.** Everything works without a network connection or AI. Your data lives in SQLite on the phone and
  syncs to the backend whenever a connection is available.

## Architecture

```
Flutter app (Android)  --HTTPS + X-Api-Key-->  Azure Functions (.NET 10, Flex Consumption)
  drift / SQLite                                 |-- EF Core   --> Azure SQL (serverless, sync only)
  training intelligence + rule engine            |-- Entra ID  --> Azure OpenAI (primary + fallback model)
  Riverpod, fl_chart                             '-- Entra ID  --> Table Storage (AI usage counters)
```

A few design choices worth knowing about (more in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- **AI is optional.** On-device training intelligence and a rule engine generate, balance, progress and swap workouts
  on their own. The AI only refines them. AI endpoints are stateless (the app sends the coach brief), so a paused
  database never slows the coach down.
- **Sync is a single call.** One `POST /sync` pushes and pulls changes, using client-generated GUIDs and
  last-write-wins.
- **No passwords in the cloud.** Managed identity is used for SQL, OpenAI, Storage and Key Vault. The only secret is
  the app's API key, which lives in Key Vault and in the phone's encrypted storage.

| Path | Contents |
|---|---|
| [app/](app/) | Flutter app: domain logic (catalog, muscles, training load, programme, rule engine, progression, stats), data layer (drift DB, repository, API client, sync) and screens |
| [backend/](backend/) | Azure Functions API, EF Core migrations and xUnit tests (see [backend/README.md](backend/README.md)) |
| [infra/](infra/) | [main.bicep](infra/main.bicep) and [deploy.ps1](infra/deploy.ps1) |
| [app/assets/data/catalog.json](app/assets/data/catalog.json) | The single source of truth: 41 equipment types and 226 exercises with muscles, joint-stress regions, instructions, tips and common mistakes (embedded in the backend at build time) |
| [docs/](docs/) | [ARCHITECTURE.md](docs/ARCHITECTURE.md), [TRAINING-SCIENCE.md](docs/TRAINING-SCIENCE.md), [IMPROVEMENT-PLAN.md](docs/IMPROVEMENT-PLAN.md), [API.md](docs/API.md), [COSTS.md](docs/COSTS.md) |

## Running costs

For a single user, expect roughly **$1.50 to $4 per month**. Even with every AI limit maxed out, the worst case stays
around $15. The template also creates a $50 monthly budget that emails you as spending climbs. Budgets only alert, so
the real safety net is the set of limits built into the API. The full breakdown is in [docs/COSTS.md](docs/COSTS.md).

## Deploy your own backend

You'll need the Azure CLI (logged in to your own tenant), the .NET 10 SDK and PowerShell 7.

```powershell
az login
./infra/deploy.ps1 -ResourceGroup <resource-group> -AlertEmail you@example.com   # provision, deploy and smoke test
./infra/deploy.ps1 -ResourceGroup <resource-group> -SkipInfra                     # redeploy the backend code only
./infra/deploy.ps1 -ResourceGroup <resource-group> -WhatIf                        # preview infrastructure changes
```

The script is safe to re-run. It:
1. Creates the resource group and deploys the Bicep template.
2. Reuses the API key in Key Vault, or generates one on the first run.
3. Creates the Function App's managed-identity user in SQL.
4. Publishes the API and smoke-tests `/health`, `/ai/usage` and `/sync`.

When it's done it prints your API URL and the command to read the API key from Key Vault.

### Tuning the AI safeguards

The limits are Function App settings, so you can change them in the portal or with the CLI:

```powershell
az functionapp config appsettings set -g <resource-group> -n <function-app> --settings AI_ENABLED=false   # kill switch
az functionapp config appsettings set -g <resource-group> -n <function-app> --settings AI_DAILY_CALL_LIMIT=10
```

`AI_MONTHLY_TOKEN_LIMIT`, `AI_MAX_OUTPUT_TOKENS`, `AZURE_OPENAI_DEPLOYMENT` and `AZURE_OPENAI_FALLBACK_DEPLOYMENT` work
the same way (defaults are listed in [backend/README.md](backend/README.md)). The app shows current usage under
**Settings > Backend connection** and on the **Coach** tab.

To switch models, change the model parameters in `infra/main.bicep` and the deployment app settings, then run the live
evaluation described in [backend/README.md](backend/README.md).

## Install the app on your phone

```powershell
cd app
flutter build apk --release --dart-define=WFIT_API_URL=https://<function-app>.azurewebsites.net/api
# The APK ends up in build/app/outputs/flutter-apk/app-release.apk (copy it to the phone, or: adb install -r <apk>)
```

Open **Settings > Backend connection**, paste your API key (the URL is already filled in thanks to the dart-define)
and tap **Save & connect**. Without a connection the app simply runs offline.

The release build is signed with the Flutter debug key, which is fine for sideloading a personal app. If you want your
own upload key, follow the [Flutter Android signing guide](https://docs.flutter.dev/deployment/android#sign-the-app).
`key.properties` and `*.jks` are already git-ignored.

## Local development

**App**
```powershell
cd app
flutter pub get
dart run build_runner build      # regenerate drift code after changing lib/data/db/database.dart
flutter analyze
flutter test                     # unit, full-flow widget and layout tests (in-memory SQLite)
flutter test test/screenshots_test.dart --dart-define=SCREENSHOTS=true   # optional: PNGs of every screen
flutter run                      # needs an Android device or emulator
```

To regenerate assets, run `dart run flutter_launcher_icons -f flutter_launcher_icons.yaml` and
`dart run flutter_native_splash:create --path=flutter_native_splash.yaml` for the icon and splash (sources live in
`assets/brand/source/`), or `node tool/fetch_exercise_media.mjs` for the demo photos (needs `sharp`, see the script
header).

**Backend**
```powershell
cd backend
dotnet test WFit.sln
# Local host: copy src/WFit.Api/local.settings.sample.json to local.settings.json, fill in the settings, then:
cd src/WFit.Api; func start      # or: npx azure-functions-core-tools@4 start
```

To change the database schema, run `dotnet tool restore` and then
`dotnet ef migrations add <Name> --project src/WFit.Api`. Migrations are applied automatically on the first database
request after a deploy.

**Catalog changes:** edit `app/assets/data/catalog.json` and bump its `version`. The backend reseeds its catalog tables
when the version changes, and both test suites validate the catalog.

## Troubleshooting

- **The first sync of the day takes 30 to 60 seconds.** That's serverless SQL waking up from auto-pause, which is
  expected. The app waits up to 120 seconds and otherwise retries on the next sync.
- **Sync fails late in the month.** The free SQL allowance may be used up, so the database pauses until the 1st.
  Nothing is lost, because changes stay queued on the phone.
- **The AI says "limit reached".** The daily or monthly cap was hit. The app falls back to its on-device plan, swaps
  and insights, which use the same training intelligence.
- **401 from the API.** The API key on the phone doesn't match the one in Key Vault. Re-enter it in Settings.
