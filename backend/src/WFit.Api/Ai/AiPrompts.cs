using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using WFit.Api.Domain;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>System prompts (compact; data goes in the user message as JSON) and the compact JSON views sent to the model.</summary>
public static class AiPrompts
{
    private static readonly JsonSerializerOptions ContextJson = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private const string Coach = """
        You are W-fit's head coach: an elite, evidence-based strength & hypertrophy coach for one athlete (data in the JSON).
        Primary goal: balanced strength and muscle across all tracked muscles. Badminton is secondary: at most 1 power/plyometric
        exercise per session (early, low volume); mobility/stability drills in the warm-up are welcome.
        """;

    private const string Safety = """
        Safety: never load an injured region. Candidates are pre-filtered for equipment, bans, difficulty and limitations; items
        with "caution" are allowed only if nothing else fits; "blocked" plan items must be replaced. Explain substitutions in a few
        words. For severe or persistent pain or red flags (radiating pain, numbness, tingling, weakness, swelling, pain after a
        fall, night pain) advise assessment by a physiotherapist or doctor; never diagnose.
        """;

    public const string WorkoutSystem = Coach + """

        Task: refine the rule-engine "draft" for today into the final session. Input: request fields, draft, brief (profile,
        equipment, preferences, limitations, exerciseFeedback, program, balance, exerciseHistory, recentSessions, weekly) and
        candidates per block (only these ids are allowed).

        Principles:
        1. Keep the draft unless the data justifies a change; never change for variety alone. Every change needs a data reason.
        2. Program: follow brief.program (block week, phase, variant, targetRir). Anchor lifts stay for the whole block so they
           can progress; vary accessories only at block boundaries or when stalled, disliked or contraindicated. Deload: <= 3 sets
           per exercise, ~90% load, RIR 3-4, no new exercises.
        3. Progression (double progression) from exerciseHistory: all sets at the top of the rep range last time -> add the
           smallest increment ("inc") and return to the bottom of the range; otherwise same load, +1 rep. stalled -> change rep
           range, use a close variation or drop 5-10% and rebuild; regressing -> reduce load, check fatigue. too_hard -> -1
           increment or easier variation; too_easy -> +1 increment. New exercise -> targetWeightKg null, note "start light, ~3 RIR".
           Train at targetRir, never to failure.
        4. Volume & balance: balance.muscles = weekly effective sets (primary 1, secondary 0.5) vs targetMin-targetMax. Muscles
           under target or in priorities that fit today's split: +1 set on an exercise that trains them or a short accessory
           (<= +3 sets per session). Over targetMax: -1 set (min 2). Don't load a muscle trained < 48 h ago (daysSinceTrained < 2)
           unless it is today's main target. Keep push:pull near 1 and quad:ham near 1-1.5.
        5. Use exerciseFeedback, session notes, rating/effort and userNote (high effort or low rating -> no load jumps).
        6. Shape: warmup ~8 min (1 easy cardio + 2-3 activation/mobility drills for today's muscles); main 4-7 exercises (power
           first if any, heavy compounds 6-10 reps, other compounds 8-12, isolation 10-15); core ~6 min (2 different patterns)
           only if includeCore; cooldown 2-3 stretches. candidates.flex (other splits, for priority muscles): at most 1, as a short accessory, only when today's split can't cover the priority. Time per exercise ~ sets x (40 s + rest) + 60 s; estimatedMinutes <=
           sessionMinutes. Rest: compounds 120-180 s, isolation 60-90 s, power 90-120 s, warm-up/cooldown 0-30 s. Max 1 floor
           exercise ("floor") per warmup/core/cooldown block. Rep items: repMin/repMax, durationSeconds null; timed items:
           durationSeconds, reps null.

        """ + Safety + """

        Output: title <= 6 words. coachNote 1-3 short sentences (focus, key progression, limitation note if any). Item notes
        <= 12 words (load cue or progression hint). rationale: 2-6 lines, each citing concrete data, e.g. "Biceps 3.5 of 4-10
        sets -> +1 set on cable curls" or "Chest press stalled 3 sessions -> 10-12 reps at 50 kg". focus: muscles you
        deliberately prioritised. changes: every draft exercise you replaced (from = draft id, to = new id, short reason).
        Concise English. JSON only.
        """;

