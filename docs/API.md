# W-fit API contract (v3)

Base URL: `https://<function-app>.azurewebsites.net/api`

All JSON uses **camelCase**. Timestamps are ISO-8601 UTC (`2026-11-03T19:00:00Z`). Dates are `yyyy-MM-dd`.
IDs of user records are client-generated GUID strings (lowercase). Exercise / equipment IDs come from
`app/assets/data/catalog.json` — the single source of truth, embedded into the backend at build time. Muscle and
body-region vocabularies are defined in `app/lib/domain/muscles.dart` and mirrored in `WFit.Api.Domain.Anatomy`
(see [IMPROVEMENT-PLAN §4.1](IMPROVEMENT-PLAN.md)).

## Authentication

Every endpoint except `GET /health` requires header `X-Api-Key: <key>`. The key lives in Key Vault and is exposed to
the Function App as app setting `WFIT_API_KEY` (Key Vault reference). Comparison is constant-time. Missing/invalid → `401`.

## Errors

Non-2xx responses return `{ "error": "code", "message": "human readable" }`.
Codes: `unauthorized`, `bad_request`, `payload_too_large`, `ai_disabled`, `ai_limit_reached`, `ai_unavailable`,
`not_found`, `server_error`.
Body too large → HTTP `413` (`/sync` 16 MB, `/ai/*` 256 KB). AI limit → HTTP `429`. AI disabled / upstream failure /
unusable model answer → HTTP `503`. The app then keeps its on-device rule-engine plan.

## Shared record shapes

Every synced record has `updatedAt` (client clock, last-write-wins) and `deleted` (soft delete).

```jsonc
// Profile (singleton, id is always "me")
{ "id": "me", "name": "Alex", "experience": "beginner",   // beginner|novice|intermediate
  "goals": "lean, strong, flexible, badminton performance",
  "trainingDays": [1,3,5],          // ISO weekday 1=Mon..7=Sun
  "sessionMinutes": 60, "includeCore": true,
  "restMode": "normal",          // short (x0.7) | normal | long (x1.3) rest between sets
  "cooldownStretches": 3,         // 0-3; 0 = no cool-down block
  "barWeights": { "smith_machine": 15 },  // user-set empty-bar kg (max 10, 0-60 kg); bar exercises log plates only
  "stackPlates": { "seated_row_machine": 5 },  // kg of one plate on machines with a numbered stack (max 40, 0-50 kg); left out = unchanged
  "muscleFocus": { "less": ["side_delts"], "more": ["glutes"], "light": ["lower_back"] },  // tracked muscles; more wins over less
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
          "durationSeconds": 300, "restSeconds": 0, "targetWeightKg": null, "notes": "",
          "perSide": false }   // optional; reps / seconds count per side (set by the app)
      ] }
  ],
  // PlanMeta serialized as a JSON object string, ≤ 8000 chars (null / invalid / too long ⇒ stored as "{}").
  "metaJson": "{\"program\":\"Block 2 · Week 3 · Push B\",\"variant\":\"B\",\"deload\":false,\"focus\":[\"biceps\"],\"rationale\":[\"…\"],\"changes\":[{\"from\":\"id\",\"to\":\"id\",\"reason\":\"…\"}]}",
  "updatedAt": "...", "deleted": false }

// WorkoutSession
{ "id": "guid", "plannedWorkoutId": "guid|null", "dayType": "push", "title": "Push day",
  "startedAt": "...", "endedAt": "...|null", "durationSeconds": 3480,
  "rating": 4, "perceivedEffort": 7, "notes": "", "updatedAt": "...", "deleted": false }

// SetLog
{ "id": "guid", "sessionId": "guid", "exerciseId": "dumbbell-bench-press", "section": "main",
  "exerciseOrder": 1, "setNumber": 1, "weightKg": 16.0,
  "plate": null,                  // plate number on a numbered stack; weightKg is what it weighs
  "reps": 10, "durationSeconds": null,
  "rir": 2, "completed": true, "completedAt": "...", "updatedAt": "...", "deleted": false }

// BodyMetric
{ "id": "guid", "date": "2026-11-03", "weightKg": 78.4, "bodyFatPct": null, "waistCm": 84,
  "chestCm": null, "armCm": null, "thighCm": null, "hipsCm": null, "notes": "",
  "updatedAt": "...", "deleted": false }

// FeedbackEntry (feedback memory, IMPROVEMENT-PLAN §4.3)
{ "id": "guid", "createdAt": "2026-11-07T18:00:00Z",       // null ⇒ updatedAt
  "kind": "pain",          // pain|discomfort|too_easy|too_hard|unavailable|dislike|like|note
  "region": "neck",        // neck|shoulder|elbow|wrist|upper_back|lower_back|hip|knee|ankle|null
  "severity": 2,           // 1 mild | 2 moderate | 3 severe | null
  "exerciseId": null,      // catalog id or null
  "sessionId": null,       // GUID or null
  "note": "Neck stiff after shrugs",                        // ≤ 2000 chars (truncated)
  "status": "active",      // active|resolved
  "reviewOn": "2026-11-14",                                 // date or null
  "resolvedAt": null, "source": "user",                     // user|coach
  "updatedAt": "...", "deleted": false }
```
A feedback entry is skipped (not stored) when its id / sessionId is not a GUID, `kind` / `status` / `source` / `region`
are outside the vocabularies, `severity` is outside 1–3, `exerciseId` is unknown, or a `pain` / `discomfort` entry has
neither `region` nor `exerciseId`.

