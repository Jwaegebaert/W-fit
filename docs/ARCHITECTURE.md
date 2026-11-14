# W-fit architecture

## Overview

```
┌──────────────────────────────┐        HTTPS + X-Api-Key        ┌──────────────────────────────────┐
│ Flutter Android app          │ ───────────────────────────────▶ │ Azure Functions (.NET 10 isolated)│
│  • Riverpod state            │   POST /sync (background)        │ Flex Consumption (scale to zero) │
│  • drift / SQLite (offline)  │   POST /ai/workout|adjust|swap|  │  • API-key middleware            │
│  • Training intelligence +   │        insights (+ coach brief)  │  • EF Core → Azure SQL (sync only)│
│    rule engine v2            │ ◀─────────────────────────────── │  • Azure OpenAI (MI auth)         │
│  • fl_chart statistics       │                                  │  • AI usage limits (Table Storage)│
└──────────────────────────────┘                                  └───────┬───────────────┬──────────┘
                                                                          │               │
                                                     Azure SQL free offer │               │ Azure OpenAI
                                                     serverless, AutoPause│               │ gpt-6-sol (+ gpt-6-luna fallback)
```

### Principles
1. **Offline-first.** The phone's SQLite database is the working copy. Every workout, set, bodyweight entry and setting is
   written locally first and queued for sync. The app is fully usable with no network and no AI.
2. **AI is an enhancement, never a dependency.** An on-device training-intelligence layer (muscle volume and balance,
   block periodisation, limitations from feedback) feeds a deterministic rule engine that drafts every workout,
   applies progression and proposes swaps. The AI refines that draft; its responses are constrained to catalog IDs,
   filtered by the same safety rules and validated.
3. **One catalog.** `app/assets/data/catalog.json` (v3: 41 equipment types with descriptions + 226 exercises with
   muscles, movement pattern, equipment, joint-stress regions, default prescription, badminton relevance,
   instructions, tip and common mistakes) is bundled in the app and embedded in the backend. Equipment `mat`
   ("Exercise mat / floor space") marks floor work: an exercise is a floor exercise ⇔ its `equipment` contains `mat`.
4. **Cheap by construction.** Scale-to-zero compute, free SQL offer with AutoPause on exhaustion, pay-per-token AI with
   hard server-side limits, capped telemetry. See `docs/COSTS.md`.

## Repository layout
| Path | Purpose |
|---|---|
| `app/` | Flutter Android app |
| `backend/` | .NET 10 isolated Azure Functions API + tests |
| `infra/` | Bicep templates + deploy script |
| `docs/API.md` | REST contract |
| `docs/COSTS.md` | Per-resource monthly cost estimate |

## Sync model
- Client-generated GUIDs, `updatedAt` on every record, soft deletes.
- `POST /sync` pushes dirty local rows and pulls rows changed since the last `serverTime` (last-write-wins).
- Sync runs on app start, after finishing a workout, after settings changes, and on manual pull-to-refresh. Failures
  are silent; dirty rows stay queued.

## Rule engine (on-device, mirrored conceptually by the server's candidate filter)
**Eligibility.** An exercise is eligible when all its `equipment` is available (unknown ⇒ available, `bodyweight`
always available), none of it is temporarily *occupied*, its preference isn't `banned`, and its difficulty fits the
experience level (beginner ⇒ difficulty ≤ 2, prefer 1).

**Day rotation.** Push → Pull → Legs, continuing after the last completed session, on the user's training days
(default Mon/Wed/Fri).

**Training intelligence (v3).** Pure Dart in `app/lib/domain`; principles and references in
[TRAINING-SCIENCE.md](TRAINING-SCIENCE.md), contracts in [IMPROVEMENT-PLAN.md](IMPROVEMENT-PLAN.md) §4.
- `training_load.dart`: effective sets per muscle per week (primary 1, secondary 0.5) for 19 tracked muscles, targets
  from `muscles.dart`, status (under/ok/high), weeks under, days since trained, priorities (carry-over of last week's
  deficit), push:pull and quad:ham ratios.
- `program.dart`: 6-week blocks (5 + deload, early deload on fatigue signals, new block after a ≥ 14-day gap),
  A/B variant per day type, target RIR per block week.
- `limitations.dart`: active feedback entries (pain/discomfort per body region and severity, per-exercise feedback)
  → exclusions and penalties via each exercise's `stress` regions.
