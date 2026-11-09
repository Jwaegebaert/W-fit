using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>POST /ai/swap — rule-ranked safe candidates, the model picks up to 3; falls back to the rule ranking.</summary>
public sealed class SwapAiService(CatalogService catalog, AiGateway ai, TimeProvider time)
{
    public const int CandidatesForModel = 15;
    public const int MaxSuggestions = 3;

    public async Task<SwapResponse> SuggestAsync(SwapRequest request, CancellationToken ct)
    {
        var original = catalog.FindExercise(request.ExerciseId)
            ?? throw ApiException.BadRequest("exerciseId is not a known catalog exercise.");
        var reason = request.Reason ?? SwapReason.Preference;
        var dayType = request.DayType?.ToWire() ?? original.Splits.FirstOrDefault() ?? "push";
        var section = request.Section ?? Vocab.SectionFor(original.Category);
        var brief = CoachBriefRules.Sanitize(request.Brief);
        var today = CoachBriefRules.ParseDate(brief.Today) ?? DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime);
        var deload = brief.IsDeload();

        var ctx = brief.ToSelectionContext(catalog, today, extraOccupied: request.OccupiedEquipment);
        var ranked = ExerciseSelector.RankSwapCandidates(original, catalog.Exercises, ctx, dayType, request.ExcludeExerciseIds);
        if (ranked.Count == 0)
            return new SwapResponse([], "rules", await ai.GetUsageAsync(ct));

        var top = ranked.Take(CandidatesForModel).ToList();
        var relevant = new HashSet<string>(top.Select(e => e.Id).Append(original.Id), StringComparer.Ordinal);
        var originalVerdict = ctx.Limitations.Evaluate(original);
        var context = new
        {
            original = AiPrompts.CandidateView(original, LimitationFilter.None),
            originalLimitation = originalVerdict.Reason,
            reason = reason.ToWire(),
            note = string.IsNullOrWhiteSpace(request.Note) ? null : SyncMapper.Trunc(request.Note.Trim(), 500),
            dayType,
            section = section.ToWire(),
            brief = new
            {
                today = AiPrompts.Date(today),
                brief.Profile,
                brief.Limitations,
                exerciseFeedback = brief.ExerciseFeedback?.Where(f => f?.ExerciseId is { } id && relevant.Contains(id)).ToList(),
                brief.Program,
                priorities = brief.Balance?.Priorities,
                exerciseHistory = brief.ExerciseHistory?.Where(h => h?.ExerciseId is { } id && relevant.Contains(id)).ToList(),
                brief.Preferences,
            },
            candidates = top.Select(e => AiPrompts.CandidateView(e, ctx.Limitations)),
        };
        var prompt = new AiPrompt("exercise_swap", AiPrompts.SwapSystem, AiPrompts.Serialize(context),
            AiSchemas.Swap(top.Select(e => e.Id)), AiEffort.Low);
        var output = await ai.CompleteJsonAsync<AiSwapOutput>(prompt, ct);

        var suggestions = AiOutputValidator.ValidateSwap(output, top, section, MaxSuggestions, deload);
        var source = "ai";
        if (suggestions.Count == 0)
        {
            suggestions = AiOutputValidator.RuleSwaps(original, ranked, section, MaxSuggestions, deload);
            source = "rules";
        }
        return new SwapResponse(suggestions, source, await ai.GetUsageAsync(ct));
    }
}
