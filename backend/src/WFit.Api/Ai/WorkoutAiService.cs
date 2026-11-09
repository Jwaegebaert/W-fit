using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>
/// Eligible exercises of one day type, per catalog category and per workout block. Main-section candidates also include
/// eligible off-split exercises that are already in the draft / plan (the rule engine's flex slot) and, when priority
/// muscles are given, a separate <see cref="Flex"/> list of off-split exercises for them (the validator allows one).
/// Eligibility (equipment, occupied, bans, difficulty, limitations) is always enforced.
/// </summary>
public sealed class DayCandidates
{
    public const int MaxFlexCandidates = 12;

    public DayCandidates(
        CatalogService catalog,
        SelectionContext ctx,
        string dayType,
        bool includeCore,
        ISet<string>? excludeIds = null,
        IEnumerable<string?>? planIds = null,
        IEnumerable<string>? flexMuscles = null)
    {
        Context = ctx;
        var pool = catalog.Exercises.Where(e => excludeIds is null || !excludeIds.Contains(e.Id)).ToList();
        var byCategory = ExerciseSelector.CandidatesByCategory(pool, ctx, dayType)
            .Where(kv => includeCore || kv.Key != Vocab.Category.Core)
            .ToDictionary(kv => kv.Key, kv => kv.Value.ToList());

        var daySplit = new HashSet<string>(byCategory.Values.SelectMany(l => l).Select(e => e.Id), StringComparer.Ordinal);
        var offSplit = pool.Where(e => Vocab.IsMain(e.Category) && !daySplit.Contains(e.Id) && ExerciseSelector.IsEligible(e, ctx)).ToList();
        var inPlan = new HashSet<string>((planIds ?? []).OfType<string>(), StringComparer.Ordinal);
        var muscles = new HashSet<string>(flexMuscles ?? [], StringComparer.Ordinal);
        Flex = muscles.Count == 0
            ? []
            : offSplit.Where(e => e.Category == Vocab.Category.Strength && !inPlan.Contains(e.Id) && e.Primary.Any(muscles.Contains))
                .OrderByDescending(e => e.Primary.Count(muscles.Contains))
                .ThenBy(e => e.Difficulty)
                .Take(MaxFlexCandidates)
                .ToList();
        foreach (var e in offSplit.Where(e => inPlan.Contains(e.Id)).Concat(Flex))
        {
            if (!byCategory.TryGetValue(e.Category, out var list)) byCategory[e.Category] = list = [];
            list.Add(e);
        }
        ByCategory = byCategory.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<CatalogExerciseItem>)kv.Value);

        FlexIds = new HashSet<string>(Flex.Select(e => e.Id), StringComparer.Ordinal);
        Warmup = Of(Vocab.Category.Warmup);
        Main = Of(Vocab.Category.Power, Vocab.Category.Strength).Where(e => !FlexIds.Contains(e.Id)).ToList();
        Core = includeCore ? Of(Vocab.Category.Core) : [];
        Cooldown = Of(Vocab.Category.Cooldown);
        Ids = new HashSet<string>(Warmup.Concat(Main).Concat(Flex).Concat(Core).Concat(Cooldown).Select(e => e.Id), StringComparer.Ordinal);
    }

    public SelectionContext Context { get; }
    public IReadOnlyDictionary<string, IReadOnlyList<CatalogExerciseItem>> ByCategory { get; }
    public IReadOnlyList<CatalogExerciseItem> Warmup { get; }
    public IReadOnlyList<CatalogExerciseItem> Main { get; }
    /// <summary>Off-split exercises for priority muscles; at most one may be used (main block).</summary>
    public IReadOnlyList<CatalogExerciseItem> Flex { get; }
    public IReadOnlySet<string> FlexIds { get; }
    public IReadOnlyList<CatalogExerciseItem> Core { get; }
    public IReadOnlyList<CatalogExerciseItem> Cooldown { get; }
    public ISet<string> Ids { get; }

    public object View() => new
    {
        warmup = Warmup.Select(e => AiPrompts.CandidateView(e, Context.Limitations)),
        main = Main.Select(e => AiPrompts.CandidateView(e, Context.Limitations)),
        flex = Flex.Count == 0 ? null : Flex.Select(e => AiPrompts.CandidateView(e, Context.Limitations)),
        core = Core.Select(e => AiPrompts.CandidateView(e, Context.Limitations)),
        cooldown = Cooldown.Select(e => AiPrompts.CandidateView(e, Context.Limitations)),
    };

    private IReadOnlyList<CatalogExerciseItem> Of(params string[] categories) =>
        categories.SelectMany(c => ByCategory.TryGetValue(c, out var l) ? l : []).ToList();
}

