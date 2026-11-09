using Microsoft.Extensions.Logging;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>
/// POST /ai/adjust — interprets a free-text report ("my neck hurts", "the leg press is broken", "this felt too easy")
/// into feedback entries and, when a plan is given, an adjusted plan validated against the updated limitations.
/// </summary>
public sealed class AdjustAiService(CatalogService catalog, AiGateway ai, TimeProvider time, ILogger<AdjustAiService> logger)
{
    public const int MaxMessageLength = 2000;
    public const int MaxReplyLength = 1000;

    public async Task<AdjustResponse> AdjustAsync(AdjustRequest request, CancellationToken ct)
    {
        var message = request.Message?.Trim();
        if (string.IsNullOrEmpty(message)) throw ApiException.BadRequest("message is required.");
        message = SyncMapper.Trunc(message, MaxMessageLength);

        var brief = CoachBriefRules.Sanitize(request.Brief);
        var today = CoachBriefRules.ParseDate(brief.Today) ?? DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime);
        var onScreen = catalog.FindExercise(request.ExerciseId);

        var plan = request.Plan;
        string? dayType = null;
        if (plan is not null)
        {
            dayType = plan.DayType?.Trim().ToLowerInvariant();
            if (dayType is null || !Vocab.DayTypes.Contains(dayType))
                throw ApiException.BadRequest("plan.dayType must be push, pull or legs.");
        }
        var includeCore = plan?.Blocks?.Any(b => b?.Section == Vocab.Category.Core) ?? false;
        var sessionMinutes = Math.Clamp((int?)brief.Profile?.SessionMinutes ?? 60, 20, 120);
        var deload = brief.IsDeload() || plan?.Meta?.Deload == true;

        var ctx = brief.ToSelectionContext(catalog, today);
        var candidates = dayType is null ? null : new DayCandidates(catalog, ctx, dayType, includeCore, planIds: WorkoutAiService.PlanIds(plan));

        var context = new
        {
            request = new
            {
                today = AiPrompts.Date(today),
                message,
                exerciseId = onScreen?.Id,
                exerciseName = onScreen?.Name,
                sessionInProgress = request.SessionInProgress == true,
            },
            plan = plan is null || candidates is null
                ? null
                : new
                {
                    dayType,
                    title = plan.Title is null ? null : SyncMapper.Trunc(plan.Title, 100),
                    deload,
                    blocks = AiPrompts.PlanView(plan.Blocks, catalog, candidates.Ids, ctx),
                    meta = AiPrompts.MetaView(plan.Meta),
                },
            brief,
            candidates = candidates?.View(),
        };

        var prompt = new AiPrompt("plan_adjustment", AiPrompts.AdjustSystem, AiPrompts.Serialize(context),
            AiSchemas.Adjust(candidates?.Ids), AiEffort.Low);
        var output = await ai.CompleteJsonAsync<AiAdjustOutput>(prompt, ct);

        var feedback = AiOutputValidator.ValidateFeedback(output.Feedback, catalog);
        var reply = string.IsNullOrWhiteSpace(output.Reply)
            ? "Noted - I've updated your coach notes."
            : SyncMapper.Trunc(output.Reply.Trim(), MaxReplyLength);

        AdjustedPlanDto? adjusted = null;
        if (plan is not null && dayType is not null)
            adjusted = AdjustPlan(plan, dayType, output.Plan, feedback, brief, today, includeCore, sessionMinutes, deload);

        return new AdjustResponse(reply, feedback, adjusted, await ai.GetUsageAsync(ct));
    }

    /// <summary>
    /// Validates the model's plan against candidates that already honour the new feedback. When the model kept the plan
    /// (null) but the plan now contains excluded exercises, those are removed deterministically.
    /// </summary>
    private AdjustedPlanDto? AdjustPlan(
        PlanInput plan,
        string dayType,
        AiWorkoutOutput? proposed,
        IReadOnlyList<AdjustFeedback> feedback,
        CoachBrief brief,
        DateOnly today,
        bool includeCore,
        int sessionMinutes,
        bool deload)
    {
        var newLimitations = feedback
            .Where(f => Vocab.FeedbackKind.IsPainLike(f.Kind))
            .Select(f => new Limitation(f.Kind, f.Region, f.Severity, f.ExerciseId, today))
            .ToList();
        var unavailableEquipment = new HashSet<string>(StringComparer.Ordinal);
        var excludedIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var f in feedback.Where(f => f.Kind == Vocab.FeedbackKind.Unavailable))
        {
            if (f.EquipmentId is { } eq && !catalog.IsAlwaysAvailable(eq)) unavailableEquipment.Add(eq);
            if (catalog.FindExercise(f.ExerciseId) is not { } exercise) continue;
            excludedIds.Add(exercise.Id);
            // A broken machine rules out every exercise that needs it.
            var machines = exercise.Equipment.Where(e => !catalog.IsAlwaysAvailable(e)).ToList();
            if (f.EquipmentId is null && machines.Count == 1) unavailableEquipment.Add(machines[0]);
        }

        var ctx = brief.ToSelectionContext(catalog, today, extraLimitations: newLimitations, extraUnavailable: unavailableEquipment);
        var candidates = new DayCandidates(catalog, ctx, dayType, includeCore, excludedIds, WorkoutAiService.PlanIds(plan));
        var programLabel = plan.Meta?.Program ?? brief.ProgramLabel(dayType);
        var variant = plan.Meta?.Variant ?? brief.Program?.Variant;

        if (proposed is not null)
        {
            try
            {
                var validated = AiOutputValidator.ValidateWorkout(proposed, candidates.ByCategory, includeCore, dayType, sessionMinutes, deload);
                var meta = AiOutputValidator.ValidateMeta(proposed.Focus, proposed.Rationale, proposed.Changes, validated.ExerciseIds,
                    catalog, programLabel, variant, deload, ctx.Limitations);
                return new AdjustedPlanDto(validated.Title, validated.CoachNote, validated.EstimatedMinutes, validated.Blocks, meta);
            }
            catch (ApiException ex)
            {
                logger.LogWarning("AI adjusted plan unusable ({Message}); falling back to the current plan.", ex.Message);
            }
        }

        var current = (plan.Blocks ?? []).OfType<WorkoutBlockDto>().ToList();
        var removed = current.SelectMany(b => b.Items ?? []).Where(i => i is not null && !candidates.Ids.Contains(i.ExerciseId ?? ""))
            .Select(i => i.ExerciseId).Distinct().ToList();
        if (removed.Count == 0) return null;

        try
        {
            var kept = new AiWorkoutOutput
            {
                Title = plan.Title,
                CoachNote = plan.CoachNote,
                EstimatedMinutes = (int)Math.Round(plan.EstimatedMinutes ?? 0),
                Blocks = current,
            };
            var validated = AiOutputValidator.ValidateWorkout(kept, candidates.ByCategory, includeCore, dayType, sessionMinutes, deload);
            var rationale = removed.Select(id => $"Removed {id}: {AiPrompts.BlockedReason(catalog.FindExercise(id), ctx)}.");
            var meta = AiOutputValidator.ValidateMeta(plan.Meta?.Focus, rationale, null, validated.ExerciseIds,
                catalog, programLabel, variant, deload, ctx.Limitations);
            return new AdjustedPlanDto(validated.Title, validated.CoachNote, validated.EstimatedMinutes, validated.Blocks, meta);
        }
        catch (ApiException)
        {
            return null;
        }
    }
}
