using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

public sealed record ValidatedWorkout(string Title, string CoachNote, int EstimatedMinutes, List<WorkoutBlockDto> Blocks)
{
    public IEnumerable<string> ExerciseIds => Blocks.SelectMany(b => b.Items).Select(i => i.ExerciseId);
}

/// <summary>Validates and clamps model output to the candidates, safe prescriptions and the contract vocabularies.</summary>
public static class AiOutputValidator
{
    public const int MaxMainItems = 7;
    public const int MinMainItems = 2;
    public const int MaxOtherItems = 6;
    /// <summary>Floor exercises (equipment "mat") allowed per warm-up / core / cooldown block when standing options exist.</summary>
    public const int MaxFloorItemsPerBlock = 1;
    public const int MaxNoteLength = 300;
    public const int MaxSets = 5;
    public const int MaxDeloadSets = 3;
    public const int MaxFlexItems = 1;
    public const int MaxFocus = 4;
    public const int MaxRationaleLines = 6;
    public const int MaxRationaleLength = 240;
    public const int MaxChanges = 8;
    public const int MaxChangeReason = 200;
    public const int MaxFeedback = 5;
    public const int MaxFeedbackNote = 2000;
    public const int MinReviewDays = 1;
    public const int MaxReviewDays = 42;
    public const int DefaultPainReviewDays = 7;
    public const int DefaultDiscomfortReviewDays = 14;

    private static readonly WorkoutSection[] SectionOrder =
        [WorkoutSection.Warmup, WorkoutSection.Main, WorkoutSection.Core, WorkoutSection.Cooldown];

    /// <param name="candidatesByCategory">Eligible exercises for the day, keyed by catalog category.</param>
    /// <param name="deload">Deload week: every item is capped at <see cref="MaxDeloadSets"/> sets.</param>
    /// <param name="flexIds">Off-split flex candidates; at most <see cref="MaxFlexItems"/> of them in the main block.</param>
    public static ValidatedWorkout ValidateWorkout(
        AiWorkoutOutput output,
        IReadOnlyDictionary<string, IReadOnlyList<CatalogExerciseItem>> candidatesByCategory,
        bool includeCore,
        string dayType,
        int sessionMinutes,
        bool deload = false,
        IReadOnlySet<string>? flexIds = null)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        var itemsBySection = SectionOrder.ToDictionary(s => s, _ => new List<WorkoutItemDto>());
        var floorBySection = SectionOrder.ToDictionary(s => s, _ => 0);
        var flexUsed = 0;

        foreach (var block in output.Blocks ?? [])
        {
            if (block is null || Vocab.ParseSection(block.Section) is not { } section) continue;
            if (section == WorkoutSection.Core && !includeCore) continue;

            var allowed = Vocab.CategoriesFor(section);
            var target = itemsBySection[section];
            var limit = section == WorkoutSection.Main ? MaxMainItems : MaxOtherItems;
            var sectionCandidates = allowed
                .SelectMany(c => candidatesByCategory.TryGetValue(c, out var list) ? list : [])
                .ToList();
            // Extra floor work is only dropped when a standing / station alternative exists for the block.
            var limitFloor = section != WorkoutSection.Main && sectionCandidates.Any(e => !e.IsFloor);

            foreach (var item in block.Items ?? [])
            {
                if (target.Count >= limit) break;
                if (item?.ExerciseId is not { } id || used.Contains(id)) continue;
                var exercise = sectionCandidates.FirstOrDefault(e => e.Id == id);
                if (exercise is null) continue;
                if (limitFloor && exercise.IsFloor && floorBySection[section] >= MaxFloorItemsPerBlock) continue;
                if (flexIds?.Contains(id) == true)
                {
                    if (flexUsed >= MaxFlexItems) continue;
                    flexUsed++;
                }

                used.Add(id);
                if (exercise.IsFloor) floorBySection[section]++;
                target.Add(ClampItem(item, exercise, section, deload));
            }
        }

        var main = itemsBySection[WorkoutSection.Main];
        if (main.Count < MinMainItems)
            throw ApiException.AiUnavailable("The AI response did not contain a usable workout.");

        var blocks = SectionOrder
            .Where(s => itemsBySection[s].Count > 0)
            .Select(s => new WorkoutBlockDto { Section = s.ToWire(), Items = itemsBySection[s] })
            .ToList();

        var title = string.IsNullOrWhiteSpace(output.Title)
            ? $"{char.ToUpperInvariant(dayType[0])}{dayType[1..]} day"
            : SyncMapper.Trunc(output.Title.Trim(), 200);
        var estimated = output.EstimatedMinutes > 0 ? output.EstimatedMinutes : sessionMinutes;

