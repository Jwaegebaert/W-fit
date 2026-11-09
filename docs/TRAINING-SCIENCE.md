# W-fit training science

How the on-device training brain (`app/lib/domain`) turns well-established resistance-training principles into
concrete planning rules. Audience: anyone changing the engine, the coach brief or the AI prompts. The contracts live in
[IMPROVEMENT-PLAN.md](IMPROVEMENT-PLAN.md) §4; this document explains *why* the numbers are what they are.

The athlete: one beginner→novice lifter, Push / Pull / Legs 3× per week, ~60 min including warm-up, core and
cool-down, a machine-heavy gym with little floor space. Goals in order: balanced strength and hypertrophy, then
general athleticism (badminton is a secondary interest).

| Module | Responsibility |
|---|---|
| `muscles.dart` | Vocabulary, weekly effective-set bands (`min`–`max`) and the planning goal per muscle |
| `training_load.dart` | Effective sets per muscle and ISO week, balance status / priorities / ratios, exercise trends |
| `program.dart` | Blocks, block week, A/B variant, target RIR, deload (planned + early triggers) |
| `limitations.dart` | Pain / discomfort / exercise feedback → exclusions, penalties, load adjustments |
| `templates.dart` | A/B session templates, slot roles, rep / set / rest schemes |
| `rule_engine.dart` | Builds the plan (+ rationale, meta), swaps, instant re-planning after a pain report |
| `progression.dart` | Double progression with deload, feedback and RIR adjustments |

## 1. Progressive overload and double progression

**Evidence.** Novices progress best with a simple, steadily increasing load at moderate volume (ACSM 2009). Hypertrophy
is similar across a wide range of loads when sets are taken reasonably close to failure (Schoenfeld et al. 2021), so the
rep range can serve as the progression tool.

**Engine.** `adviseProgression()` uses double progression: keep the weight until *every* working set reaches the top of
the plan's rep range, then add the smallest increment (`incrementKg`) and restart at the bottom. Two sessions below the
range → −10 % reset, except for **anchor lifts inside a block** (`holdOnStruggle`), which hold the load so the deload
or the next block does the reset (keeps anchor loads monotonic within a block). Reported RIR ≥ 4 on all sets also
earns an increment. The engine computes target weights itself from `TrainingContext.history`, ignoring deload sessions,
so the first week of a new block continues from the last *normal* week.

## 2. Effort: reps in reserve (RIR)

**Evidence.** RIR-based effort scales are reliable even for novices (Zourdos et al. 2016; Helms et al. 2016). Training
close to – but not necessarily at – failure gives most of the hypertrophy with less fatigue (Refalo et al. 2023).

**Engine.** `ProgramState.targetRir`: block week 1 → 3 RIR (learn the movements, re-sensitise), weeks 2–3 → 2,
weeks 4–5 → 1–2, deload → 3–4. The coach note and the progression messages quote the target; RIR feedback in the set
log (`LoggedSet.rir`) feeds back into progression.

## 3. Volume targets and fractional sets

**Evidence.** Hypertrophy rises with weekly set volume with diminishing returns (Schoenfeld, Ogborn & Krieger 2017).
Indirect (synergist) work contributes roughly half as much as direct work, so counting secondary muscles as fractional
sets predicts outcomes better than direct-only counting (Pelland et al. 2024).

**Engine.** `effectiveSetsFor()`: a completed working set of a `strength`, `power` or `core` exercise counts 1.0 for
each primary and 0.5 (`secondarySetWeight`) for each secondary tracked muscle; warm-up / cool-down never count. Each
tracked muscle has a weekly band in `muscles.dart` (e.g. chest 6–12, side delts 5–10, traps 2–6). The engine plans
toward the **goal** = `min + 25 % of the band` (`MuscleTarget.goal`) rather than the bare minimum, because deload weeks
and normal week-to-week variation would otherwise pull multi-week averages below `min`. `max` marks where extra volume
mainly adds fatigue in a 3×/week, 60-min programme – it is a planning ceiling, not a physiological limit.

