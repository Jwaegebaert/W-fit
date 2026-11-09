# W-fit v3 — "intelligent coach" improvement plan

Status: in implementation (November 2026). This document is the single reference for the v3 work: what was wrong,
what we decided, the contracts between components, and how we validate the result. When v3 ships, the durable parts
move into [ARCHITECTURE.md](ARCHITECTURE.md), [API.md](API.md) and [TRAINING-SCIENCE.md](TRAINING-SCIENCE.md).

## 1. Analysis of v2 (what fell short and why)

| Area | Finding | Evidence |
|---|---|---|
| Catalog | 126 exercises, only 71 main lifts. Traps, forearms, adductors and lower back are (almost) never a *primary* target; no adductor machine, shrugs, preacher/incline curls, skull crushers, dips, hack squat, seated leg curl, deadlift variants or back extensions. 40 exercises have no demo photo. No joint-stress metadata, so pain cannot be handled. | `catalog.json` analysis |
| Same workout every week | `RuleEngine` fills a fixed slot list per day and gives `+5` to exercises used in the last two sessions of that day type, so the same exercises win forever. No periodisation, no rep-range variation. | `rule_engine.dart` (`recentBonus`, `mainSlots`) |
| Muscle data unused | `muscleLoad()` and the "Muscle focus" chart count primary sets only and never influence planning. No targets, no multi-week view, no indirect volume. | `stats.dart`, `stats_screen.dart` |
| Feedback lost | Session notes, swap notes ("shoulder feels tight") and preference notes are stored but never sent to the AI; the swap note is not even persisted. There is no concept of pain or limitations besides a free-text profile field. Set RIR exists in the schema but is never captured. | `TrainingDataReader`, `swap_sheet.dart`, `session_screen.dart` |
| AI context thin | The model sees 6 sessions of "best set" strings, liked/disliked ids and the profile. No balance, no progression trends, no feedback, no program state. | `WorkoutAiService` |
| AI slow | Telemetry (30 days): AI workout 12.6 s, but the app forces `POST /sync` first and sync p90 = 25.8 s, max 54.5 s (serverless SQL resuming from auto-pause). End-to-end waits of 40–65 s. | App Insights `AppRequests` |
| AI quality | `gpt-4.1-mini` (legacy, retiring 2027-04). In a realistic benchmark it produced contradictory rationale and claimed volume changes it did not make. | §3 benchmark |
| Badminton overweighted | A plyometric slot on every day type, badminton bonuses in warm-up and cool-down, and the AI prompt frames badminton as a primary goal. | `mainSlots`, `_warmup`, `AiPrompts.WorkoutSystem` |

## 2. Target architecture

```
Flutter app (offline-first)                                     Azure Functions (.NET 10, stateless AI)
┌──────────────────────────────────────────────┐   HTTPS        ┌─────────────────────────────────────┐
│ Training intelligence (pure Dart, tested)    │                │ /ai/workout  /ai/adjust  /ai/swap   │
│  • training_load: effective sets per muscle  │  coach brief   │ /ai/insights /ai/usage              │
│  • balance: targets, status, priorities      │ ─────────────▶ │  • candidate + safety filter        │
│  • program: blocks, A/B variants, deload     │                │    (equipment, bans, limitations)   │
│  • limitations: pain/feedback → exclusions   │ ◀───────────── │  • gpt-6-sol (low effort),          │
│  • rule engine v2 (draft plan + rationale)   │  refined plan  │    gpt-6-luna fallback              │
│ Coach service: brief builder, pre-generation │                │  • output validator (hard limits)   │
│ drift/SQLite incl. feedback memory           │                │  • usage limits in Table Storage    │
└───────────────┬──────────────────────────────┘                └─────────────────────────────────────┘
                │ POST /sync (background, unchanged model + feedback entries)
                ▼
        Azure SQL (backup / multi-device copy; no longer on the AI critical path)
```

Key decisions:

