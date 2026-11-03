using WFit.Api.Domain;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

public sealed record AiUsageDto(bool Enabled, int CallsToday, int DailyCallLimit, long TokensThisMonth, long MonthlyTokenLimit);

public sealed record AiWorkoutRequest
{
    public DayType? DayType { get; init; }
    public DateOnly? Date { get; init; }
    public int? SessionMinutes { get; init; }
    public bool? IncludeCore { get; init; }
    public List<string> OccupiedEquipment { get; init; } = [];
    public string? UserNote { get; init; }
}

public sealed record AiWorkoutResponse(PlannedWorkoutDto Workout, AiUsageDto Usage);

public sealed record SwapRequest
{
    public string ExerciseId { get; init; } = "";
    public SwapReason? Reason { get; init; }
    public DayType? DayType { get; init; }
    public WorkoutSection? Section { get; init; }
    public List<string> ExcludeExerciseIds { get; init; } = [];
    public List<string> OccupiedEquipment { get; init; } = [];
    public string? Note { get; init; }
}

public sealed record SwapSuggestion(string ExerciseId, string Why, int Sets, int? RepMin, int? RepMax, int RestSeconds);

public sealed record SwapResponse(IReadOnlyList<SwapSuggestion> Suggestions, string Source, AiUsageDto Usage);

public sealed record InsightsRequest
{
    public bool Force { get; init; }
}

public sealed record InsightsResponse(
    DateTimeOffset GeneratedAt,
    string Summary,
    IReadOnlyList<string> Highlights,
    IReadOnlyList<string> Recommendations,
    string NextFocus,
    string Source,
    bool Cached,
    AiUsageDto? Usage);

// Structured outputs returned by the model.

public sealed record AiWorkoutOutput
{
    public string? Title { get; init; }
    public string? CoachNote { get; init; }
    public int EstimatedMinutes { get; init; }
    public List<WorkoutBlockDto>? Blocks { get; init; }
}

public sealed record AiSwapOutput
{
    public List<SwapSuggestion>? Suggestions { get; init; }
}

public sealed record AiInsightsOutput
{
    public string? Summary { get; init; }
    public List<string>? Highlights { get; init; }
    public List<string>? Recommendations { get; init; }
    public string? NextFocus { get; init; }
}
