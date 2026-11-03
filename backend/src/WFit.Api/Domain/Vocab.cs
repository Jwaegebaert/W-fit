namespace WFit.Api.Domain;

public enum DayType { Push, Pull, Legs }

public enum WorkoutSection { Warmup, Main, Core, Cooldown }

public enum SwapReason { Occupied, Unavailable, Preference }

/// <summary>Wire values (lower-case strings) shared by the API contract and the catalog.</summary>
public static class Vocab
{
    public const string ProfileId = "me";

    public static class Category
    {
        public const string Warmup = "warmup";
        public const string Strength = "strength";
        public const string Power = "power";
        public const string Core = "core";
        public const string Cooldown = "cooldown";
    }

    public static class Measure
    {
        public const string Reps = "reps";
        public const string Time = "time";
    }

    public static class Preference
    {
        public const string Liked = "liked";
        public const string Neutral = "neutral";
        public const string Disliked = "disliked";
        public const string Banned = "banned";
    }

    public static class Experience
    {
        public const string Beginner = "beginner";
        public const string Novice = "novice";
        public const string Intermediate = "intermediate";
    }

    public static readonly IReadOnlySet<string> Experiences = Set(Experience.Beginner, Experience.Novice, Experience.Intermediate);
    public static readonly IReadOnlySet<string> Preferences = Set(Preference.Liked, Preference.Neutral, Preference.Disliked, Preference.Banned);
    public static readonly IReadOnlySet<string> DayTypes = Set("push", "pull", "legs");
    public static readonly IReadOnlySet<string> Sections = Set("warmup", "main", "core", "cooldown");
    public static readonly IReadOnlySet<string> Sources = Set("ai", "rules");
    public static readonly IReadOnlySet<string> Statuses = Set("planned", "completed", "skipped");

    public static string ToWire(this DayType value) => value.ToString().ToLowerInvariant();
    public static string ToWire(this WorkoutSection value) => value.ToString().ToLowerInvariant();
    public static string ToWire(this SwapReason value) => value.ToString().ToLowerInvariant();

    public static WorkoutSection? ParseSection(string? value) => value switch
    {
        "warmup" => WorkoutSection.Warmup,
        "main" => WorkoutSection.Main,
        "core" => WorkoutSection.Core,
        "cooldown" => WorkoutSection.Cooldown,
        _ => null,
    };

    /// <summary>Catalog categories an exercise may have to appear in a workout section.</summary>
    public static IReadOnlySet<string> CategoriesFor(WorkoutSection section) => section switch
    {
        WorkoutSection.Warmup => Set(Category.Warmup),
        WorkoutSection.Main => Set(Category.Strength, Category.Power),
        WorkoutSection.Core => Set(Category.Core),
        _ => Set(Category.Cooldown),
    };

    /// <summary>Strength and power are interchangeable for swaps; other categories only swap within themselves.</summary>
    public static bool SameSwapGroup(string a, string b) =>
        a == b || (IsMain(a) && IsMain(b));

    public static bool IsMain(string category) => category is Category.Strength or Category.Power;

    private static HashSet<string> Set(params string[] values) => new(values, StringComparer.Ordinal);
}
