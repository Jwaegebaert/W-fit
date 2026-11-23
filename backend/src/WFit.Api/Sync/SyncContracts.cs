namespace WFit.Api.Sync;

public interface ISyncDto
{
    DateTimeOffset UpdatedAt { get; }
    bool Deleted { get; }
}

public sealed record ProfileDto : ISyncDto
{
    public string Id { get; init; } = "me";
    public string Name { get; init; } = "";
    public string Experience { get; init; } = "beginner";
    public string Goals { get; init; } = "";
    public List<int> TrainingDays { get; init; } = [];
    public int SessionMinutes { get; init; } = 60;
    public bool IncludeCore { get; init; } = true;
    public double? HeightCm { get; init; }
    public int? BirthYear { get; init; }
    public string Injuries { get; init; } = "";
    public string Notes { get; init; } = "";
    public string RestMode { get; init; } = "normal";
    public int CooldownStretches { get; init; } = 3;
    public Dictionary<string, double>? BarWeights { get; init; }
    public MuscleFocusDto? MuscleFocus { get; init; }
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record MuscleFocusDto
{
    public List<string> Less { get; init; } = [];
    public List<string> More { get; init; } = [];
    public List<string> Light { get; init; } = [];
}

public sealed record EquipmentStatusDto : ISyncDto
{
    public string EquipmentId { get; init; } = "";
    public bool Available { get; init; } = true;
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record ExercisePreferenceDto : ISyncDto
{
    public string ExerciseId { get; init; } = "";
    public string Preference { get; init; } = "neutral";
    public string Note { get; init; } = "";
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record WorkoutItemDto
{
    public string ExerciseId { get; init; } = "";
    public int Sets { get; init; }
    public int? RepMin { get; init; }
    public int? RepMax { get; init; }
    public int? DurationSeconds { get; init; }
    public int RestSeconds { get; init; }
    public double? TargetWeightKg { get; init; }
    public string Notes { get; init; } = "";
}

public sealed record WorkoutBlockDto
{
    public string Section { get; init; } = "";
    public List<WorkoutItemDto> Items { get; init; } = [];
}

public sealed record PlannedWorkoutDto : ISyncDto
{
    public string Id { get; init; } = "";
    public DateOnly Date { get; init; }
    public string DayType { get; init; } = "";
    public string Title { get; init; } = "";
    public string Source { get; init; } = "rules";
    public string Status { get; init; } = "planned";
    public int EstimatedMinutes { get; init; }
    public string CoachNote { get; init; } = "";
    public List<WorkoutBlockDto> Blocks { get; init; } = [];

    /// <summary>Plan meta as a JSON object string (≤ 8000 chars), e.g. <c>{"program":"Block 2 · Week 3 · Push B",...}</c>.</summary>
    public string? MetaJson { get; init; } = "{}";
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record FeedbackEntryDto : ISyncDto
{
    public string Id { get; init; } = "";
    public DateTimeOffset? CreatedAt { get; init; }
    public string Kind { get; init; } = "";
    public string? Region { get; init; }
    public int? Severity { get; init; }
    public string? ExerciseId { get; init; }
    public string? SessionId { get; init; }
    public string? Note { get; init; } = "";
    public string Status { get; init; } = "active";
    public DateOnly? ReviewOn { get; init; }
    public DateTimeOffset? ResolvedAt { get; init; }
    public string Source { get; init; } = "user";
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record WorkoutSessionDto : ISyncDto
{
    public string Id { get; init; } = "";
    public string? PlannedWorkoutId { get; init; }
    public string DayType { get; init; } = "";
    public string Title { get; init; } = "";
    public DateTimeOffset StartedAt { get; init; }
    public DateTimeOffset? EndedAt { get; init; }
    public int? DurationSeconds { get; init; }
    public int? Rating { get; init; }
    public int? PerceivedEffort { get; init; }
    public string Notes { get; init; } = "";
    public int? AvgHeartRate { get; init; }
    public int? MaxHeartRate { get; init; }
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record SetLogDto : ISyncDto
{
    public string Id { get; init; } = "";
    public string SessionId { get; init; } = "";
    public string ExerciseId { get; init; } = "";
    public string Section { get; init; } = "main";
    public int ExerciseOrder { get; init; }
    public int SetNumber { get; init; }
    public double? WeightKg { get; init; }
    public int? Reps { get; init; }
    public int? DurationSeconds { get; init; }
    public int? Rir { get; init; }
    public bool Completed { get; init; }
    public DateTimeOffset? CompletedAt { get; init; }
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record BodyMetricDto : ISyncDto
{
    public string Id { get; init; } = "";
    public DateOnly Date { get; init; }
    public double? WeightKg { get; init; }
    public double? BodyFatPct { get; init; }
    public double? WaistCm { get; init; }
    public double? ChestCm { get; init; }
    public double? ArmCm { get; init; }
    public double? ThighCm { get; init; }
    public double? HipsCm { get; init; }
    public string Notes { get; init; } = "";
    public DateTimeOffset UpdatedAt { get; init; }
    public bool Deleted { get; init; }
}

public sealed record SyncChanges
{
    public ProfileDto? Profile { get; init; }
    public List<EquipmentStatusDto> Equipment { get; init; } = [];
    public List<ExercisePreferenceDto> ExercisePreferences { get; init; } = [];
    public List<PlannedWorkoutDto> PlannedWorkouts { get; init; } = [];
    public List<WorkoutSessionDto> Sessions { get; init; } = [];
    public List<SetLogDto> Sets { get; init; } = [];
    public List<BodyMetricDto> BodyMetrics { get; init; } = [];
    public List<FeedbackEntryDto> FeedbackEntries { get; init; } = [];

    public int CountRecords() =>
        (Profile is null ? 0 : 1) + (Equipment?.Count ?? 0) + (ExercisePreferences?.Count ?? 0) + (PlannedWorkouts?.Count ?? 0)
        + (Sessions?.Count ?? 0) + (Sets?.Count ?? 0) + (BodyMetrics?.Count ?? 0) + (FeedbackEntries?.Count ?? 0);
}

public sealed record SyncRequest
{
    public DateTimeOffset? Since { get; init; }
    public SyncChanges? Changes { get; init; }
}

public sealed record SyncResponse(DateTimeOffset ServerTime, SyncChanges Changes);
