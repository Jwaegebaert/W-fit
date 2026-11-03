using System.Globalization;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using WFit.Api.Data;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Ai;

public sealed record WeekStat(string WeekStart, int Sessions, double VolumeKg);

public sealed record ExerciseProgress(string ExerciseId, string Name, int Sessions, double FirstE1rmKg, double BestE1rmKg, string BestSet, string BestDate);

public sealed record BodyweightTrend(string FirstDate, double FirstKg, string LastDate, double LastKg, double ChangeKg);

public sealed record TrainingStats(
    int Sessions,
    int CompletedSets,
    IReadOnlyList<WeekStat> Weeks,
    IReadOnlyList<ExerciseProgress> Progress,
    BodyweightTrend? Bodyweight,
    double? AverageRating,
    double? AveragePerceivedEffort);

/// <summary>POST /ai/insights — 8-week stats computed server-side, summarised by the model, cached per UTC day.</summary>
public sealed class InsightsService(WFitDbContext db, CatalogService catalog, AiUsageService usage, TimeProvider time)
{
    public const int WindowDays = 56;
    public const int MaxItems = 4;
    private const int MaxProgressExercises = 12;

    public async Task<InsightsResponse> GetAsync(InsightsRequest request, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var today = DateOnly.FromDateTime(now.UtcDateTime);

        if (!request.Force)
        {
            var cached = await db.InsightsCache.AsNoTracking().FirstOrDefaultAsync(c => c.Day == today, ct);
            if (cached is not null && TryDeserialize(cached.Json) is { } hit)
                return hit with { Cached = true, Usage = await usage.GetUsageAsync(ct) };
        }

        var stats = await ComputeStatsAsync(now, ct);
        if (stats.Sessions == 0)
            return RulesResponse(now, await usage.GetUsageAsync(ct));

        var prompt = new AiPrompt("progress_insights", AiPrompts.InsightsSystem, AiPrompts.Serialize(new { periodDays = WindowDays, stats }), AiSchemas.Insights());
        var output = await usage.CompleteJsonAsync<AiInsightsOutput>(prompt, ct);
        if (string.IsNullOrWhiteSpace(output.Summary))
            throw ApiException.AiUnavailable();

        var response = new InsightsResponse(
            now,
            SyncMapper.Trunc(output.Summary.Trim(), 1000),
            CleanList(output.Highlights),
            CleanList(output.Recommendations),
            SyncMapper.Trunc(output.NextFocus?.Trim(), 300),
            "ai",
            Cached: false,
            Usage: null);

        var json = JsonSerializer.Serialize(response, JsonDefaults.Options);
        var row = await db.InsightsCache.FirstOrDefaultAsync(c => c.Day == today, ct);
        if (row is null) db.InsightsCache.Add(new InsightsCache { Day = today, Json = json, GeneratedAt = now });
        else
        {
            row.Json = json;
            row.GeneratedAt = now;
        }
        await db.SaveChangesAsync(ct);

        return response with { Usage = await usage.GetUsageAsync(ct) };
    }

    public async Task<TrainingStats> ComputeStatsAsync(DateTimeOffset now, CancellationToken ct)
    {
        var from = now.AddDays(-WindowDays);
        var sessions = await db.WorkoutSessions.AsNoTracking()
            .Where(s => !s.Deleted && s.StartedAt >= from)
            .ToListAsync(ct);

        var sets = new List<SetLog>();
        foreach (var chunk in sessions.Select(s => s.Id).Chunk(500))
        {
            sets.AddRange(await db.SetLogs.AsNoTracking()
                .Where(s => chunk.Contains(s.SessionId) && !s.Deleted && s.Completed)
                .ToListAsync(ct));
        }

        var fromDate = DateOnly.FromDateTime(from.UtcDateTime);
        var weights = await db.BodyMetrics.AsNoTracking()
            .Where(b => !b.Deleted && b.WeightKg != null && b.Date >= fromDate)
            .OrderBy(b => b.Date)
            .ToListAsync(ct);

        return BuildStats(sessions, sets, weights, catalog);
    }

