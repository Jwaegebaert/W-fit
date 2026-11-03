using WFit.Api.Data;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

/// <summary>POST /ai/workout — candidate filtering, model call, validation and persistence as a PlannedWorkout.</summary>
public sealed class WorkoutAiService(
    WFitDbContext db,
    CatalogService catalog,
    TrainingDataReader data,
    AiUsageService usage,
    TimeProvider time)
{
    public const int HistorySessions = 6;

    public async Task<AiWorkoutResponse> GenerateAsync(AiWorkoutRequest request, CancellationToken ct)
    {
        if (request.DayType is not { } dayTypeValue) throw ApiException.BadRequest("dayType is required (push|pull|legs).");
        var dayType = dayTypeValue.ToWire();
        var now = time.GetUtcNow();

        var profile = await data.LoadProfileAsync(ct);
        var sessionMinutes = Math.Clamp(request.SessionMinutes ?? profile?.SessionMinutes ?? 60, 20, 120);
        var includeCore = request.IncludeCore ?? profile?.IncludeCore ?? true;
        var ctx = await data.LoadSelectionContextAsync(profile?.Experience, request.OccupiedEquipment, ct);

        var candidates = ExerciseSelector.CandidatesByCategory(catalog.Exercises, ctx, dayType);
        IReadOnlyList<CatalogExerciseItem> Of(params string[] categories) =>
            categories.SelectMany(c => candidates.TryGetValue(c, out var l) ? l : []).ToList();

        var main = Of(Vocab.Category.Power, Vocab.Category.Strength);
        if (main.Count < AiOutputValidator.MinMainItems)
            throw ApiException.AiUnavailable("Not enough eligible exercises for this day with the current equipment.");

        var warmup = Of(Vocab.Category.Warmup);
        var core = includeCore ? Of(Vocab.Category.Core) : [];
        var cooldown = Of(Vocab.Category.Cooldown);
        var history = await data.LoadRecentSessionsAsync(HistorySessions, ct);

        var context = new
        {
            profile = AiPrompts.ProfileView(profile),
            dayType,
            date = (request.Date ?? DateOnly.FromDateTime(now.UtcDateTime)).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture),
            sessionMinutes,
            includeCore,
            userNote = string.IsNullOrWhiteSpace(request.UserNote) ? null : SyncMapper.Trunc(request.UserNote, 500),
            candidates = new
            {
                warmup = warmup.Select(AiPrompts.CandidateView),
                main = main.Select(AiPrompts.CandidateView),
                core = core.Select(AiPrompts.CandidateView),
                cooldown = cooldown.Select(AiPrompts.CandidateView),
            },
            recentSessions = history,
            preferences = new
            {
                liked = ctx.Preferences.Where(p => p.Value == Vocab.Preference.Liked).Select(p => p.Key),
                disliked = ctx.Preferences.Where(p => p.Value == Vocab.Preference.Disliked).Select(p => p.Key),
            },
        };

        var ids = warmup.Concat(main).Concat(core).Concat(cooldown).Select(e => e.Id);
        var prompt = new AiPrompt("workout_plan", AiPrompts.WorkoutSystem, AiPrompts.Serialize(context), AiSchemas.Workout(ids));
        var output = await usage.CompleteJsonAsync<AiWorkoutOutput>(prompt, ct);

        var validated = AiOutputValidator.ValidateWorkout(output, candidates, includeCore, dayType, sessionMinutes);

        var stamp = time.GetUtcNow();
        var entity = new PlannedWorkout
        {
            Id = Guid.NewGuid().ToString("D"),
            Date = request.Date ?? DateOnly.FromDateTime(now.UtcDateTime),
            DayType = dayType,
            Title = validated.Title,
            Source = "ai",
            Status = "planned",
            EstimatedMinutes = validated.EstimatedMinutes,
            CoachNote = validated.CoachNote,
            BlocksJson = SyncMapper.SerializeBlocks(validated.Blocks),
            UpdatedAt = stamp,
            ServerUpdatedAt = stamp,
            Deleted = false,
        };
        db.PlannedWorkouts.Add(entity);
        await db.SaveChangesAsync(ct);

        return new AiWorkoutResponse(entity.ToDto(), await usage.GetUsageAsync(ct));
    }
}
