# W-fit API contract (v1)

Base URL: `https://<function-app>.azurewebsites.net/api`

All JSON uses **camelCase**. Timestamps are ISO-8601 UTC (`2026-11-03T19:00:00Z`). Dates are `yyyy-MM-dd`.
IDs of user records are client-generated GUID strings (lowercase). Exercise / equipment IDs come from
`app/assets/data/catalog.json` — the single source of truth, embedded into the backend at build time.

## Authentication

Every endpoint except `GET /health` requires header `X-Api-Key: <key>`. The key lives in Key Vault and is exposed to
the Function App as app setting `WFIT_API_KEY` (Key Vault reference). Comparison is constant-time. Missing/invalid → `401`.

## Errors

Non-2xx responses return `{ "error": "code", "message": "human readable" }`.
Codes: `unauthorized`, `bad_request`, `ai_disabled`, `ai_limit_reached`, `ai_unavailable`, `not_found`, `server_error`.
AI limit → HTTP `429`. AI disabled / upstream failure → HTTP `503`. The app then falls back to its on-device rule engine.

## Shared record shapes

Every synced record has `updatedAt` (client clock, last-write-wins) and `deleted` (soft delete).

```jsonc
// Profile (singleton, id is always "me")
{ "id": "me", "name": "Alex", "experience": "beginner",   // beginner|novice|intermediate
  "goals": "lean, strong, flexible, badminton performance",
  "trainingDays": [1,3,5],          // ISO weekday 1=Mon..7=Sun
  "sessionMinutes": 60, "includeCore": true,
  "heightCm": 180, "birthYear": 1995, "injuries": "", "notes": "",
  "updatedAt": "...", "deleted": false }

// EquipmentStatus (one per catalog equipment id)
{ "equipmentId": "leg_press", "available": false, "updatedAt": "...", "deleted": false }

// ExercisePreference
{ "exerciseId": "barbell-back-squat", "preference": "disliked",  // liked|neutral|disliked|banned
  "note": "", "updatedAt": "...", "deleted": false }

// PlannedWorkout
{ "id": "guid", "date": "2026-11-04", "dayType": "push",   // push|pull|legs
  "title": "Push day", "source": "ai",                     // ai|rules
  "status": "planned",                                     // planned|completed|skipped
  "estimatedMinutes": 58, "coachNote": "Focus on controlled tempo.",
  "blocks": [
    { "section": "warmup",                                 // warmup|main|core|cooldown
      "items": [
        { "exerciseId": "rowing-easy", "sets": 1, "repMin": null, "repMax": null,
          "durationSeconds": 300, "restSeconds": 0, "targetWeightKg": null, "notes": "" }
      ] }
  ],
  "updatedAt": "...", "deleted": false }

// WorkoutSession
{ "id": "guid", "plannedWorkoutId": "guid|null", "dayType": "push", "title": "Push day",
  "startedAt": "...", "endedAt": "...|null", "durationSeconds": 3480,
  "rating": 4, "perceivedEffort": 7, "notes": "", "updatedAt": "...", "deleted": false }

// SetLog
{ "id": "guid", "sessionId": "guid", "exerciseId": "dumbbell-bench-press", "section": "main",
  "exerciseOrder": 1, "setNumber": 1, "weightKg": 16.0, "reps": 10, "durationSeconds": null,
  "rir": 2, "completed": true, "completedAt": "...", "updatedAt": "...", "deleted": false }

// BodyMetric
{ "id": "guid", "date": "2026-11-03", "weightKg": 78.4, "bodyFatPct": null, "waistCm": 84,
  "chestCm": null, "armCm": null, "thighCm": null, "hipsCm": null, "notes": "",
  "updatedAt": "...", "deleted": false }
```

## Endpoints

### `GET /health` (anonymous)
`200 { "status": "ok", "version": "1.0.0" }` — does **not** touch SQL (so it never wakes the database).

