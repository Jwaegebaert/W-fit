namespace WFit.Api.Domain;

/// <summary>User state that decides which catalog exercises may be offered.</summary>
public sealed record SelectionContext(
    string Experience,
    IReadOnlyDictionary<string, bool> EquipmentAvailability,
    IReadOnlySet<string> OccupiedEquipment,
    IReadOnlyDictionary<string, string> Preferences,
    IReadOnlySet<string> AlwaysAvailableEquipment)
{
    public static SelectionContext Create(
        CatalogService catalog,
        string? experience,
        IReadOnlyDictionary<string, bool>? equipmentAvailability = null,
        IEnumerable<string>? occupiedEquipment = null,
        IReadOnlyDictionary<string, string>? preferences = null) =>
        new(
            string.IsNullOrWhiteSpace(experience) ? Vocab.Experience.Beginner : experience,
            equipmentAvailability ?? new Dictionary<string, bool>(),
            new HashSet<string>(occupiedEquipment ?? [], StringComparer.Ordinal),
            preferences ?? new Dictionary<string, string>(),
            new HashSet<string>(catalog.Equipment.Where(e => e.AlwaysAvailable).Select(e => e.Id).Append(CatalogService.BodyweightId), StringComparer.Ordinal));

    public string PreferenceOf(string exerciseId) =>
        Preferences.TryGetValue(exerciseId, out var p) ? p : Vocab.Preference.Neutral;
}

/// <summary>Pure candidate filtering and swap ranking (mirrors the on-device rule engine).</summary>
public static class ExerciseSelector
{
    public static int MaxDifficulty(string? experience) =>
        experience == Vocab.Experience.Intermediate ? 3 : 2;

    public static bool IsEquipmentUsable(string equipmentId, SelectionContext ctx)
    {
        if (ctx.AlwaysAvailableEquipment.Contains(equipmentId)) return true;
        if (ctx.OccupiedEquipment.Contains(equipmentId)) return false;
        return !ctx.EquipmentAvailability.TryGetValue(equipmentId, out var available) || available;
    }

    /// <summary>Equipment, occupation, ban and difficulty checks (independent of the day type).</summary>
    public static bool IsEligible(CatalogExerciseItem exercise, SelectionContext ctx) =>
        exercise.Equipment.All(eq => IsEquipmentUsable(eq, ctx))
        && ctx.PreferenceOf(exercise.Id) != Vocab.Preference.Banned
        && exercise.Difficulty <= MaxDifficulty(ctx.Experience);

    public static bool IsEligibleForDay(CatalogExerciseItem exercise, SelectionContext ctx, string dayType) =>
        exercise.Splits.Contains(dayType) && IsEligible(exercise, ctx);

    /// <summary>Eligible exercises for the day grouped by catalog category.</summary>
    public static IReadOnlyDictionary<string, IReadOnlyList<CatalogExerciseItem>> CandidatesByCategory(
        IEnumerable<CatalogExerciseItem> exercises, SelectionContext ctx, string dayType) =>
        exercises
            .Where(e => IsEligibleForDay(e, ctx, dayType))
            .GroupBy(e => e.Category)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<CatalogExerciseItem>)g.ToList());

    public static int SwapScore(CatalogExerciseItem original, CatalogExerciseItem candidate, SelectionContext ctx, string dayType)
    {
        var score = 0;
        if (candidate.Pattern == original.Pattern) score += 3;
        score += 2 * candidate.Primary.Intersect(original.Primary).Count();
        if (candidate.Secondary.Intersect(original.Secondary).Any()) score += 1;
        if (candidate.Splits.Contains(dayType)) score += 1;
        var pref = ctx.PreferenceOf(candidate.Id);
        if (pref == Vocab.Preference.Liked) score += 1;
        if (pref == Vocab.Preference.Disliked) score -= 2;
        if (candidate.Difficulty > MaxDifficulty(ctx.Experience)) score -= 2;
        return score;
    }

    /// <summary>Eligible same-category alternatives ranked by the rule score (best first).</summary>
    public static IReadOnlyList<CatalogExerciseItem> RankSwapCandidates(
        CatalogExerciseItem original,
        IEnumerable<CatalogExerciseItem> exercises,
        SelectionContext ctx,
        string dayType,
        IEnumerable<string>? excludeIds = null)
    {
        var exclude = new HashSet<string>(excludeIds ?? [], StringComparer.Ordinal) { original.Id };
        return exercises
            .Where(e => !exclude.Contains(e.Id)
                        && Vocab.SameSwapGroup(e.Category, original.Category)
                        && IsEligible(e, ctx))
            .Select(e => (Exercise: e, Score: SwapScore(original, e, ctx, dayType)))
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Exercise.Difficulty)
            .ThenByDescending(x => x.Exercise.Compound)
            .ThenBy(x => x.Exercise.Name, StringComparer.Ordinal)
            .Select(x => x.Exercise)
            .ToList();
    }
}