1. **One training brain, on the device.** All analytics (volume, balance, progression trends, program state,
   limitations) live in pure Dart in `app/lib/domain`. The UI, the offline rule engine and the AI all use the same
   numbers, so "the chart says biceps are behind" and "the plan adds biceps" can never disagree.
2. **Rule engine drafts, AI refines.** The rule engine always produces a scientifically sound draft (works offline).
   The AI receives the draft plus a compact *coach brief* and returns a refined plan with rationale. A server-side
   validator enforces candidate ids, limitation exclusions and safe prescriptions, so model mistakes cannot reach
   the user.
3. **Stateless AI endpoints.** The brief travels in the request; AI endpoints no longer read SQL, so a cold database
   never blocks the coach. Usage limits move to Azure Table Storage (always warm, ~free). The app saves AI plans
   locally and syncs them in the background.
4. **Latency hidden by design.** After a workout is finished the app pre-generates the next session with the AI in
   the background. Pain/feedback reports are applied instantly by the deterministic engine; the AI refinement follows
   asynchronously. The app pings `/health` at start-up to warm the Function host.
5. **Feedback memory.** A new synced table `feedback_entries` stores pain/discomfort per body region, per-exercise
   feedback, check-ins and resolutions. It drives exclusions, penalties and the brief until resolved.
6. **Badminton is secondary.** At most one power exercise per session and at most two per week; badminton is a
   tie-breaker in warm-up/cool-down selection, not a goal that shapes the programme.

## 3. AI model decision

Benchmark on 2026-11-09 with the real W-fit task (push-day planning, neck-pain limitation, side-delt/biceps deficit,
progression history; strict JSON schema; same prompt for all):

| Deployment | Effort | Latency | Tokens in/out (reasoning) | Assessment |
|---|---|---|---|---|
| gpt-4.1-mini (v2) | – | 9.1 s | 5.2k / 1.0k | Picked a floor push-up, contradictory rationale |
| gpt-6-luna | low | 17.5 s | 5.2k / 1.9k (0.5k) | Sound, verbose |
| gpt-6-luna | medium | 48.4 s | 5.2k / 5.0k (3.5k) | Too slow |
| **gpt-6-sol** | **low** | **13.1 s** | 5.2k / 1.3k (0.3k) | Correct, concise, clinically sensible, progression-aware |
| gpt-6-sol | medium | 28.7 s | 5.2k / 3.1k (1.5k) | Best (adds red-flag advice), too slow for interactive use |

Foundry quality index: gpt-4.1-mini 0.59 → gpt-6-sol 0.83. Prices (EU Data Zone, per 1M tokens): gpt-6-sol
$2.40 in / $12 out; gpt-6-luna $0.12 / $0.60.

**Decision:** `gpt-6-sol` (2026-09-22, DataZoneStandard, EU) with `reasoning_effort=low` for workout, adjust and swap;
`medium` for insights (background, cached). `gpt-6-luna` is the automatic fallback on throttling/5xx. Reasoning
models take no `temperature`; `max_completion_tokens` must include reasoning tokens (we use 8k).
Expected cost ≈ $0.05 per workout plan, ≈ $1–3 per month in normal use. App limits: 40 calls/day,
3M tokens/month; the $50 budget alert stays.

## 4. Contracts

### 4.1 Vocabulary (code: `app/lib/domain/muscles.dart`, backend mirror `WFit.Api.Domain.Anatomy`)
- **Tracked muscles** (balanced, with weekly effective-set targets `min–max`): chest 6–12, front_delts 3–10,
  side_delts 5–10, triceps 4–10, lats 6–12, upper_back 6–12, rear_delts 4–10, traps 2–6, biceps 4–10,
  forearms 1–6, quads 6–12, glutes 6–12, hamstrings 5–10, adductors 2–6, abductors 2–6, calves 3–8, abs 4–10,
  obliques 2–8, lower_back 1–6.
- **Other muscle values** allowed in the catalog (not balanced): hip_flexors, rotator_cuff, thoracic_spine,
  full_body.
