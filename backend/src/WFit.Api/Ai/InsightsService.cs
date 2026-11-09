using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>POST /ai/insights — coach review of the brief (medium reasoning effort). Not cached server-side (the app caches).</summary>
public sealed class InsightsService(AiGateway ai, TimeProvider time)
{
    public const int MaxItems = 4;
    public const int MaxItemLength = 300;
    public const int MaxFocusMuscles = 3;

    public async Task<InsightsResponse> GetAsync(InsightsRequest request, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var brief = CoachBriefRules.Sanitize(request.Brief);
        var today = CoachBriefRules.ParseDate(brief.Today) ?? DateOnly.FromDateTime(now.UtcDateTime);
        var limits = new LimitationFilter(brief.ToLimitations(), today);

        if (!brief.HasTrainingData())
            return RulesResponse(now, brief, limits, await ai.GetUsageAsync(ct));

        var prompt = new AiPrompt("progress_insights", AiPrompts.InsightsSystem,
            AiPrompts.Serialize(new { today = AiPrompts.Date(today), brief }), AiSchemas.Insights(), AiEffort.Medium);
        var output = await ai.CompleteJsonAsync<AiInsightsOutput>(prompt, ct);
        if (string.IsNullOrWhiteSpace(output.Summary))
            throw ApiException.AiUnavailable();

        return new InsightsResponse(
            now,
            SyncMapper.Trunc(output.Summary.Trim(), 1000),
            AiOutputValidator.CleanList(output.Highlights, MaxItems, MaxItemLength),
            AiOutputValidator.CleanList(output.Recommendations, MaxItems, MaxItemLength),
            SyncMapper.Trunc(output.NextFocus?.Trim(), MaxItemLength),
            FocusMuscles(output.FocusMuscles, limits),
            "ai",
            await ai.GetUsageAsync(ct));
    }

    /// <summary>Tracked muscles only, never muscles avoided because of severe pain.</summary>
    public static List<string> FocusMuscles(IEnumerable<string?>? muscles, LimitationFilter limits) =>
        (muscles ?? [])
            .Where(m => Anatomy.IsTrackedMuscle(m) && !limits.AvoidedMuscles.Contains(m!))
            .Select(m => m!)
            .Distinct(StringComparer.Ordinal)
            .Take(MaxFocusMuscles)
            .ToList();

    public static InsightsResponse RulesResponse(DateTimeOffset now, CoachBrief brief, LimitationFilter limits, AiUsageDto usage) => new(
        now,
        "No workouts logged yet. Your coach insights will appear after your first sessions.",
        [],
        [
            "Train 3 times per week following the Push / Pull / Legs rotation.",
            "Keep 2-3 reps in reserve on every set and focus on smooth, controlled technique.",
            "Log your bodyweight once a week to see the trend.",
        ],
        "Complete your first Push, Pull and Legs sessions.",
        FocusMuscles(brief.Balance?.Priorities?.Select(p => p?.Muscle), limits),
        "rules",
        usage);
}