## Endpoints

### `GET /health` (anonymous)
`200 { "status": "ok", "version": "3.0.0" }` — does **not** touch SQL (so it never wakes the database).

### `POST /sync`
Bidirectional sync in one round-trip. The server upserts every pushed record whose `updatedAt` is newer than (or equal
to) the stored one (last-write-wins) and stamps a server-side `serverUpdatedAt`. It then returns every record with
`serverUpdatedAt > since` (all records when `since` is null). This is the **only** endpoint that uses SQL; the first
call after a deployment applies EF migrations and seeds the catalog.

Request
```jsonc
{ "since": "2026-11-01T10:00:00Z", // or null for a full pull
  "changes": { "profile": { ... } | null, "equipment": [], "exercisePreferences": [],
               "plannedWorkouts": [], "sessions": [], "sets": [], "bodyMetrics": [], "feedbackEntries": [] } }
```
Response `200`
```jsonc
{ "serverTime": "2026-11-03T19:00:00Z",
  "changes": { "profile": {...}|null, "equipment": [], "exercisePreferences": [],
               "plannedWorkouts": [], "sessions": [], "sets": [], "bodyMetrics": [], "feedbackEntries": [] } }
```
Limits: max 2,000 records per request (→ `400`). The client stores `serverTime` as its next `since`.

## AI endpoints (stateless)

The AI endpoints never read or write SQL: everything the coach needs travels in the request as the **coach brief**
(built on the device, [IMPROVEMENT-PLAN §4.4](IMPROVEMENT-PLAN.md)),
and AI plans are not persisted server-side (the app stores them and syncs them as `PlannedWorkout`s).
Usage counters live in Azure Table Storage. Requests are capped at **256 KB** (→ `413`).

**Brief handling.** Unknown fields are ignored, every field may be null and numbers may be integers or decimals.
Before prompting, lists are truncated to: `limitations` 20, `exerciseFeedback` 30, `exerciseHistory` 25 (≤ 4
`exposures` each), `recentSessions` 9 (≤ 15 `exercises` each), `weekly` 8, `balance.muscles` 25,
`balance.priorities` 8, `balance.notes` 8, equipment / preference id lists 100; free text is shortened (notes 500 chars,
injuries 1000). Dates in the brief are read leniently (`yyyy-MM-dd`, a longer ISO timestamp is cut to its date).

**Server-side safety (all AI endpoints).** Candidates = catalog ∩ day split ∩ usable equipment (`brief.equipment.unavailable`
and `occupied`, plus `occupiedEquipment` for swaps; `bodyweight` and always-available equipment are always usable) ∩ not
`banned` (`brief.preferences`) ∩ difficulty for `brief.profile.experience` (beginner/novice ≤ 2, intermediate ≤ 3) ∩ not
excluded by `brief.limitations` (active `pain` / `discomfort` entries):

| Limitation | Effect |
|---|---|
| region, severity 1 (mild) | exercises whose catalog `stress` contains the region are penalised (offered with `caution`, ranked last in swaps) |
| region, severity 2 (moderate) | exercises stressing the region are excluded |
| region, severity 3 (severe) | also excluded: exercises whose **primary** muscles include the region's related muscles (e.g. neck → traps, knee → quads) |
| exercise, `pain` | that exercise is excluded |
| exercise, `discomfort` | excluded for 28 days after `since` (or when `since` is null), then penalised |

