using WFit.Api.Domain;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

// ---------------- Plan metadata (also stored by the app in PlannedWorkout.metaJson) ----------------

public sealed record PlanChangeDto
{
    public string? From { get; init; }
    public string? To { get; init; }
    public string? Reason { get; init; }
}

/// <summary>Incoming meta (tolerant) from the rule-engine draft or the app's current plan.</summary>
public sealed record PlanMetaInput
{
    public string? Program { get; init; }
    public string? Variant { get; init; }
    public bool? Deload { get; init; }
    public List<string?>? Focus { get; init; }
    public List<string?>? Rationale { get; init; }
    public List<PlanChangeDto?>? Changes { get; init; }
}

public sealed record PlanChange(string From, string To, string Reason);

/// <summary>Validated meta returned with every AI plan: <c>{program, variant, deload, focus, rationale, changes}</c>.</summary>
public sealed record PlanMeta(
    string? Program,
    string? Variant,
    bool Deload,
    IReadOnlyList<string> Focus,
    IReadOnlyList<string> Rationale,
    IReadOnlyList<PlanChange> Changes);

/// <summary>A plan sent by the app: the rule-engine draft (<c>/ai/workout</c>) or the current plan (<c>/ai/adjust</c>).</summary>
public sealed record PlanInput
{
    public string? Id { get; init; }
    public string? Date { get; init; }
    public string? DayType { get; init; }
    public string? Title { get; init; }
    public string? CoachNote { get; init; }
    public double? EstimatedMinutes { get; init; }
    public List<WorkoutBlockDto?>? Blocks { get; init; }
    public PlanMetaInput? Meta { get; init; }
}

// ---------------- POST /ai/workout ----------------

public sealed record AiWorkoutRequest
{
    public DayType? DayType { get; init; }
    public DateOnly? Date { get; init; }
    public int? SessionMinutes { get; init; }
    public bool? IncludeCore { get; init; }
    public string? UserNote { get; init; }
    public CoachBrief? Brief { get; init; }
    public PlanInput? Draft { get; init; }
}

public sealed record AiWorkoutDto(
    string Id,
    DateOnly Date,
    string DayType,
    string Title,
    string CoachNote,
    int EstimatedMinutes,
    IReadOnlyList<WorkoutBlockDto> Blocks,
    PlanMeta Meta);

public sealed record AiWorkoutResponse(AiWorkoutDto Workout, AiUsageDto Usage);

// ---------------- POST /ai/adjust ----------------

public sealed record AdjustRequest
{
    public string? Message { get; init; }
    public string? ExerciseId { get; init; }
    public bool? SessionInProgress { get; init; }
    public PlanInput? Plan { get; init; }
    public CoachBrief? Brief { get; init; }
}

/// <summary>A feedback entry interpreted from the message; the app stores it in <c>feedback_entries</c> (source <c>coach</c>).</summary>
public sealed record AdjustFeedback(
    string Kind,
    string? Region,
    int? Severity,
    string? ExerciseId,
    string? EquipmentId,
    string Note,
    int? ReviewInDays);

public sealed record AdjustedPlanDto(string Title, string CoachNote, int EstimatedMinutes, IReadOnlyList<WorkoutBlockDto> Blocks, PlanMeta Meta);

public sealed record AdjustResponse(string Reply, IReadOnlyList<AdjustFeedback> Feedback, AdjustedPlanDto? Plan, AiUsageDto Usage);

// ---------------- POST /ai/swap ----------------

public sealed record SwapRequest
{
    public string ExerciseId { get; init; } = "";
    public SwapReason? Reason { get; init; }
    public DayType? DayType { get; init; }
    public WorkoutSection? Section { get; init; }
    public List<string>? ExcludeExerciseIds { get; init; }
    public List<string>? OccupiedEquipment { get; init; }
    public string? Note { get; init; }
    public CoachBrief? Brief { get; init; }
}

public sealed record SwapSuggestion(string ExerciseId, string Why, int Sets, int? RepMin, int? RepMax, int RestSeconds);

public sealed record SwapResponse(IReadOnlyList<SwapSuggestion> Suggestions, string Source, AiUsageDto Usage);

// ---------------- POST /ai/insights ----------------

public sealed record InsightsRequest
{
    public CoachBrief? Brief { get; init; }
}

public sealed record InsightsResponse(
    DateTimeOffset GeneratedAt,
    string Summary,
    IReadOnlyList<string> Highlights,
    IReadOnlyList<string> Recommendations,
    string NextFocus,
    IReadOnlyList<string> FocusMuscles,
    string Source,
    AiUsageDto Usage);

// ---------------- Structured outputs returned by the model ----------------

public sealed record AiWorkoutOutput
{
    public string? Title { get; init; }
    public string? CoachNote { get; init; }
    public int EstimatedMinutes { get; init; }
    public List<WorkoutBlockDto>? Blocks { get; init; }
    public List<string>? Focus { get; init; }
    public List<string>? Rationale { get; init; }
    public List<PlanChangeDto>? Changes { get; init; }
}

public sealed record AiFeedbackOutput
{
    public string? Kind { get; init; }
    public string? Region { get; init; }
    public int? Severity { get; init; }
    public string? ExerciseId { get; init; }
    public string? EquipmentId { get; init; }
    public string? Note { get; init; }
    public int? ReviewInDays { get; init; }
}

public sealed record AiAdjustOutput
{
    public string? Reply { get; init; }
    public List<AiFeedbackOutput>? Feedback { get; init; }
    public AiWorkoutOutput? Plan { get; init; }
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
    public List<string>? FocusMuscles { get; init; }
}