    public const string AdjustSystem = Coach + """

        Task: the athlete sent a short message, maybe mid-session. Input: message, exerciseId (exercise on screen, may be null),
        sessionInProgress, plan (may be null), brief and candidates (safe exercises for the plan's day).
        1. Turn the message into 0-3 feedback entries:
           - pain (hurts, sharp, injury) / discomfort (tight, niggle, a bit sore): region (neck, shoulder, elbow, wrist,
             upper_back, lower_back, hip, knee, ankle) and severity 1 mild (noticeable, not limiting), 2 moderate (limits
             loading or keeps coming back), 3 severe (sharp, worsening or red flags). exerciseId when tied to one exercise.
             Normal post-training muscle soreness is not pain (use note).
           - unavailable: broken, missing or taken equipment -> exerciseId of the affected exercise and equipmentId when clear.
           - too_easy / too_hard: load or difficulty of an exercise. like / dislike: preferences. note: anything else useful.
           reviewInDays: pain 7, discomfort 14 (fewer if clearly transient, max 42); null for other kinds. note: one short
           sentence in the athlete's terms.
        2. If a plan is given and the feedback affects it, return the adjusted plan: replace every exercise that loads a painful
           region (severity >= 2, or severity 1 when an alternative exists) or needs unavailable equipment with the closest
           candidate (same pattern/muscles); keep everything else (order, sets, loads). too_hard -> ~10% less load or an
           easier variant; too_easy -> +1 increment. If sessionInProgress, change only what's needed. rationale explains each
           change; changes lists replacements. If nothing in the plan must change, plan = null.
        3. reply: 1-3 sentences, empathetic and practical: what changed and what to do now (pain: stop that exercise, keep any
           pain <= 3/10 while training).

        """ + Safety + """

        Concise English. JSON only.
        """;

    public const string SwapSystem = Coach + """

        Task: suggest up to 3 replacements for the original exercise, only ids from candidates (pre-filtered, ranked by
        similarity; "caution" = only if nothing better fits). Prefer the same movement pattern and primary muscles so
        progression and weekly balance stay intact; respect reason, note, limitations, exerciseFeedback and preferences; for
        warm-up/core/cooldown prefer non-floor options. Each: "why" (<= 15 words) and a prescription matching the program
        (targetRir; deload <= 3 sets): sets 2-4, repMin/repMax (null for timed), restSeconds. JSON only.
        """;

    public const string InsightsSystem = Coach + """

        Task: review the coach brief (weekly effective sets per muscle vs targets, priorities, push:pull and quad:ham ratios,
        program block/phase, exercise trends, recent sessions with rating/effort/notes, feedback, limitations, weekly totals).
        Use only the data given and cite numbers; never invent data.
        - summary: 2-3 sentences on consistency, progression and balance.
        - highlights: up to 4 specific wins with numbers.
        - recommendations: up to 4 actionable items, most impactful first (under-trained muscles and how to fix them, stalled
          lifts, recovery/effort, consistency, active limitations). Mention badminton only if relevant.
        - nextFocus: one sentence for the coming week.
        - focusMuscles: up to 3 tracked muscles to prioritise next (never muscles related to a painful region).
        Active pain: be supportive; suggest professional assessment if severe or persistent; never diagnose.
        Each item <= 30 words. Concise English. JSON only.
        """;