Missing severity counts as 2 for `pain` and 1 for `discomfort`. Model output is validated: ids outside the candidates are
dropped, sections must match the exercise category, no duplicates, ≤ 7 main / ≤ 6 other items per block, ≥ 2 main items
(else `503`), sets 1–5 (≤ 3 on a deload: `brief.program.deload` or `draft.meta.deload`), reps 3–20 (min ≤ max), timed
10–600 s, rest 30–240 s main / 0–180 s other, `targetWeightKg` 0.5-kg steps ≤ 300 (null for timed), notes ≤ 300 chars,
≤ 1 floor exercise (equipment `mat`) per warm-up / core / cooldown block when a standing option exists.

**PlanMeta** (returned with every AI plan; the app stores it as `metaJson`):
```jsonc
{ "program": "Block 2 · Week 3 · Push B",  // draft/plan meta.program, else built from brief.program, else null
  "variant": "B", "deload": false,
  "focus": ["biceps"],                      // tracked muscles only, ≤ 4, never muscles avoided for severe pain
  "rationale": ["Biceps 3.5 of 4–10 sets → +1 set on cable curls"],   // ≤ 6 lines, ≤ 240 chars each
  "changes": [ { "from": "incline-dumbbell-press", "to": "machine-chest-press", "reason": "neck pain" } ] }
  // ≤ 8; `from` is a catalog id, `to` is in the returned plan
```

**Models.** `gpt-6-sol` (reasoning effort `low` for workout / adjust / swap, `medium` for insights), automatic single
fallback to `gpt-6-luna` on 429 / 5xx / network error / timeout (60 s per attempt). Typical latency 10–15 s for a plan.

### `POST /ai/workout`
Refines the rule-engine draft into today's session.

Request
```jsonc
{ "dayType": "push",                   // required: push|pull|legs
  "date": "2026-11-10",                // optional, default brief.today / server UTC date
  "sessionMinutes": 60, "includeCore": true,   // optional, default brief.profile, then 60 / true
  "userNote": "left shoulder a bit stiff",     // optional, ≤ 500 chars used
  "brief": { /* coach brief §4.4 */ },
  "draft": { "title": "Push B", "blocks": [ /* WorkoutBlock[] */ ], "meta": { /* PlanMeta */ } } }
```
Draft items the athlete can't do today (limitation, equipment, ban, difficulty) are shown to the model as `blocked` with
the reason, so it replaces them. Response `200`:
```jsonc
{ "workout": { "id": "new guid", "date": "2026-11-10", "dayType": "push", "title": "Push B · shoulders",
               "coachNote": "…", "estimatedMinutes": 58, "blocks": [ /* WorkoutBlock[] */ ], "meta": { /* PlanMeta */ } },
  "usage": AiUsage }
```
The workout is **not** saved on the server; save it locally (`source: "ai"`) and sync it.

### `POST /ai/adjust`
Interprets a free-text report ("my neck hurts", "the leg press is broken", "this felt too easy") into feedback entries
and, when a plan is given, an adjusted plan.

Request
```jsonc
{ "message": "the leg press is broken and my left knee feels a bit sore",   // required, ≤ 2000 chars
  "exerciseId": "leg-press",        // optional: exercise on screen (unknown ids are ignored)
  "sessionInProgress": true,
  "plan": { "id": "guid", "date": "2026-11-09", "dayType": "legs", "title": "Legs A",
            "blocks": [ /* WorkoutBlock[] */ ], "meta": { /* PlanMeta */ } } | null,   // dayType must be valid (else 400)
  "brief": { /* coach brief */ } }
```
Response `200`
```jsonc
{ "reply": "Sorry about the knee – I swapped the leg press and leg extension …",
  "feedback": [
    { "kind": "unavailable", "region": null, "severity": null, "exerciseId": "leg-press", "equipmentId": "leg_press",
      "note": "The leg press is broken.", "reviewInDays": null },
    { "kind": "discomfort", "region": "knee", "severity": 1, "exerciseId": null, "equipmentId": null,
      "note": "Left knee a bit sore.", "reviewInDays": 14 } ],
  "plan": { "title": "…", "coachNote": "…", "estimatedMinutes": 55, "blocks": [ /* WorkoutBlock[] */ ], "meta": { /* PlanMeta */ } } | null,
  "usage": AiUsage,
  "focusChanges": [ { "muscle": "side_delts", "level": "less", "light": true, "reason": "…" } ] }  // proposals only; the app saves them when the athlete accepts
```
Feedback validation (≤ 5 entries): `kind` / `region` per the §4.3 vocabularies; `pain` / `discomfort` need a region or
an exercise and get severity 1–3 (default pain 2, discomfort 1); other kinds have `severity: null`; `too_easy`,
`too_hard`, `like`, `dislike` need a known `exerciseId`; `unavailable` needs `exerciseId` or `equipmentId`;
`equipmentId` (a catalog equipment id, **only** for `unavailable`) tells the app which equipment to mark unavailable;
`reviewInDays` 1–42 (default pain 7, discomfort 14, otherwise null); `note` ≤ 2000. The app stores the entries as
`FeedbackEntry` (`source: "coach"`, `reviewOn = today + reviewInDays`).

