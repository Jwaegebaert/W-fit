namespace WFit.Api.Data;

/// <summary>Columns shared by every record that is synced with the app.</summary>
public abstract class SyncEntity
{
    /// <summary>Client clock; last-write-wins.</summary>
    public DateTimeOffset UpdatedAt { get; set; }

    /// <summary>Server clock when the row was last written; drives incremental pulls.</summary>
    public DateTimeOffset ServerUpdatedAt { get; set; }

    public bool Deleted { get; set; }
}

public sealed class Profile : SyncEntity
{
    public string Id { get; set; } = "me";
    public string Name { get; set; } = "";
    public string Experience { get; set; } = "beginner";
    public string Goals { get; set; } = "";
    public List<int> TrainingDays { get; set; } = [];
    public int SessionMinutes { get; set; } = 60;
    public bool IncludeCore { get; set; } = true;
    public double? HeightCm { get; set; }
    public int? BirthYear { get; set; }
    public string Injuries { get; set; } = "";
    public string Notes { get; set; } = "";
}

public sealed class EquipmentStatus : SyncEntity
{
    public string EquipmentId { get; set; } = "";
    public bool Available { get; set; } = true;
}

public sealed class ExercisePreference : SyncEntity
{
    public string ExerciseId { get; set; } = "";
    public string Preference { get; set; } = "neutral";
    public string Note { get; set; } = "";
}

public sealed class PlannedWorkout : SyncEntity
{
    public string Id { get; set; } = "";
    public DateOnly Date { get; set; }
    public string DayType { get; set; } = "";
    public string Title { get; set; } = "";
    public string Source { get; set; } = "rules";
    public string Status { get; set; } = "planned";
    public int EstimatedMinutes { get; set; }
    public string CoachNote { get; set; } = "";

    /// <summary>Workout blocks serialized as JSON (nvarchar(max)).</summary>
    public string BlocksJson { get; set; } = "[]";
}

public sealed class WorkoutSession : SyncEntity
{
    public string Id { get; set; } = "";
    public string? PlannedWorkoutId { get; set; }
    public string DayType { get; set; } = "";
    public string Title { get; set; } = "";
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public int? DurationSeconds { get; set; }
    public int? Rating { get; set; }
    public int? PerceivedEffort { get; set; }
    public string Notes { get; set; } = "";
}

public sealed class SetLog : SyncEntity
{
    public string Id { get; set; } = "";
    public string SessionId { get; set; } = "";
    public string ExerciseId { get; set; } = "";
    public string Section { get; set; } = "main";
    public int ExerciseOrder { get; set; }
    public int SetNumber { get; set; }
    public double? WeightKg { get; set; }
    public int? Reps { get; set; }
    public int? DurationSeconds { get; set; }
    public int? Rir { get; set; }
    public bool Completed { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
}

public sealed class BodyMetric : SyncEntity
{
    public string Id { get; set; } = "";
    public DateOnly Date { get; set; }
    public double? WeightKg { get; set; }
    public double? BodyFatPct { get; set; }
    public double? WaistCm { get; set; }
    public double? ChestCm { get; set; }
    public double? ArmCm { get; set; }
    public double? ThighCm { get; set; }
    public double? HipsCm { get; set; }
    public string Notes { get; set; } = "";
}

/// <summary>Persisted copy of the embedded catalog (reseeded when the catalog version changes).</summary>
public sealed class CatalogExercise
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public string Pattern { get; set; } = "";
    public List<string> Splits { get; set; } = [];
    public List<string> Primary { get; set; } = [];
    public List<string> Secondary { get; set; } = [];
    public List<string> Equipment { get; set; } = [];
    public int Difficulty { get; set; }
    public bool Compound { get; set; }
    public bool Unilateral { get; set; }
    public string Measure { get; set; } = "";
    public int Sets { get; set; }
    public int? RepMin { get; set; }
    public int? RepMax { get; set; }
    public int? DurationSeconds { get; set; }
    public int RestSeconds { get; set; }
    public double IncrementKg { get; set; }
    public string? Badminton { get; set; }
    public List<string> Instructions { get; set; } = [];
    public string? Tip { get; set; }
}

public sealed class CatalogEquipment
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Group { get; set; } = "";
    public bool AlwaysAvailable { get; set; }
}

public sealed class AppMeta
{
    public string Key { get; set; } = "";
    public string Value { get; set; } = "";
}

/// <summary>AI consumption per UTC day.</summary>
public sealed class AiUsage
{
    public DateOnly Day { get; set; }
    public int Calls { get; set; }
    public long InputTokens { get; set; }
    public long OutputTokens { get; set; }
}

/// <summary>Insights response cached per UTC day.</summary>
public sealed class InsightsCache
{
    public DateOnly Day { get; set; }
    public string Json { get; set; } = "";
    public DateTimeOffset GeneratedAt { get; set; }
}