        return new ValidatedWorkout(
            title,
            SyncMapper.Trunc(output.CoachNote?.Trim(), 2000),
            Math.Clamp(estimated, 10, 180),
            blocks);
    }

    public static WorkoutItemDto ClampItem(WorkoutItemDto item, CatalogExerciseItem exercise, WorkoutSection section, bool deload = false)
    {
        var (repMin, repMax, duration) = Prescription(exercise, item.RepMin, item.RepMax, item.DurationSeconds);
        return new WorkoutItemDto
        {
            ExerciseId = exercise.Id,
            Sets = Math.Clamp(item.Sets, 1, deload ? MaxDeloadSets : MaxSets),
            RepMin = repMin,
            RepMax = repMax,
            DurationSeconds = duration,
            RestSeconds = ClampRest(item.RestSeconds, section),
            TargetWeightKg = exercise.IsTimed || exercise.LoadType == "none" ? null : ClampWeight(item.TargetWeightKg),
            Notes = SyncMapper.Trunc(item.Notes?.Trim(), MaxNoteLength),
        };
    }

    /// <summary>
    /// Plan meta: focus ⊆ tracked muscles (minus muscles avoided for severe pain), ≤ 6 rationale lines of ≤ 240 chars,
    /// changes whose <c>from</c> is a catalog id and whose <c>to</c> is in the final plan.
    /// </summary>
    public static PlanMeta ValidateMeta(
        IEnumerable<string?>? focus,
        IEnumerable<string?>? rationale,
        IEnumerable<PlanChangeDto?>? changes,
        IEnumerable<string> planIds,
        CatalogService catalog,
        string? program,
        string? variant,
        bool deload,
        LimitationFilter? limits = null)
    {
        var avoided = limits?.AvoidedMuscles ?? new HashSet<string>();
        var validFocus = (focus ?? [])
            .Where(m => Anatomy.IsTrackedMuscle(m) && !avoided.Contains(m!))
            .Select(m => m!)
            .Distinct(StringComparer.Ordinal)
            .Take(MaxFocus)
            .ToList();

        var lines = (rationale ?? [])
            .Where(l => !string.IsNullOrWhiteSpace(l))
            .Select(l => Shorten(l!.Trim(), MaxRationaleLength))
            .Distinct(StringComparer.Ordinal)
            .Take(MaxRationaleLines)
            .ToList();

        var inPlan = new HashSet<string>(planIds, StringComparer.Ordinal);
        var validChanges = new List<PlanChange>();
        foreach (var c in changes ?? [])
        {
            if (validChanges.Count >= MaxChanges) break;
            if (c?.From is not { } from || c.To is not { } to || from == to) continue;
            if (!catalog.ExercisesById.ContainsKey(from) || !inPlan.Contains(to)) continue;
            if (validChanges.Any(v => v.From == from && v.To == to)) continue;
            validChanges.Add(new PlanChange(from, to, Shorten(c.Reason?.Trim() ?? "", MaxChangeReason)));
        }

        return new PlanMeta(
            string.IsNullOrWhiteSpace(program) ? null : SyncMapper.Trunc(program.Trim(), 100),
            string.IsNullOrWhiteSpace(variant) ? null : SyncMapper.Trunc(variant.Trim(), 16),
            deload,
            validFocus,
            lines,
            validChanges);
    }

    /// <summary>
    /// Feedback interpreted by <c>/ai/adjust</c>: kind / region vocabularies, severity 1–3 (pain/discomfort only, default
    /// pain 2 / discomfort 1), known exercise / equipment ids, note ≤ 2000, reviewInDays 1–42 (default pain 7, discomfort 14).
    /// Pain / discomfort need a region or an exercise; exercise feedback (too_easy, too_hard, like, dislike) needs an exercise;
    /// unavailable needs an exercise or equipment.
    /// </summary>
    public static IReadOnlyList<AdjustFeedback> ValidateFeedback(IEnumerable<AiFeedbackOutput?>? feedback, CatalogService catalog)
    {
        var result = new List<AdjustFeedback>();
        foreach (var f in feedback ?? [])
        {
            if (result.Count >= MaxFeedback) break;
            var kind = f?.Kind?.Trim().ToLowerInvariant();
            if (f is null || kind is null || !Vocab.FeedbackKinds.Contains(kind)) continue;

            var region = Anatomy.IsRegion(f.Region) ? f.Region : null;
            var exerciseId = catalog.FindExercise(f.ExerciseId)?.Id;
            var equipmentId = f.EquipmentId is { } eq && catalog.EquipmentById.ContainsKey(eq) ? eq : null;
            var painLike = Vocab.FeedbackKind.IsPainLike(kind);

            var valid = kind switch
            {
                Vocab.FeedbackKind.Pain or Vocab.FeedbackKind.Discomfort => region is not null || exerciseId is not null,
                Vocab.FeedbackKind.Unavailable => exerciseId is not null || equipmentId is not null,
                Vocab.FeedbackKind.TooEasy or Vocab.FeedbackKind.TooHard or Vocab.FeedbackKind.Like or Vocab.FeedbackKind.Dislike => exerciseId is not null,
                _ => true,
            };
            if (!valid) continue;

            int? severity = painLike ? Math.Clamp(f.Severity ?? (kind == Vocab.FeedbackKind.Pain ? 2 : 1), 1, 3) : null;
            int? review = f.ReviewInDays is { } days
                ? Math.Clamp(days, MinReviewDays, MaxReviewDays)
                : kind switch
                {
                    Vocab.FeedbackKind.Pain => DefaultPainReviewDays,
                    Vocab.FeedbackKind.Discomfort => DefaultDiscomfortReviewDays,
                    _ => null,
                };
            var entry = new AdjustFeedback(
                kind,
                region,
                severity,
                exerciseId,
                kind == Vocab.FeedbackKind.Unavailable ? equipmentId : null,
                SyncMapper.Trunc(f.Note?.Trim(), MaxFeedbackNote),
                review);
            if (!result.Contains(entry)) result.Add(entry);
        }
        return result;
    }

    public static IReadOnlyList<SwapSuggestion> ValidateSwap(
        AiSwapOutput output, IReadOnlyList<CatalogExerciseItem> candidates, WorkoutSection section, int max = 3, bool deload = false)
    {
        var byId = candidates.ToDictionary(c => c.Id, StringComparer.Ordinal);
        var result = new List<SwapSuggestion>();
        foreach (var s in output.Suggestions ?? [])
        {
            if (result.Count >= max) break;
            if (s?.ExerciseId is not { } id || !byId.TryGetValue(id, out var exercise) || result.Any(r => r.ExerciseId == id))
                continue;
            var (repMin, repMax, _) = Prescription(exercise, s.RepMin, s.RepMax, null);
            result.Add(new SwapSuggestion(
                id,
                string.IsNullOrWhiteSpace(s.Why) ? RuleWhy(exercise, null) : SyncMapper.Trunc(s.Why.Trim(), MaxNoteLength),
                Math.Clamp(s.Sets, 1, deload ? MaxDeloadSets : MaxSets),
                repMin,
                repMax,
                ClampRest(s.RestSeconds, section)));
        }
        return result;
    }

    /// <summary>Catalog-default suggestions used when the model returns nothing valid.</summary>
    public static IReadOnlyList<SwapSuggestion> RuleSwaps(
        CatalogExerciseItem original, IEnumerable<CatalogExerciseItem> ranked, WorkoutSection section, int max = 3, bool deload = false) =>
        ranked.Take(max).Select(e =>
        {
            var (repMin, repMax, _) = Prescription(e, e.RepMin, e.RepMax, null);
            return new SwapSuggestion(e.Id, RuleWhy(e, original), Math.Clamp(e.Sets, 1, deload ? MaxDeloadSets : MaxSets),
                repMin, repMax, ClampRest(e.Rest, section));
        }).ToList();

    public static int ClampRest(int restSeconds, WorkoutSection section) =>
        section == WorkoutSection.Main ? Math.Clamp(restSeconds, 30, 240) : Math.Clamp(restSeconds, 0, 180);

    public static List<string> CleanList(IEnumerable<string?>? items, int maxItems, int maxLength) =>
        (items ?? []).Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => Shorten(s!.Trim(), maxLength)).Take(maxItems).ToList();

    /// <summary>Reps for rep-based exercises (3–20, min ≤ max), duration for timed ones (10–600 s).</summary>
    private static (int? RepMin, int? RepMax, int? Duration) Prescription(
        CatalogExerciseItem exercise, int? repMin, int? repMax, int? durationSeconds)
    {
        if (exercise.IsTimed)
            return (null, null, Math.Clamp(durationSeconds ?? exercise.DurationSeconds ?? 30, 10, 600));

        var min = Math.Clamp(repMin ?? exercise.RepMin ?? 8, 3, 20);
        var max = Math.Clamp(repMax ?? exercise.RepMax ?? Math.Max(min, 12), 3, 20);
        if (min > max) (min, max) = (max, min);
        return (min, max, null);
    }

    private static double? ClampWeight(double? kg)
    {
        if (kg is not { } w || !double.IsFinite(w) || w <= 0) return null;
        return Math.Round(Math.Min(w, 300) * 2, MidpointRounding.AwayFromZero) / 2;
    }

    private static string Shorten(string value, int max) => value.Length <= max ? value : value[..(max - 1)].TrimEnd() + "…";

    private static string RuleWhy(CatalogExerciseItem candidate, CatalogExerciseItem? original)
    {
        if (original is not null && candidate.Pattern == original.Pattern)
            return $"Same movement pattern ({candidate.Pattern.Replace('_', ' ')}).";
        var muscles = string.Join(", ", candidate.Primary.Select(m => m.Replace('_', ' ')));
        return $"Trains {muscles}.";
    }
}