## 4. Frequency and recovery

**Evidence.** When volume is equated, training a muscle once or twice a week gives similar hypertrophy; twice is at
least as good (Schoenfeld, Ogborn & Krieger 2016). ~48 h between hard sessions for the same muscle is the conventional
recovery window for beginners (ACSM 2009).

**Engine.** PPL trains each muscle directly about once a week; the **flex slot** adds a second, small exposure for the
muscle that needs it most, but never for a muscle trained within the last 48 h (`daysSinceTrained`, shifted to the
plan date) and never twice in a week once it reached its minimum.

## 5. Balance and antagonist ratios

**Evidence.** Large push:pull or quadriceps:hamstring imbalances are commonly linked to shoulder and knee problems; the
hamstring:quadriceps ratio is a long-standing screening measure (Coombs & Garbutt 2002). The exact "ideal" ratio is not
well established, so W-fit uses ratios as *flags*, not targets.

**Engine.** `analyzeBalance()` computes per muscle: this week, last week, the average of the last 3 completed training
weeks (deload weeks excluded), status (under / ok / high), weeks-under streak, days since primary work and trend.
Priority score (0–1) = 0.35·last week's deficit vs `min` + 0.2·recent-average deficit + 0.15·streak + 0.15·staleness
(> 8 days without primary work, only while below goal) + 0.15·shortfall vs goal. The engine then:

- adds **+1 set** on today's slot that trains a priority muscle as a primary (≤ +3 per session, `extraSets` 1–2);
- gives the **flex slot** (2–3 sets) to the top priority muscle that is not trained by today's slots and not within
  48 h – including shortfalls inside the current week once that muscle's own day has passed;
- removes **−1 set** (min 2) from a non-anchor exercise whose primary muscles are all above `max`;
- when time is short, trims sets from exercises whose muscles are already at / above goal first.

Push:pull (pressing vs pulling sets) and quad:hamstring ratios over 4 weeks appear in the notes when outside
0.7–1.3 and 0.8–2.0. Because each muscle is mostly trained in one session, the small hip muscles alternate between
A and B weeks (e.g. abduction in Legs A, adduction in Legs B); their 2-week average is the meaningful number.

## 6. Block periodisation and deload

**Evidence.** Planned variation in volume/intensity with periodic reductions in load is standard practice (ACSM 2009).
A Delphi consensus of strength coaches describes deloads as short (≈ 1 week) periods of reduced volume and/or intensity,
used every 4–8 weeks or in response to fatigue signals (Bell et al. 2023).

**Engine.** `computeProgramState()` replays the session history: blocks of 6 training weeks (5 accumulation + 1 deload);
a training gap ≥ 14 days starts a new block; weeks without training do not consume the block. Early deload (from block
week 2, once per block) when the average perceived effort of the last 3 sessions is ≥ 8.5, the last two session ratings
are ≤ 2, or ≥ 2 anchor lifts are regressing. A deload covers the rest of that ISO week; the next week starts a new block.
Deload sessions: −1 set per exercise (min 2; anchors 2), ~90 % load, RIR 3–4, no power work, no balance extras.

## 7. Variation without randomness

**Evidence.** Rotating exercises within a sensible range keeps or improves hypertrophy and strength compared with a fixed
selection, while excessive, random variation hampers progress (Fonseca et al. 2014; Kassiano et al. 2022).

**Engine.** Deterministic rules, no random numbers:

- **A/B variants** alternate per exposure of each day type and differ in emphasis (table below).
- **Anchors** (heavy compound, 6–10 reps) are reused for every exposure of the same variant in a block – the engine
  reconstructs past slot picks from `SessionInfo.mainExerciseIds`, so a manual swap is respected. At a block boundary
  an anchor is kept if it is still progressing, and rotated to an equivalent variation (same pattern, similar
  muscles, not an anchor in the last two blocks) when its trend is stalled / regressing or it has served 2 blocks.