The plan is validated like a workout against candidates that **already include the new feedback** (new pain /
discomfort entries, unavailable equipment — when no `equipmentId` is given, the single machine of the reported exercise —
and the reported exercise itself). If the model keeps the plan (`null`) but the plan now contains excluded exercises,
the server removes them and explains it in `meta.rationale`. `plan` is `null` when no plan was sent or nothing had to change.

### `POST /ai/swap`
Suggest up to 3 replacement exercises.

Request
```jsonc
{ "exerciseId": "barbell-bench-press", "reason": "occupied",   // occupied|unavailable|preference
  "dayType": "push", "section": "main",
  "excludeExerciseIds": ["incline-dumbbell-press"], "occupiedEquipment": ["flat_bench"], "note": "",
  "brief": { /* coach brief */ } }
```
Response `200`
```jsonc
{ "suggestions": [ { "exerciseId": "machine-chest-press", "why": "Same pressing pattern, no bench needed.",
                     "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 90 } ],
  "source": "ai",   // "rules" when the model returned nothing valid (rule ranking) or no candidate exists (empty list, no AI call)
  "usage": AiUsage }
```
Candidates are ranked by the rule score (same pattern +3, primary overlap +2 each, …, limitation penalty) and the top 15
are offered to the model. When `reason` is `unavailable`, the server does **not** change equipment itself; the client
marks the equipment unavailable and syncs.

### `POST /ai/insights`
Coach review of the brief (reasoning effort `medium`). **Not cached server-side** — the app caches per day + brief
fingerprint. Without training data in the brief (no `recentSessions`, no `weekly` sessions, no `program.completedSessions`)
a rules-based answer is returned without an AI call.

Request `{ "brief": { /* coach brief */ } }`
Response `200`
```jsonc
{ "generatedAt": "...", "summary": "...", "highlights": ["..."], "recommendations": ["..."],   // ≤ 4 each, ≤ 300 chars
  "nextFocus": "...", "focusMuscles": ["rear_delts", "biceps"],   // ≤ 3 tracked muscles
  "source": "ai", "usage": AiUsage }
```

### `GET /ai/usage`
`200 AiUsage` (Table Storage only)
```jsonc
{ "enabled": true, "callsToday": 3, "dailyCallLimit": 40,
  "tokensThisMonth": 41250, "monthlyTokenLimit": 3000000, "model": "gpt-6-sol" }
```
`callsToday` counts logical AI calls per UTC day (a fallback attempt is part of the same call; failed calls count too).
`tokensThisMonth` = input + output tokens (output includes reasoning tokens) in the current UTC month.

## AI cost safeguards (server-side app settings)
| Setting | Default | Purpose |
|---|---|---|
| `AI_ENABLED` | `true` | Kill switch (`false` ⇒ 503 `ai_disabled`) |
| `AI_DAILY_CALL_LIMIT` | `40` | Max AI calls per UTC day (⇒ 429 `ai_limit_reached`) |
| `AI_MONTHLY_TOKEN_LIMIT` | `3000000` | Hard monthly token cap (input + output, UTC month) |
| `AI_MAX_OUTPUT_TOKENS` | `8000` | `max_completion_tokens` per call (includes reasoning tokens) |
| `AI_CALL_TIMEOUT_SECONDS` | `60` | Per-attempt model timeout (the fallback attempt gets its own) |
| `AZURE_OPENAI_ENDPOINT` | — | W-fit Azure OpenAI account endpoint (v1 API `…/openai/v1`, Entra ID auth) |
| `AZURE_OPENAI_DEPLOYMENT` | `gpt-6-sol` | Primary deployment |
| `AZURE_OPENAI_FALLBACK_DEPLOYMENT` | `gpt-6-luna` | Fallback deployment (empty or `none` disables the fallback) |
| `AZURE_STORAGE_TABLE_ENDPOINT` | `https://{AzureWebJobsStorage__accountName}.table.core.windows.net` | Table Storage for usage counters (table `aiusage`); unset ⇒ in-memory (local dev) |
| `SQL_CONNECTION_STRING` | — | Sync only; uses managed identity (no password) |