    /// <summary>Pure aggregation: weekly sessions/volume, Epley e1RM progress, bodyweight trend, averages.</summary>
    public static TrainingStats BuildStats(
        IReadOnlyList<WorkoutSession> sessions, IReadOnlyList<SetLog> sets, IReadOnlyList<BodyMetric> weights, CatalogService catalog)
    {
        var sessionById = sessions.ToDictionary(s => s.Id);
        var setsBySession = sets.ToLookup(s => s.SessionId);

        var weeks = sessions
            .GroupBy(s => WeekStart(s.StartedAt))
            .OrderBy(g => g.Key)
            .Select(g => new WeekStat(
                g.Key.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                g.Count(),
                Math.Round(g.SelectMany(s => setsBySession[s.Id]).Sum(Volume), 1)))
            .ToList();

        var progress = sets
            .Where(s => s.WeightKg > 0 && s.Reps > 0 && sessionById.ContainsKey(s.SessionId))
            .GroupBy(s => s.ExerciseId)
            .Select(g =>
            {
                var ordered = g.OrderBy(s => sessionById[s.SessionId].StartedAt).ToList();
                var firstSession = ordered[0].SessionId;
                var first = ordered.Where(s => s.SessionId == firstSession).Max(E1rm);
                var best = ordered.MaxBy(E1rm)!;
                return new ExerciseProgress(
                    g.Key,
                    catalog.FindExercise(g.Key)?.Name ?? g.Key,
                    g.Select(s => s.SessionId).Distinct().Count(),
                    Math.Round(first, 1),
                    Math.Round(E1rm(best), 1),
                    $"{best.WeightKg!.Value.ToString("0.##", CultureInfo.InvariantCulture)}kg x {best.Reps}",
                    sessionById[best.SessionId].StartedAt.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            })
            .OrderByDescending(p => p.Sessions)
            .ThenByDescending(p => p.BestE1rmKg - p.FirstE1rmKg)
            .Take(MaxProgressExercises)
            .ToList();

        BodyweightTrend? trend = null;
        if (weights.Count > 0)
        {
            var first = weights[0];
            var last = weights[^1];
            trend = new BodyweightTrend(
                first.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), first.WeightKg!.Value,
                last.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), last.WeightKg!.Value,
                Math.Round(last.WeightKg.Value - first.WeightKg.Value, 1));
        }

        static double? Avg(IEnumerable<int?> values)
        {
            var list = values.Where(v => v.HasValue).Select(v => v!.Value).ToList();
            return list.Count == 0 ? null : Math.Round(list.Average(), 1);
        }

        return new TrainingStats(
            sessions.Count,
            sets.Count,
            weeks,
            progress,
            trend,
            Avg(sessions.Select(s => s.Rating)),
            Avg(sessions.Select(s => s.PerceivedEffort)));
    }

    /// <summary>Epley estimated one-rep max.</summary>
    public static double E1rm(SetLog s) => s.WeightKg is > 0 && s.Reps is > 0 ? s.WeightKg.Value * (1 + s.Reps.Value / 30.0) : 0;

    private static double Volume(SetLog s) => s.WeightKg is > 0 && s.Reps is > 0 ? s.WeightKg.Value * s.Reps.Value : 0;

    private static DateOnly WeekStart(DateTimeOffset t)
    {
        var date = DateOnly.FromDateTime(t.UtcDateTime);
        var offset = ((int)date.DayOfWeek + 6) % 7; // Monday = 0
        return date.AddDays(-offset);
    }

    private static List<string> CleanList(IEnumerable<string>? items) =>
        (items ?? []).Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => SyncMapper.Trunc(s.Trim(), 300)).Take(MaxItems).ToList();

    private static InsightsResponse? TryDeserialize(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<InsightsResponse>(json, JsonDefaults.Options);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static InsightsResponse RulesResponse(DateTimeOffset now, AiUsageDto usage) => new(
        now,
        "No workouts logged in the last 8 weeks yet. Your progress insights will appear after your first sessions.",
        [],
        [
            "Train 3 times per week following the Push / Pull / Legs rotation.",
            "Keep 2-3 reps in reserve on every set and focus on smooth, controlled technique.",
            "Log your bodyweight once a week to see the trend.",
        ],
        "Complete your first Push, Pull and Legs sessions.",
        "rules",
        Cached: false,
        Usage: usage);
}
