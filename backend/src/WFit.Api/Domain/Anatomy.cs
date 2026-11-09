namespace WFit.Api.Domain;

/// <summary>Weekly effective-set band for a tracked muscle (primary set = 1, secondary set = 0.5).</summary>
public sealed record MuscleTarget(string Id, string Group, double Min, double Max);

/// <summary>
/// Muscle and body-region vocabulary. Mirrors <c>app/lib/domain/muscles.dart</c> (IMPROVEMENT-PLAN §4.1);
/// keep both in sync (a test compares them).
/// </summary>
public static class Anatomy
{
    public const double SecondarySetWeight = 0.5;
    public const string FullBody = "full_body";

    /// <summary>Muscles whose weekly volume is tracked and balanced (display order).</summary>
    public static readonly IReadOnlyList<MuscleTarget> TrackedMuscles =
    [
        new("chest", "push", 6, 12),
        new("front_delts", "push", 3, 10),
        new("side_delts", "push", 5, 10),
        new("triceps", "push", 4, 10),
        new("lats", "pull", 6, 12),
        new("upper_back", "pull", 6, 12),
        new("rear_delts", "pull", 4, 10),
        new("traps", "pull", 2, 6),
        new("biceps", "pull", 4, 10),
        new("forearms", "pull", 1, 6),
        new("quads", "legs", 6, 12),
        new("glutes", "legs", 6, 12),
        new("hamstrings", "legs", 5, 10),
        new("adductors", "legs", 2, 6),
        new("abductors", "legs", 2, 6),
        new("calves", "legs", 3, 8),
        new("abs", "core", 4, 10),
        new("obliques", "core", 2, 8),
        new("lower_back", "core", 1, 6),
    ];

    public static readonly IReadOnlyDictionary<string, MuscleTarget> Targets =
        TrackedMuscles.ToDictionary(m => m.Id, StringComparer.Ordinal);

    public static readonly IReadOnlySet<string> TrackedMuscleIds =
        new HashSet<string>(TrackedMuscles.Select(m => m.Id), StringComparer.Ordinal);

    /// <summary>Valid catalog <c>primary</c> / <c>secondary</c> values: tracked muscles plus mobility / prehab targets.</summary>
    public static readonly IReadOnlySet<string> MuscleVocabulary =
        new HashSet<string>(TrackedMuscleIds.Concat(["hip_flexors", "rotator_cuff", "thoracic_spine", FullBody]), StringComparer.Ordinal);

    public static class Region
    {
        public const string Neck = "neck";
        public const string Shoulder = "shoulder";
        public const string Elbow = "elbow";
        public const string Wrist = "wrist";
        public const string UpperBack = "upper_back";
        public const string LowerBack = "lower_back";
        public const string Hip = "hip";
        public const string Knee = "knee";
        public const string Ankle = "ankle";
    }

    /// <summary>Body regions for pain reports and catalog <c>stress</c> (order = display order).</summary>
    public static readonly IReadOnlyList<string> Regions =
    [
        Region.Neck, Region.Shoulder, Region.Elbow, Region.Wrist, Region.UpperBack,
        Region.LowerBack, Region.Hip, Region.Knee, Region.Ankle,
    ];

    public static readonly IReadOnlySet<string> RegionVocabulary = new HashSet<string>(Regions, StringComparer.Ordinal);

    /// <summary>Muscles whose direct training is also avoided when pain in the region is severe.</summary>
    public static readonly IReadOnlyDictionary<string, IReadOnlySet<string>> RelatedMuscles =
        new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
        {
            [Region.Neck] = Set("traps"),
            [Region.Shoulder] = Set("front_delts", "side_delts", "rear_delts", "rotator_cuff"),
            [Region.Elbow] = Set("biceps", "triceps", "forearms"),
            [Region.Wrist] = Set("forearms"),
            [Region.UpperBack] = Set("upper_back", "traps", "thoracic_spine"),
            [Region.LowerBack] = Set("lower_back"),
            [Region.Hip] = Set("adductors", "abductors", "hip_flexors"),
            [Region.Knee] = Set("quads"),
            [Region.Ankle] = Set("calves"),
        };

    public static bool IsTrackedMuscle(string? id) => id is not null && TrackedMuscleIds.Contains(id);

    public static bool IsRegion(string? id) => id is not null && RegionVocabulary.Contains(id);

    public static IReadOnlySet<string> RelatedMusclesOf(string region) =>
        RelatedMuscles.TryGetValue(region, out var muscles) ? muscles : Set();

    /// <summary>Effective sets one set of the exercise adds to <paramref name="muscle"/> (1 primary, 0.5 secondary, else 0).</summary>
    public static double EffectiveSetWeight(CatalogExerciseItem exercise, string muscle)
    {
        if (muscle == FullBody) return 0;
        if (exercise.Primary.Contains(muscle)) return 1;
        return exercise.Secondary.Contains(muscle) ? SecondarySetWeight : 0;
    }

    private static HashSet<string> Set(params string[] values) => new(values, StringComparer.Ordinal);
}
