# W-fit architecture

## Overview

```
┌──────────────────────────────┐        HTTPS + X-Api-Key        ┌──────────────────────────────────┐
│ Flutter Android app          │ ───────────────────────────────▶ │ Azure Functions (.NET 10 isolated)│
│  • Riverpod state            │   POST /sync (push+pull)         │ Flex Consumption (scale to zero) │
│  • drift / SQLite (offline)  │   POST /ai/workout|swap|insights │  • API-key middleware            │
│  • Rule engine (no-AI path)  │                                  │  • EF Core → Azure SQL (MI auth)  │
│  • fl_chart statistics       │ ◀─────────────────────────────── │  • Azure OpenAI (MI auth)         │
└──────────────────────────────┘                                  │  • AI usage limiter               │
                                                                  └───────┬───────────────┬──────────┘
                                                                          │               │
                                                     Azure SQL free offer │               │ Azure OpenAI (<resource-group>)
                                                     serverless, AutoPause│               │ gpt-4.1-mini, 20K TPM
```

### Principles
1. **Offline-first.** The phone's SQLite database is the working copy. Every workout, set, bodyweight entry and setting is
   written locally first and queued for sync. The app is fully usable with no network and no AI.
2. **AI is an enhancement, never a dependency.** A deterministic on-device rule engine generates Push/Pull/Legs workouts,
   applies double progression and proposes swaps. AI responses are constrained to catalog exercise IDs and validated.
3. **One catalog.** `app/assets/data/catalog.json` (equipment + 100+ exercises with muscles, movement pattern, equipment,
   default prescription, badminton relevance, instructions) is bundled in the app and embedded in the backend.
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

**Session template (60 min default).** Warm-up ≈ 8 min (1 cardio + 3 activation/mobility for the split),
main block fills the remaining budget, optional core ≈ 6 min (2 exercises with different patterns), cooldown ≈ 6 min
(4 stretches for the split). Main slots by priority:

| Day | Slot order (movement patterns) |
|---|---|
| Push | plyo_upper (power, fresh) · horizontal_push · vertical_push · incline_push · lateral_raise · triceps · chest_fly |
| Pull | vertical_pull · horizontal_pull · plyo_upper · rear_delt · biceps · vertical_pull/horizontal_pull variant |
| Legs | plyo_lower (power, fresh) · squat · hinge · lunge · knee_flexion · calf · hip_abduction |

Exercise time ≈ `sets × (40 s work + rest) + 60 s setup`. Slots are added until the main budget is used.
Exercise choice per slot: not already used → previously used for this slot (consistency helps beginners progress) →
liked → lower difficulty → compound first.

**Double progression.** Per exercise, look at the last session's working sets:
all sets ≥ `repMax` ⇒ add `incrementKg` and target `repMin`; two consecutive sessions below `repMin` ⇒ −10 %;
otherwise keep the weight and aim for +1 rep. New exercises start light at ~3 reps in reserve.

**Swaps.** Rank eligible exercises in the same category: same movement pattern (+3), primary-muscle overlap (+2 each),
secondary overlap (+1), same split (+1), liked (+1), disliked (−2), difficulty above level (−2).
*Occupied* excludes the equipment for the current session only. *Unavailable* marks the equipment permanently
unavailable in settings (synced to the server and respected by AI generation).

## AI integration (server-side only)
- Azure OpenAI chat completions with **structured outputs** (`response_format: json_schema`, strict).
- The server builds a compact candidate list (id, name, pattern, primary muscles) filtered by equipment, preferences
  and day type; the model may only return IDs from that list. Output is validated and clamped to beginner-safe ranges.
- Context is bounded: profile, equipment summary, last 6 sessions summarised as top sets per exercise.
- Limits: daily call limit, monthly token cap, per-call `max_tokens`, insights cached per day, kill switch.
- Authentication via the Function App's managed identity (`Cognitive Services OpenAI User`); no keys.

## Security
- API key header for the single user (generated at deploy time, stored only in Key Vault and in the phone's
  encrypted storage). HTTPS only, TLS 1.2+, FTP disabled.
- SQL uses Entra-only authentication with the Function App's managed identity. No SQL passwords exist.
- No secrets in the repository; `local.settings.json` is git-ignored.