- **Secondaries and accessories** stay constant within a block per variant (progressable) and prefer exercises not
  used in the previous block (−3 / −5 score) and not used by the other variant (−3).
- Core patterns rotate per exposure; warm-up cardio rotates per day type and variant.

| Template | Emphasis | Slots (role: patterns) |
|---|---|---|
| Push A | Chest strength | anchor: horizontal_push · secondary: vertical_push / incline_push · accessory: lateral_raise (4 sets), chest_fly, triceps · flex |
| Push B | Shoulders & upper chest | anchor: vertical_push · secondary: incline_push / horizontal_push · accessory: lateral_raise (4 sets), chest_fly, triceps · flex |
| Pull A | Vertical pull | anchor: vertical_pull · secondary: horizontal_pull · accessory: rear_delt, biceps, pullover / forearm · flex |
| Pull B | Rows & traps | power: plyo_upper · anchor: horizontal_pull · secondary: vertical_pull · accessory: shrug / carry, rear_delt, biceps · flex |
| Legs A | Squat focus | power: plyo_lower · anchor: squat · secondary: hinge / hip_extension · accessory: knee_extension / lunge, knee_flexion, hip_abduction / hip_adduction / glute_isolation, calf · flex |
| Legs B | Hinge & hips | anchor: hinge · secondary: squat / lunge · accessory: knee_flexion, knee_extension / lunge, hip_adduction / glute_isolation / back_extension / hip_abduction, calf · flex |

Rep schemes (`RoleScheme`): power 3–6 reps, 3 sets · anchor 6–10, 3 sets (4 in weeks 4–5), rest 2–3 min · secondary
8–12, 3 sets, 90–120 s · accessory / flex 10–15, 3 / 2 sets, 45–75 s. Ranges are nudged toward the exercise's catalog
range and stay fixed within a block so double progression works; longer rests for heavy compounds follow
Schoenfeld et al. 2016 (rest intervals).

## 8. Pain and feedback (limitations)

**Evidence.** Continuing to train while keeping symptoms acceptable (pain-monitoring approach) works better for many
overuse complaints than complete rest (Silbernagel et al. 2007); persistent, severe or worsening pain needs a
professional assessment, which the coach recommends.

**Engine.** Every catalog exercise lists the body regions it stresses (`stress`). Active feedback entries become a
`LimitationPolicy`: region severity 1 → strong penalty (used only when nothing else fits), 2 → excluded, 3 → excluded
plus direct work for related muscles (e.g. neck → traps, elbow → biceps / triceps / forearms); exercise pain → excluded,
discomfort → paused 4 weeks then penalised; `too_hard` → −1 increment and easier variations preferred, `too_easy` →
+1 increment (both consumed by the next exposure). `RuleEngine.adjustForLimitations()` re-plans instantly after a
report, keeping each slot's prescription, and records `{from, to, reason}` changes. Pain entries get a review date
(pain +7 days, discomfort +14) so the app asks whether they are resolved.

## 9. Badminton (secondary goal)

**Evidence.** Plyometric training improves jump performance with modest weekly doses (de Villarreal et al. 2009); it
does not need to dominate a strength programme.

**Engine.** One power slot per week in the templates (jumps in Legs A, smash-like upper-body power in Pull B), placed
first while fresh, hard-capped at ≤ 1 per session and ≤ 2 per ISO week, skipped in deloads, protected once per week
but shortened / dropped before strength volume when time runs out. In warm-up, core and cool-down selection badminton
relevance is only a 0.1-point tie-breaker.

## 10. Time budget

Plans must fit `sessionMinutes` (+3 min tolerance; validated at +5). Time is trimmed in this order: third warm-up
drill → second power exercise of the week → core exercise whose muscles are above target → flex 3→2 sets →
accessories of saturated muscles 3→2 → protected power 3→2 → other accessories 3→2 → power → flex → accessories →
anchor 4→3 / secondary 3→2. At least 3 main exercises always remain.

## 11. Validation (`app/test/simulation_test.dart`)