- **Effective sets:** a completed working set in a `strength`, `power` or `core` exercise counts 1.0 for each primary
  muscle and 0.5 for each secondary muscle (`full_body` is ignored). Warm-up and cool-down sets don't count.
- **Body regions** (pain reports and catalog `stress`): neck, shoulder, elbow, wrist, upper_back, lower_back, hip,
  knee, ankle. Severe pain additionally avoids direct work for the region's related muscles (neck→traps;
  shoulder→front/side/rear delts, rotator cuff; elbow→biceps, triceps, forearms; wrist→forearms;
  upper_back→upper_back, traps, thoracic_spine; lower_back→lower_back; hip→adductors, abductors, hip_flexors;
  knee→quads; ankle→calves).

### 4.2 Catalog v3 (`app/assets/data/catalog.json`, `version: 3`)
Existing fields unchanged. New required field per exercise:
- `stress: string[]` — regions under meaningful load/strain (may be empty). Tag a region when the exercise loads that
  joint under external resistance, needs end-range positions there, or is a common aggravator. Examples: barbell
  back squat → `["neck","lower_back","hip","knee"]` (bar on upper traps); shrug → `["neck"]`; standing overhead press
  → `["neck","shoulder","lower_back"]`; crunch/sit-up → `["neck","lower_back"]`; skull crusher →
  `["elbow","shoulder"]`; leg extension → `["knee"]`; machine chest press → `["shoulder"]`; box jump →
  `["knee","ankle"]`; cat-cow → `[]`.

Content requirements:
- ≥ 210 exercises total, ≥ 140 in `strength`/`power`. Every tracked muscle is the primary target of ≥ 4 main
  exercises, including ≥ 1 machine/cable/Smith option and ≥ 1 free-weight (barbell/dumbbell/kettlebell/EZ) or
  bodyweight option. Every main movement pattern has ≥ 3 exercises with both a machine/cable and a free-weight
  option.
- New patterns as needed: `shrug`, `hip_adduction`, `pullover`, `back_extension`, `forearm`, `carry`,
  `glute_isolation` (all must be added to the rule-engine templates).
- Every new exercise has full v2 fields (instructions, tip, 2–3 mistakes, badminton only if genuinely relevant) and,
  wherever free-exercise-db has a matching movement **and** equipment, demo photos via
  `app/tool/fetch_exercise_media.mjs` (hand-verified mapping). New equipment types need an SVG line drawing in
  `app/assets/equipment/` in the existing style and must be considered in `equipment_presets.dart`.

### 4.3 Feedback memory (synced table `feedback_entries` / `FeedbackEntries`)
| Field | Type | Notes |
|---|---|---|
| id | GUID string | client-generated |
| createdAt | UTC timestamp | when reported |
| kind | `pain` \| `discomfort` \| `too_easy` \| `too_hard` \| `unavailable` \| `dislike` \| `like` \| `note` | |
| region | region id or null | required for pain/discomfort without exerciseId |
| severity | 1 (mild) \| 2 (moderate) \| 3 (severe) or null | pain/discomfort |
| exerciseId | catalog id or null | exercise-specific feedback |
| sessionId | GUID or null | session in which it was reported |
| note | string ≤ 2000 | user's words or coach summary |
| status | `active` \| `resolved` | |
| reviewOn | date `yyyy-MM-dd` or null | when the app asks "still an issue?" |
| resolvedAt | UTC timestamp or null | |
| source | `user` \| `coach` | `coach` = created from an AI interpretation |
| updatedAt, deleted | sync columns | last-write-wins, soft delete |

Engine semantics (active entries only):
- Region pain/discomfort severity 1 → exercises stressing the region get a strong penalty (allowed only if nothing
  else fits); severity 2 → excluded; severity 3 → excluded plus direct work for the related muscles excluded.
- Exercise-specific `pain` → exercise excluded; `discomfort` → excluded for 4 weeks, then penalised;
  `too_hard` → next target weight −1 increment and easier variations preferred; `too_easy` → +1 increment allowed.
