using System.Globalization;
using Microsoft.EntityFrameworkCore;
using WFit.Api.Data;
using WFit.Api.Domain;

namespace WFit.Api.Ai;

public sealed record ExerciseBest(string ExerciseId, string Best);

public sealed record SessionSummary(string Date, string DayType, int? Rating, int? PerceivedEffort, IReadOnlyList<ExerciseBest> Exercises);

/// <summary>Reads the user state the AI endpoints need from SQL (the client syncs before calling AI).</summary>
public sealed class TrainingDataReader(WFitDbContext db, CatalogService catalog)
{
    public Task<Profile?> LoadProfileAsync(CancellationToken ct) =>
        db.Profiles.AsNoTracking().FirstOrDefaultAsync(p => p.Id == Vocab.ProfileId && !p.Deleted, ct);

    public async Task<Dictionary<string, string>> LoadPreferencesAsync(CancellationToken ct) =>
        await db.ExercisePreferences.AsNoTracking().Where(p => !p.Deleted)
            .ToDictionaryAsync(p => p.ExerciseId, p => p.Preference, ct);

    public async Task<SelectionContext> LoadSelectionContextAsync(string? experience, IEnumerable<string>? occupied, CancellationToken ct)
    {
        var equipment = await db.EquipmentStatuses.AsNoTracking().Where(e => !e.Deleted)
            .ToDictionaryAsync(e => e.EquipmentId, e => e.Available, ct);
        var preferences = await LoadPreferencesAsync(ct);
        return SelectionContext.Create(catalog, experience, equipment, occupied, preferences);
    }

    /// <summary>Last sessions with the best completed set per exercise (e.g. "20kg x 8").</summary>
    public async Task<List<SessionSummary>> LoadRecentSessionsAsync(int count, CancellationToken ct)
    {
        var sessions = await db.WorkoutSessions.AsNoTracking()
            .Where(s => !s.Deleted)
            .OrderByDescending(s => s.StartedAt)
            .Take(count)
            .ToListAsync(ct);
        if (sessions.Count == 0) return [];

        var ids = sessions.Select(s => s.Id).ToArray();
        var sets = await db.SetLogs.AsNoTracking()
            .Where(s => ids.Contains(s.SessionId) && !s.Deleted && s.Completed)
            .ToListAsync(ct);
        var setsBySession = sets.ToLookup(s => s.SessionId);

        return sessions.Select(s => new SessionSummary(
            s.StartedAt.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            s.DayType,
            s.Rating,
            s.PerceivedEffort,
            setsBySession[s.Id]
                .GroupBy(x => x.ExerciseId)
                .OrderBy(g => g.Min(x => x.ExerciseOrder))
                .Select(g => new ExerciseBest(g.Key, FormatBest(g)))
                .ToList()))
            .ToList();
    }

    public static string FormatBest(IEnumerable<SetLog> sets)
    {
        var list = sets.ToList();
        var weighted = list.Where(s => s.WeightKg > 0 && s.Reps > 0)
            .OrderByDescending(s => s.WeightKg).ThenByDescending(s => s.Reps).FirstOrDefault();
        if (weighted is not null)
            return $"{weighted.WeightKg!.Value.ToString("0.##", CultureInfo.InvariantCulture)}kg x {weighted.Reps}";
        var reps = list.Where(s => s.Reps > 0).MaxBy(s => s.Reps);
        if (reps is not null) return $"{reps.Reps} reps";
        var timed = list.Where(s => s.DurationSeconds > 0).MaxBy(s => s.DurationSeconds);
        return timed is not null ? $"{timed.DurationSeconds}s" : "done";
    }
}
