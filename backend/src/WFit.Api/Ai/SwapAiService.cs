using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>POST /ai/swap — rule-ranked candidates, model picks up to 3; falls back to the rule ranking.</summary>
public sealed class SwapAiService(CatalogService catalog, TrainingDataReader data, AiUsageService usage)
{
    public const int CandidatesForModel = 15;
    public const int MaxSuggestions = 3;

    public async Task<SwapResponse> SuggestAsync(SwapRequest request, CancellationToken ct)
    {
        var original = catalog.FindExercise(request.ExerciseId)
            ?? throw ApiException.BadRequest("exerciseId is not a known catalog exercise.");
        var reason = request.Reason ?? SwapReason.Preference;
        var dayType = request.DayType?.ToWire() ?? original.Splits.FirstOrDefault() ?? "push";
        var section = request.Section ?? DefaultSection(original.Category);

        var profile = await data.LoadProfileAsync(ct);
        var ctx = await data.LoadSelectionContextAsync(profile?.Experience, request.OccupiedEquipment, ct);
        var ranked = ExerciseSelector.RankSwapCandidates(original, catalog.Exercises, ctx, dayType, request.ExcludeExerciseIds);

        if (ranked.Count == 0)
            return new SwapResponse([], "rules", await usage.GetUsageAsync(ct));

        var top = ranked.Take(CandidatesForModel).ToList();
        var context = new
        {
            original = AiPrompts.CandidateView(original),
            reason = reason.ToWire(),
            note = string.IsNullOrWhiteSpace(request.Note) ? null : SyncMapper.Trunc(request.Note, 500),
            dayType,
            section = section.ToWire(),
            experience = ctx.Experience,
            injuries = string.IsNullOrWhiteSpace(profile?.Injuries) ? null : profile.Injuries,
            candidates = top.Select(AiPrompts.CandidateView),
        };
        var prompt = new AiPrompt("exercise_swap", AiPrompts.SwapSystem, AiPrompts.Serialize(context), AiSchemas.Swap(top.Select(e => e.Id)));
        var output = await usage.CompleteJsonAsync<AiSwapOutput>(prompt, ct);

        var suggestions = AiOutputValidator.ValidateSwap(output, top, section, MaxSuggestions);
        var source = "ai";
        if (suggestions.Count == 0)
        {
            suggestions = AiOutputValidator.RuleSwaps(original, ranked, section, MaxSuggestions);
            source = "rules";
        }
        return new SwapResponse(suggestions, source, await usage.GetUsageAsync(ct));
    }

    private static WorkoutSection DefaultSection(string category) => category switch
    {
        Vocab.Category.Warmup => WorkoutSection.Warmup,
        Vocab.Category.Core => WorkoutSection.Core,
        Vocab.Category.Cooldown => WorkoutSection.Cooldown,
        _ => WorkoutSection.Main,
    };
}