- `dislike`/`like`/`unavailable` also update the existing preference / equipment tables (backwards compatible).
- Default `reviewOn`: pain +7 days, discomfort +14 days. A check-in card asks to resolve or keep.

`PlannedWorkout` gains `metaJson` (string ≤ 8000, default `{}`):
`{"program":"Block 2 · Week 3 · Push B","variant":"B","deload":false,"focus":["biceps"],"rationale":["…"],"changes":[{"from":"id","to":"id","reason":"…"}]}`.

### 4.4 Coach brief (built on the device, sent with every AI request)
```jsonc
{
  "today": "2026-11-09",
  "profile": { "experience": "beginner", "goals": "…", "sessionMinutes": 60, "includeCore": true, "trainingDays": [1,3,5],
               "age": 34, "heightCm": 180, "bodyweightKg": 78.5, "injuries": "free text", "notes": "free text" },
  "equipment": { "unavailable": ["rowing_machine"], "occupied": ["cable_machine"] },
  "preferences": { "liked": [], "disliked": [], "banned": [] },
  "limitations": [ { "id": "…", "kind": "pain", "region": "neck", "severity": 2, "exerciseId": null,
                     "note": "…", "since": "2026-11-07" } ],
  "exerciseFeedback": [ { "exerciseId": "…", "kind": "too_hard", "note": "…", "date": "2026-11-03" } ],   // ≤ 30, last 90 days
  "program": { "blockNumber": 2, "blockWeek": 3, "blockLength": 6, "phase": "accumulation", "deload": false,
               "deloadReason": null, "variant": "B", "variantFocus": "vertical & incline press emphasis",
               "targetRir": 2, "completedSessions": 23, "weeksTraining": 8 },
  "balance": {
    "muscles": [ { "muscle": "biceps", "thisWeek": 3.0, "lastWeek": 5.5, "recentAvg": 5.1, "targetMin": 4, "targetMax": 10,
                   "status": "under", "weeksUnder": 2, "daysSinceTrained": 5, "trend": "down" } ],
    "priorities": [ { "muscle": "biceps", "score": 0.8, "extraSets": 2, "reason": "below target 2 weeks running" } ],
    "ratios": { "pushPull": 1.15, "quadHam": 1.6 },
    "notes": [ "Rear delts below target in 3 of the last 4 weeks" ]
  },
  "exerciseHistory": [ { "exerciseId": "machine-chest-press", "trend": "progressing", "lastPerformed": "2026-11-03",
                         "exposures": [ { "date": "2026-11-03", "sets": "52.5x10, 52.5x9, 52.5x8", "e1rm": 70.0 } ] } ], // ≤ 25 exercises, ≤ 4 exposures, 12 weeks
  "recentSessions": [ { "date": "2026-11-07", "dayType": "legs", "title": "…", "rating": 4, "effort": 7,
                        "durationMin": 58, "notes": "…", "exercises": ["leg-press", "…"] } ],                  // ≤ 9
  "weekly": [ { "weekStart": "2026-11-02", "sessions": 3, "sets": 52, "volumeKg": 12000 } ]                      // ≤ 8
}
```

### 4.5 AI endpoints (stateless; request/response JSON camelCase; `X-Api-Key` as before)
- `POST /ai/workout` `{ dayType, date, sessionMinutes, includeCore, userNote, brief, draft }` where `draft` =
  `{ title, blocks, meta }` from the rule engine → `{ workout: { id, date, dayType, title, coachNote,
  estimatedMinutes, blocks, meta }, usage }`. Not persisted server-side.