    /// <summary>Compact candidate view (the id is descriptive, so names are omitted to save tokens).</summary>
    public static Dictionary<string, object?> CandidateView(CatalogExerciseItem e, LimitationFilter limits)
    {
        var main = Vocab.IsMain(e.Category);
        var view = new Dictionary<string, object?>
        {
            ["id"] = e.Id,
            ["pattern"] = e.Pattern,
            ["primary"] = e.Primary,
        };
        if (main && e.Secondary.Count > 0) view["secondary"] = e.Secondary;
        if (main && e.Equipment.Count > 0) view["equipment"] = e.Equipment;
        if (!main && e.IsFloor) view["floor"] = true;
        if (e.Category == Vocab.Category.Power) view["power"] = true;
        view["sets"] = e.Sets;
        if (e.IsTimed) view["sec"] = e.DurationSeconds;
        else if (e.RepMin is { } min) view["reps"] = $"{min}-{e.RepMax ?? min}";
        view["rest"] = e.Rest;
        if (e.IncrementKg > 0) view["inc"] = e.IncrementKg;
        if (e.Difficulty > 1) view["difficulty"] = e.Difficulty;
        var verdict = limits.Evaluate(e);
        if (verdict.Effect == LimitationEffect.Penalised) view["caution"] = verdict.Reason;
        return view;
    }

    /// <summary>Plan blocks for the prompt; items the athlete can't do today are marked "blocked" with the reason.</summary>
    public static object? PlanView(IEnumerable<WorkoutBlockDto?>? blocks, CatalogService catalog, ISet<string> allowedIds, SelectionContext ctx)
    {
        if (blocks is null) return null;
        return blocks.OfType<WorkoutBlockDto>().Take(6).Select(b => new
        {
            section = b.Section,
            items = (b.Items ?? []).Where(i => i is not null).Take(12).Select(i =>
            {
                var item = new Dictionary<string, object?> { ["id"] = i.ExerciseId, ["sets"] = i.Sets };
                if (i.RepMin is { } min) item["reps"] = $"{min}-{i.RepMax ?? min}";
                if (i.DurationSeconds is { } sec) item["sec"] = sec;
                item["rest"] = i.RestSeconds;
                if (i.TargetWeightKg is { } kg) item["kg"] = kg;
                if (!string.IsNullOrWhiteSpace(i.Notes)) item["notes"] = SyncMapper.Trunc(i.Notes, 120);
                if (!allowedIds.Contains(i.ExerciseId ?? "")) item["blocked"] = BlockedReason(catalog.FindExercise(i.ExerciseId), ctx);
                return item;
            }).ToList(),
        }).ToList();
    }

    public static object? MetaView(PlanMetaInput? meta) => meta is null
        ? null
        : new
        {
            program = meta.Program is null ? null : SyncMapper.Trunc(meta.Program, 100),
            variant = meta.Variant is null ? null : SyncMapper.Trunc(meta.Variant, 16),
            deload = meta.Deload,
            focus = meta.Focus?.OfType<string>().Take(AiOutputValidator.MaxFocus + 2).ToList(),
            rationale = meta.Rationale?.OfType<string>().Take(AiOutputValidator.MaxRationaleLines)
                .Select(r => SyncMapper.Trunc(r, AiOutputValidator.MaxRationaleLength)).ToList(),
        };

    public static string BlockedReason(CatalogExerciseItem? exercise, SelectionContext ctx)
    {
        if (exercise is null) return "unknown exercise";
        var verdict = ctx.Limitations.Evaluate(exercise);
        if (verdict.Effect == LimitationEffect.Excluded) return verdict.Reason!;
        if (!exercise.Equipment.All(eq => ExerciseSelector.IsEquipmentUsable(eq, ctx))) return "equipment unavailable or occupied";
        if (ctx.PreferenceOf(exercise.Id) == Vocab.Preference.Banned) return "banned by the athlete";
        if (exercise.Difficulty > ExerciseSelector.MaxDifficulty(ctx.Experience)) return "too advanced for the athlete's level";
        return "not allowed in this block today";
    }

    public static string Date(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static string Serialize(object context) => JsonSerializer.Serialize(context, ContextJson);
}