### `POST /sync`
Bidirectional sync in one round-trip. The server upserts every pushed record whose `updatedAt` is newer than (or equal
to) the stored one (last-write-wins) and stamps a server-side `serverUpdatedAt`. It then returns every record with
`serverUpdatedAt > since` (all records when `since` is null).

Request
```jsonc
{ "since": "2026-11-01T10:00:00Z", // or null for a full pull
  "changes": { "profile": { ... } | null, "equipment": [], "exercisePreferences": [],
               "plannedWorkouts": [], "sessions": [], "sets": [], "bodyMetrics": [] } }
```
Response `200`
```jsonc
{ "serverTime": "2026-11-03T19:00:00Z",
  "changes": { "profile": {...}|null, "equipment": [], "exercisePreferences": [],
               "plannedWorkouts": [], "sessions": [], "sets": [], "bodyMetrics": [] } }
```
Limits: max 2,000 records per request (→ `400`). The client stores `serverTime` as its next `since`.

### `POST /ai/workout`
Generate a planned workout with Azure OpenAI. The server reads profile, equipment, preferences and recent history
from SQL (the client syncs first). The model may only choose from a server-filtered candidate list of exercise IDs;
the result is validated and clamped to beginner-safe bounds (sets 1–5, reps 3–20, rest 30–240 s for main lifts,
max 7 main exercises, at most 1 floor exercise — equipment `mat` — per warm-up / core / cooldown block when a standing
alternative exists). The workout is saved as a `PlannedWorkout` (source `ai`) and returned.

Request
```jsonc
{ "dayType": "push", "date": "2026-11-04", "sessionMinutes": 60, "includeCore": true,
  "occupiedEquipment": ["cable_machine"], "userNote": "left shoulder a bit stiff" }
```
Response `200` → `{ "workout": PlannedWorkout, "usage": AiUsage }`

### `POST /ai/swap`
Suggest up to 3 replacement exercises (validated against catalog + available equipment).

Request
```jsonc
{ "exerciseId": "barbell-bench-press", "reason": "occupied",   // occupied|unavailable|preference
  "dayType": "push", "section": "main",
  "excludeExerciseIds": ["incline-dumbbell-press"], "occupiedEquipment": ["flat_bench"], "note": "" }
```
Response `200`
```jsonc
{ "suggestions": [ { "exerciseId": "machine-chest-press", "why": "Same pressing pattern, no bench needed.",
                     "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 90 } ],
  "source": "ai", "usage": AiUsage }
```
When `reason` is `unavailable`, the server does **not** change equipment itself; the client marks the equipment
unavailable and syncs.

### `POST /ai/insights`
Progress insights from the last 8 weeks. Cached per UTC day; `force: true` bypasses the cache (counts against limits).

Request `{ "force": false }`
Response `200`
```jsonc
{ "generatedAt": "...", "summary": "...", "highlights": ["..."], "recommendations": ["..."],
  "nextFocus": "...", "source": "ai", "cached": true, "usage": AiUsage }
```

### `GET /ai/usage`
`200 AiUsage`
```jsonc
{ "enabled": true, "callsToday": 3, "dailyCallLimit": 25,
  "tokensThisMonth": 41250, "monthlyTokenLimit": 2000000 }
```

## AI cost safeguards (server-side app settings)
| Setting | Default | Purpose |
|---|---|---|
| `AI_ENABLED` | `true` | Kill switch |
| `AI_DAILY_CALL_LIMIT` | `25` | Max AI calls per UTC day |
| `AI_MONTHLY_TOKEN_LIMIT` | `2000000` | Hard monthly token cap (≈ $2 on gpt-4.1-mini) |
| `AI_MAX_OUTPUT_TOKENS` | `1800` | Per-call output cap |
| `AZURE_OPENAI_ENDPOINT` | — | Dedicated W-fit Azure OpenAI account endpoint |
| `AZURE_OPENAI_DEPLOYMENT` | `gpt-4.1-mini` | Chat deployment name |
| `SQL_CONNECTION_STRING` | — | Uses `Authentication=Active Directory Default` (managed identity, no password) |