A deterministic synthetic athlete completes every generated plan for 14 weeks (2 full blocks + 2 weeks) in a classic
machine gym, with fatigue across sets, occasional missed reps and diminishing novice gains. Results with catalog v3
(225 exercises):

- A/B overlap of consecutive same-day sessions: max 17 % (limit < 80 %); anchors persist within every block.
- Accessories new between blocks: 95 % and 100 % (limit ≥ 60 %).
- Every 4-week window of every muscle within [min (80 % for traps, forearms, adductors, abductors, lower back),
  1.5 × max]; no muscle below min for more than 2 consecutive weeks (deload weeks included).
- Skipping all biceps work for a week raises biceps volume the following week versus the baseline run; a severity-2
  neck-pain entry removes every neck-stress exercise (in the run: Smith squat, hack squat, Smith split squat, Smith
  calf raise, cable shrug, suitcase carry) until resolved, with explained substitutions.
- ≤ 1 power exercise per session, ≤ 2 per week (≈ 1 in practice); every plan ≤ 65 min (estimate).
- Anchor target loads never decrease within a block (except deload) and do increase.

## References

- American College of Sports Medicine (2009). Progression models in resistance training for healthy adults (position
  stand). *Medicine & Science in Sports & Exercise* 41(3):687–708.
- Bell L, et al. (2023). Integrating deloading into strength and physique sports training programmes: an international
  Delphi consensus approach. *Sports Medicine – Open*.
- Coombs R, Garbutt G (2002). Developments in the use of the hamstring/quadriceps ratio for the assessment of muscle
  balance. *Journal of Sports Science and Medicine* 1:56–62.
- de Villarreal ES, Kellis E, Kraemer WJ, Izquierdo M (2009). Determining variables of plyometric training for
  improving vertical jump height performance: a meta-analysis. *Journal of Strength and Conditioning Research* 23(2).
- Fonseca RM, et al. (2014). Changes in exercises are more effective than in loading schemes to improve muscle
  strength. *Journal of Strength and Conditioning Research* 28(11).
- Helms ER, Cronin J, Storey A, Zourdos MC (2016). Application of the repetitions in reserve-based rating of perceived
  exertion scale for resistance training. *Strength and Conditioning Journal* 38(4).
- Kassiano W, et al. (2022). Does varying resistance exercises promote superior muscle hypertrophy and strength gains?
  A systematic review. *Journal of Strength and Conditioning Research*.
- Pelland JC, et al. (2024). The resistance training dose response: meta-regressions exploring the effects of weekly
  volume and frequency on muscle hypertrophy and strength gain. *Sports Medicine* (preprint 2024).
- Refalo MC, et al. (2023). Influence of resistance training proximity-to-failure on skeletal muscle hypertrophy: a
  systematic review with meta-analysis. *Sports Medicine* 53.
- Schoenfeld BJ, Ogborn D, Krieger JW (2016). Effects of resistance training frequency on measures of muscle
  hypertrophy: a systematic review and meta-analysis. *Sports Medicine* 46(11).
- Schoenfeld BJ, Ogborn D, Krieger JW (2017). Dose-response relationship between weekly resistance training volume and
  increases in muscle mass: a systematic review and meta-analysis. *Journal of Sports Sciences* 35(11).
- Schoenfeld BJ, et al. (2016). Longer interset rest periods enhance muscle strength and hypertrophy in
  resistance-trained men. *Journal of Strength and Conditioning Research* 30(7).
- Schoenfeld BJ, Grgic J, et al. (2021). Loading recommendations for muscle strength, hypertrophy, and local endurance:
  a re-examination of the repetition continuum. *Sports* 9(2).
- Silbernagel KG, et al. (2007). Continued sports activity, using a pain-monitoring model, during rehabilitation in
  patients with Achilles tendinopathy: a randomized controlled study. *American Journal of Sports Medicine* 35(6).
- Zourdos MC, et al. (2016). Novel resistance training–specific rating of perceived exertion scale measuring
  repetitions in reserve. *Journal of Strength and Conditioning Research* 30(1).