/// <summary>POST /ai/workout — stateless: brief + rule-engine draft in, refined and validated plan out (not persisted).</summary>
public sealed class WorkoutAiService(CatalogService catalog, AiGateway ai, TimeProvider time)
{
    public async Task<AiWorkoutResponse> GenerateAsync(AiWorkoutRequest request, CancellationToken ct)
    {
        if (request.DayType is not { } dayTypeValue) throw ApiException.BadRequest("dayType is required (push|pull|legs).");
        var dayType = dayTypeValue.ToWire();
        var brief = CoachBriefRules.Sanitize(request.Brief);
        var serverToday = DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime);
        var today = CoachBriefRules.ParseDate(brief.Today) ?? request.Date ?? serverToday;
        var date = request.Date ?? today;

        var sessionMinutes = Math.Clamp(request.SessionMinutes ?? (int?)brief.Profile?.SessionMinutes ?? 60, 20, 120);
        var includeCore = request.IncludeCore ?? brief.Profile?.IncludeCore ?? true;
        var deload = brief.IsDeload() || request.Draft?.Meta?.Deload == true;

        var ctx = brief.ToSelectionContext(catalog, today);
        var draftIds = PlanIds(request.Draft);
        var candidates = new DayCandidates(catalog, ctx, dayType, includeCore, planIds: draftIds, flexMuscles: brief.PriorityMuscles(ctx.Limitations));
        if (candidates.Main.Count < AiOutputValidator.MinMainItems)
            throw ApiException.AiUnavailable("Not enough eligible exercises for this day with the current equipment and limitations.");

        var context = new
        {
            request = new
            {
                today = AiPrompts.Date(today),
                date = AiPrompts.Date(date),
                dayType,
                sessionMinutes,
                includeCore,
                deload,
                userNote = string.IsNullOrWhiteSpace(request.UserNote) ? null : SyncMapper.Trunc(request.UserNote.Trim(), 500),
            },
            draft = request.Draft is { } d
                ? new
                {
                    title = d.Title is null ? null : SyncMapper.Trunc(d.Title, 100),
                    blocks = AiPrompts.PlanView(d.Blocks, catalog, candidates.Ids, ctx),
                    meta = AiPrompts.MetaView(d.Meta),
                }
                : null,
            brief,
            candidates = candidates.View(),
        };

        var prompt = new AiPrompt("workout_plan", AiPrompts.WorkoutSystem, AiPrompts.Serialize(context),
            AiSchemas.Workout(candidates.Ids), AiEffort.Low);
        var output = await ai.CompleteJsonAsync<AiWorkoutOutput>(prompt, ct);

        var validated = AiOutputValidator.ValidateWorkout(output, candidates.ByCategory, includeCore, dayType, sessionMinutes, deload, candidates.FlexIds);
        var meta = AiOutputValidator.ValidateMeta(
            output.Focus, output.Rationale, output.Changes, validated.ExerciseIds, catalog,
            request.Draft?.Meta?.Program ?? brief.ProgramLabel(dayType),
            request.Draft?.Meta?.Variant ?? brief.Program?.Variant,
            deload,
            ctx.Limitations);

        var workout = new AiWorkoutDto(
            Guid.NewGuid().ToString("D"), date, dayType, validated.Title, validated.CoachNote, validated.EstimatedMinutes, validated.Blocks, meta);
        return new AiWorkoutResponse(workout, await ai.GetUsageAsync(ct));
    }

    /// <summary>Exercise ids of the main block(s) of a draft / plan (the rule engine's flex slot may be off-split).</summary>
    public static IEnumerable<string?> PlanIds(PlanInput? plan) =>
        (plan?.Blocks ?? []).OfType<WorkoutBlockDto>()
            .Where(b => b.Section == WorkoutSection.Main.ToWire())
            .SelectMany(b => b.Items ?? [])
            .Select(i => i?.ExerciseId);
}