- `POST /ai/adjust` (new) `{ message, exerciseId?, sessionInProgress, plan?: { id, date, dayType, title, blocks,
  meta }, brief }` → `{ reply, feedback: [ { kind, region, severity, exerciseId, note, reviewInDays } ],
  plan: { title, coachNote, blocks, meta } | null, usage }`. Interprets free-text reports ("my neck hurts", "the
  leg press is broken", "this felt too easy") into feedback entries and an adjusted plan.
- `POST /ai/swap` `{ exerciseId, reason, dayType, section, excludeExerciseIds, occupiedEquipment, note, brief }` →
  `{ suggestions, source, usage }`.
- `POST /ai/insights` `{ brief }` → `{ generatedAt, summary, highlights, recommendations, nextFocus,
  focusMuscles: [muscle ids], source, usage }`. Cached on the device per day + brief fingerprint.
- `GET /ai/usage` → `{ enabled, callsToday, dailyCallLimit, tokensThisMonth, monthlyTokenLimit, model }`.
- Server-side safety (all endpoints): candidates = catalog ∩ day split ∩ usable equipment ∩ not banned ∩
  difficulty ∩ **not excluded by limitations** (§4.3 semantics, mirrored in C#). Output ids outside the candidates
  are dropped; prescriptions are clamped; deload plans are capped at 3 sets per exercise.

### 4.6 Dart engine API (`app/lib/domain`, pure, no Flutter/DB imports except catalog loading)
```dart
// training_load.dart
List<MuscleWeek> weeklyMuscleVolume(Iterable<LoggedSet> sets, Catalog catalog, {int weeks = 8, DateTime? now});
BalanceReport analyzeBalance(List<MuscleWeek> weeks, Iterable<LoggedSet> sets, Catalog catalog, {DateTime? now});
// BalanceReport { List<MuscleStatus> muscles; List<MusclePriority> priorities; double? pushPullRatio;
//   double? quadHamRatio; Map<MuscleGroup,double> groupShare; List<String> notes; Map<String,dynamic> toBrief(); }
ExerciseTrend exerciseTrend(List<List<LoggedSet>> history);   // progressing | stalled | regressing | new

// limitations.dart
class Limitation { … }  // from active feedback entries
class LimitationPolicy { bool excludes(Exercise e); int penalty(Exercise e); String? reason(Exercise e); }

// program.dart
ProgramState computeProgramState(List<SessionInfo> sessions, {DateTime? now});  // block/week/variant/deload

// rule_engine.dart (v2)
GeneratedWorkout RuleEngine.generate({required DayType day, int sessionMinutes, bool includeCore,
    ProgramState? program, BalanceReport? balance, Map<String, ExerciseTrend> trends,
    double? Function(Exercise) suggestWeight});
// GeneratedWorkout gains: List<String> rationale, List<String> focusMuscles, PlanMeta meta.
List<SwapCandidate> RuleEngine.rankSwaps(...);              // also honours LimitationPolicy
PlanAdjustment RuleEngine.adjustForLimitations(List<PlanBlock> blocks, DayType day); // instant re-evaluation
```
`TrainingContext` gains `LimitationPolicy limitations` and `Map<String, ExerciseFeedbackSummary> feedback`.

### 4.7 Rule engine v2 programming model
- **Rotation:** Push → Pull → Legs, 3×/week (unchanged).
- **A/B variants per day type**, alternating per exposure of that day type:
  Push A chest-strength (horizontal press heavy), Push B shoulders & upper chest (vertical/incline heavy);
  Pull A vertical-pull heavy, Pull B row heavy (+ traps); Legs A squat-pattern heavy, Legs B hinge/hip heavy.
- **Slot roles:** `power` (optional, ≤ 1/session, ≤ 2/week), `anchor` (heavy compound, 6–10 reps, kept for the whole
  block for progressive overload), `secondary` (compound, 8–12), `accessory` (isolation, 10–15), `flex` (one slot
  for the top-priority under-trained muscle that is not today's main target and not trained in the last 48 h).
- **Blocks:** 6 weeks (5 accumulation + 1 deload). A new block starts after a ≥ 14-day gap. Early deload when
  fatigue signals appear (avg effort ≥ 8.5 over the last 3 sessions, rating ≤ 2 twice, or ≥ 2 regressing anchors).
  Deload: −1 set per exercise (min 2), ~90 % load, RIR 3–4. Target RIR: week 1 → 3, weeks 2–3 → 2, weeks 4–5 → 1–2.
- **Variation without randomness:** anchors persist within a block (continuity bonus) and rotate at a block boundary
  only if stalled or used for ≥ 2 blocks; accessories prefer exercises not used in the previous block and stay
  constant within a block per variant (so each appears every two weeks and remains progressable).
- **Balance:** priority muscles get +1 set on slots that train them (≤ +3 per session) and the flex slot; muscles
  above target get −1 set (min 2). Priorities: deficit vs `min`, weeks under, days since trained, last week's deficit
  carried over.
- **Safety & preferences:** limitations (§4.3), equipment, occupied, banned/disliked/liked, difficulty, floor rules
  (unchanged).

## 5. Workstreams

| # | Workstream | Scope (files) | Depends on |
|---|---|---|---|
| A | Catalog v3 content, photos, drawings, presets, catalog tests | `app/assets/**`, `app/tool/**`, `app/lib/domain/equipment_presets.dart`, `app/test/catalog_test.dart` | §4.1–4.2 |
| B | Backend: stateless AI, gpt-6-sol, adjust endpoint, limitation filter, feedback sync + `metaJson`, Table Storage usage, Bicep, live eval | `backend/**`, `infra/**`, `docs/API.md` | §4.3–4.5 |
| C | Training intelligence engine (Dart domain) + simulation tests | `app/lib/domain/**` (except presets), `app/test/{rule_engine,training_load,program,limitations,simulation}_test.dart` | §4.1, 4.3, 4.6, 4.7 |
| D1 | App data layer: drift `feedback_entries`, `metaJson`, schema v2 migration, sync, repository | `app/lib/data/**`, `app/test/sync_repository_test.dart` | §4.3 |
| D2 | App services & UI: brief builder, stateless AI calls, pre-generation, report-an-issue flow, balance screen, plan rationale, coach screen | `app/lib/services/**`, `app/lib/features/**`, `app/lib/widgets/**`, `app/lib/providers.dart`, UI tests | C, D1, B contract |
| E | Integration, deploy, live AI evaluation, docs | all | A–D |

## 6. Validation

1. **Unit tests** for effective-set counting, targets/status/priorities, program state (blocks, gaps, deload
   triggers), limitation policy, progression trends, brief size limits, backend limitation filter and validator.
2. **12-week simulation** (`app/test/simulation_test.dart`): a synthetic athlete completes every generated plan
   (reps from the plan, weights from progression). Pass criteria:
   - Variation: consecutive same-day-type sessions share < 80 % of main exercises (A/B), while ≥ 1 anchor per variant
     persists through a block; ≥ 60 % of accessory exercises change between blocks.
   - Balance: over every 4-week window each tracked muscle's average weekly effective sets is ≥ `min` (≥ 80 % of `min`
     for traps, forearms, adductors, abductors, lower back) and ≤ 1.5 × `max`; no muscle below `min` for > 2
     consecutive weeks.
   - Adaptivity: injecting a biceps deficit raises biceps volume the next week; a neck-pain entry (severity 2)
     removes every neck-stress exercise from all later plans until resolved.
   - Badminton: ≤ 1 power exercise per session, ≤ 2 per week. Time budget within sessionMinutes + 5.
   - Progression: anchor lifts show monotonically non-decreasing target loads within a block (except deload).
3. **Backend tests** for stateless endpoints with a fake model, the limitation filter, feedback sync, Table usage.
4. **Live AI evaluation** (`WFIT_LIVE_AI=1`): scenario briefs (neck pain, biceps deficit, stalled anchor, deload
   week, "leg press broken") run against the deployed model; asserts hard constraints and that the rationale
   references the scenario.
5. **Telemetry after deploy:** AI request p50/p90 and token usage from App Insights.
