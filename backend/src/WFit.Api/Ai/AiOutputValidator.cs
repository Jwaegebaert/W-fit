using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

public sealed record ValidatedWorkout(string Title, string CoachNote, int EstimatedMinutes, List<WorkoutBlockDto> Blocks);

/// <summary>Validates and clamps model output to catalog candidates and beginner-safe bounds.</summary>
public static class AiOutputValidator
{
    public const int MaxMainItems = 7;
    public const int MinMainItems = 2;
    public const int MaxOtherItems = 6;
    /// <summary>Floor exercises (equipment "mat") allowed per warm-up / core / cooldown block when standing options exist.</summary>
    public const int MaxFloorItemsPerBlock = 1;
    public const int MaxNoteLength = 300;

    private static readonly WorkoutSection[] SectionOrder =
        [WorkoutSection.Warmup, WorkoutSection.Main, WorkoutSection.Core, WorkoutSection.Cooldown];

    /// <param name="candidatesByCategory">Eligible exercises for the day, keyed by catalog category.</param>
    public static ValidatedWorkout ValidateWorkout(
        AiWorkoutOutput output,
        IReadOnlyDictionary<string, IReadOnlyList<CatalogExerciseItem>> candidatesByCategory,
        bool includeCore,
        string dayType,
        int sessionMinutes)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        var itemsBySection = SectionOrder.ToDictionary(s => s, _ => new List<WorkoutItemDto>());
        var floorBySection = SectionOrder.ToDictionary(s => s, _ => 0);

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

                used.Add(id);
                if (exercise.IsFloor) floorBySection[section]++;
                target.Add(ClampItem(item, exercise, section));
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

    public static WorkoutItemDto ClampItem(WorkoutItemDto item, CatalogExerciseItem exercise, WorkoutSection section)
    {
        var (repMin, repMax, duration) = Prescription(exercise, item.RepMin, item.RepMax, item.DurationSeconds);
        return new WorkoutItemDto
        {
            ExerciseId = exercise.Id,
            Sets = Math.Clamp(item.Sets, 1, 5),
            RepMin = repMin,
            RepMax = repMax,
            DurationSeconds = duration,
            RestSeconds = ClampRest(item.RestSeconds, section),
            TargetWeightKg = exercise.IsTimed ? null : ClampWeight(item.TargetWeightKg),
            Notes = SyncMapper.Trunc(item.Notes?.Trim(), MaxNoteLength),
        };
    }

    public static IReadOnlyList<SwapSuggestion> ValidateSwap(
        AiSwapOutput output, IReadOnlyList<CatalogExerciseItem> candidates, WorkoutSection section, int max = 3)
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
                Math.Clamp(s.Sets, 1, 5),
                repMin,
                repMax,
                ClampRest(s.RestSeconds, section)));
        }
        return result;
    }

    /// <summary>Catalog-default suggestions used when the model returns nothing valid.</summary>
    public static IReadOnlyList<SwapSuggestion> RuleSwaps(
        CatalogExerciseItem original, IEnumerable<CatalogExerciseItem> ranked, WorkoutSection section, int max = 3) =>
        ranked.Take(max).Select(e =>
        {
            var (repMin, repMax, _) = Prescription(e, e.RepMin, e.RepMax, null);
            return new SwapSuggestion(e.Id, RuleWhy(e, original), Math.Clamp(e.Sets, 1, 5), repMin, repMax, ClampRest(e.Rest, section));
        }).ToList();

    public static int ClampRest(int restSeconds, WorkoutSection section) =>
        section == WorkoutSection.Main ? Math.Clamp(restSeconds, 30, 240) : Math.Clamp(restSeconds, 0, 180);

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

    private static string RuleWhy(CatalogExerciseItem candidate, CatalogExerciseItem? original)
    {
        if (original is not null && candidate.Pattern == original.Pattern)
            return $"Same movement pattern ({candidate.Pattern.Replace('_', ' ')}).";
        var muscles = string.Join(", ", candidate.Primary.Select(m => m.Replace('_', ' ')));
        return $"Trains {muscles}.";
    }
}