- `templates.dart` + `rule_engine.dart`: A/B templates with slot roles (power ≤ 1/session, anchor, secondary,
  accessory, flex for the top-priority muscle). Anchors stay for a block (progressive overload); accessories rotate
  between blocks; balance priorities add or trim sets. Output includes rationale lines, focus muscles and plan meta.

**Session template (60 min default).** Warm-up ≈ 6–8 min (1 cardio + 2–3 activation/mobility drills), main block
fills the remaining budget, optional core ≈ 6 min (2 exercises with different patterns), cooldown ≈ 4 min
(3 stretches). Exercise time ≈ `sets × (40 s work + rest) + 60 s setup`.
**Machine and floor rules.** Designed for a machine-heavy gym with limited floor space:
- *Main lifts:* machines, cable stations and the Smith machine get a small bonus, kept below the anchor-continuity
  bonus so an established block (and its progression) is never reshuffled by it.
- *Warm-up, core, cool-down:* floor exercises (`mat`) get a −3 penalty, so standing / station options win when
  comparable, and each block holds at most 1 floor exercise. A second floor exercise is only picked when no standing /
  station candidate is left for that slot (a floor drill beats an empty slot).
- *Warm-up cardio:* the usable cardio machines (not unavailable, occupied or banned; best preference tier only) rotate
  deterministically by day type (push/pull/legs → 1st/2nd/3rd machine in catalog order), so a gym with bike,
  treadmill and elliptical gets each one once per rotation. Without machines, bodyweight cardio is used.
- *Swaps:* warm-up / core / cool-down swaps penalise floor candidates (−2); main swaps don't.

**Double progression.** Per exercise, look at the last session's working sets:
all sets ≥ `repMax` ⇒ add `incrementKg` and target `repMin`; two consecutive sessions below `repMin` ⇒ −10 %;
otherwise keep the weight and aim for +1 rep. New exercises start light at ~3 reps in reserve. Deload weeks use
~90 % load and one set less; "too hard" / "too easy" feedback moves the next load one increment.

**Swaps.** Rank eligible exercises in the same category: same movement pattern (+3), primary-muscle overlap (+2 each),
secondary overlap (+1), same split (+1), liked (+1), disliked (−2), difficulty above level (−2), floor exercise in a
warm-up / core / cool-down swap (−2); exercises excluded by active limitations are never offered.
*Occupied* excludes the equipment for the current session only. *Unavailable* marks the equipment permanently
unavailable in settings (synced to the server and respected by AI generation).

## AI integration (stateless, server-side model calls)
- The app builds a **coach brief** (profile, equipment, preferences, active limitations and exercise feedback,
  program state, muscle balance, 12-week exercise history with trends, recent sessions incl. notes) and sends it with
  each request; AI endpoints never read SQL, so a paused database never delays the coach.
- `/ai/workout` refines the rule-engine draft, `/ai/adjust` turns a free-text report ("my neck hurts", "leg press is
  broken") into feedback entries plus an adjusted plan, `/ai/swap` ranks alternatives, `/ai/insights` reviews the
  training. Contract: [API.md](API.md).
- Azure OpenAI `gpt-6-sol` (reasoning effort low; medium for insights) with strict **structured outputs**;
  `gpt-6-luna` is used once on throttling / 5xx / timeout. Model choice: [IMPROVEMENT-PLAN.md](IMPROVEMENT-PLAN.md) §3.
- Safety does not depend on the model: candidates are filtered server-side by equipment, bans, difficulty and the
  limitation filter (mirror of the app's policy); output ids outside the candidates are dropped and prescriptions
  are clamped (deload ≤ 3 sets).
- Latency is hidden: after a finished workout the app pre-generates the next session in the background; pain reports
  are applied instantly on the device and refined by the AI asynchronously; the app warms the Function host on start.
- Limits: daily call limit, monthly token cap, per-call `max_completion_tokens`, kill switch; counters in Table
  Storage. Authentication via the Function App's managed identity (`Cognitive Services OpenAI User`); no keys.
## Security
- API key header for the single user (generated at deploy time, stored only in Key Vault and in the phone's
  encrypted storage). HTTPS only, TLS 1.2+, FTP disabled.
- SQL uses Entra-only authentication with the Function App's managed identity. No SQL passwords exist.
- No secrets in the repository; `local.settings.json` is git-ignored.
