using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using WFit.Api.Data;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;

namespace WFit.Api.Sync;

/// <summary>Push (last-write-wins upsert) + pull (everything changed since <c>since</c>) in one round-trip.</summary>
public sealed class SyncService(WFitDbContext db, CatalogService catalog, TimeProvider time, ILogger<SyncService> logger)
{
    public const int MaxRecords = 2000;
    private const int LookupChunk = 500;

    public async Task<SyncResponse> SyncAsync(SyncRequest request, CancellationToken ct)
    {
        var changes = request.Changes ?? new SyncChanges();
        if (changes.CountRecords() > MaxRecords)
            throw ApiException.BadRequest($"Too many records; the maximum per request is {MaxRecords}.");

        // Captured before writing so the client's next `since` can never skip a concurrent change.
        var serverTime = time.GetUtcNow();
        var skipped = 0;

        if (changes.Profile is not null)
            skipped += await UpsertAsync(db.Profiles, nameof(Profile.Id), [changes.Profile], p => p.Id, PrepareProfile, ct);
        skipped += await UpsertAsync(db.EquipmentStatuses, nameof(EquipmentStatus.EquipmentId), changes.Equipment, e => e.EquipmentId, PrepareEquipment, ct);
        skipped += await UpsertAsync(db.ExercisePreferences, nameof(ExercisePreference.ExerciseId), changes.ExercisePreferences, e => e.ExerciseId, PreparePreference, ct);
        skipped += await UpsertAsync(db.PlannedWorkouts, nameof(PlannedWorkout.Id), changes.PlannedWorkouts, e => e.Id, PreparePlannedWorkout, ct);
        skipped += await UpsertAsync(db.WorkoutSessions, nameof(WorkoutSession.Id), changes.Sessions, e => e.Id, PrepareSession, ct);
        skipped += await UpsertAsync(db.SetLogs, nameof(SetLog.Id), changes.Sets, e => e.Id, PrepareSet, ct);
        skipped += await UpsertAsync(db.BodyMetrics, nameof(BodyMetric.Id), changes.BodyMetrics, e => e.Id, PrepareBodyMetric, ct);

        var stamp = time.GetUtcNow();
        foreach (var entry in db.ChangeTracker.Entries<SyncEntity>())
        {
            if (entry.State is EntityState.Added or EntityState.Modified)
                entry.Entity.ServerUpdatedAt = stamp;
        }
        await db.SaveChangesAsync(ct);

        if (skipped > 0)
            logger.LogWarning("Sync skipped {Count} invalid record(s).", skipped);

        return new SyncResponse(serverTime, await PullAsync(request.Since, ct));
    }

    public async Task<SyncChanges> PullAsync(DateTimeOffset? since, CancellationToken ct)
    {
        IQueryable<T> Changed<T>(DbSet<T> set) where T : SyncEntity =>
            since is { } s ? set.AsNoTracking().Where(x => x.ServerUpdatedAt > s) : set.AsNoTracking();

        var profile = await Changed(db.Profiles).FirstOrDefaultAsync(p => p.Id == Vocab.ProfileId, ct);
        return new SyncChanges
        {
            Profile = profile?.ToDto(),
            Equipment = (await Changed(db.EquipmentStatuses).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
            ExercisePreferences = (await Changed(db.ExercisePreferences).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
            PlannedWorkouts = (await Changed(db.PlannedWorkouts).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
            Sessions = (await Changed(db.WorkoutSessions).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
            Sets = (await Changed(db.SetLogs).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
            BodyMetrics = (await Changed(db.BodyMetrics).ToListAsync(ct)).Select(e => e.ToDto()).ToList(),
        };
    }

    /// <summary>A validated incoming record: its key, and how to create/update the entity.</summary>
    private sealed record Prepared<TEntity>(string Key, Func<TEntity> Create, Action<TEntity> Apply);

    /// <summary>Validates, de-duplicates and upserts records (last-write-wins). Returns the number of invalid records skipped.</summary>
    private async Task<int> UpsertAsync<TDto, TEntity>(
        DbSet<TEntity> set,
        string keyProperty,
        IEnumerable<TDto>? incoming,
        Func<TEntity, string> keyOf,
        Func<TDto, Prepared<TEntity>?> prepare,
        CancellationToken ct)
        where TDto : class, ISyncDto
        where TEntity : SyncEntity
    {
        var skipped = 0;
        var latest = new Dictionary<string, (TDto Dto, Prepared<TEntity> Prepared)>(StringComparer.Ordinal);
        foreach (var dto in incoming ?? [])
        {
            var prepared = dto is null || dto.UpdatedAt == default ? null : prepare(dto);
            if (prepared is null)
            {
                skipped++;
                continue;
            }
            if (!latest.TryGetValue(prepared.Key, out var current) || dto!.UpdatedAt >= current.Dto.UpdatedAt)
                latest[prepared.Key] = (dto!, prepared);
        }
        if (latest.Count == 0) return skipped;

        var existing = new Dictionary<string, TEntity>(StringComparer.Ordinal);
        foreach (var chunk in latest.Keys.Chunk(LookupChunk))
        {
            var rows = await set.Where(e => chunk.Contains(EF.Property<string>(e, keyProperty))).ToListAsync(ct);
            foreach (var row in rows) existing[keyOf(row)] = row;
        }

        foreach (var (key, (dto, prepared)) in latest)
        {
            if (existing.TryGetValue(key, out var entity))
            {
                if (dto.UpdatedAt < entity.UpdatedAt) continue; // stored version is newer
            }
            else
            {
                entity = prepared.Create();
                set.Add(entity);
            }
            prepared.Apply(entity);
            entity.UpdatedAt = dto.UpdatedAt;
            entity.Deleted = dto.Deleted;
        }
        return skipped;
    }

    private static Prepared<Profile>? PrepareProfile(ProfileDto d) =>
        Vocab.Experiences.Contains(d.Experience ?? "")
            ? new(Vocab.ProfileId, () => new Profile { Id = Vocab.ProfileId }, e => e.Apply(d))
            : null;

    private Prepared<EquipmentStatus>? PrepareEquipment(EquipmentStatusDto d) =>
        d.EquipmentId is { } id && catalog.EquipmentById.ContainsKey(id)
            ? new(id, () => new EquipmentStatus { EquipmentId = id }, e => e.Apply(d))
            : null;

    private Prepared<ExercisePreference>? PreparePreference(ExercisePreferenceDto d) =>
        d.ExerciseId is { } id && catalog.ExercisesById.ContainsKey(id) && Vocab.Preferences.Contains(d.Preference ?? "")
            ? new(id, () => new ExercisePreference { ExerciseId = id }, e => e.Apply(d))
            : null;

    private Prepared<PlannedWorkout>? PreparePlannedWorkout(PlannedWorkoutDto d)
    {
        var id = SyncMapper.NormalizeGuid(d.Id);
        if (id is null
            || !Vocab.DayTypes.Contains(d.DayType ?? "")
            || !Vocab.Sources.Contains(d.Source ?? "")
            || !Vocab.Statuses.Contains(d.Status ?? ""))
            return null;

        foreach (var block in d.Blocks ?? [])
        {
            if (block is null || !Vocab.Sections.Contains(block.Section ?? "")) return null;
            if ((block.Items ?? []).Any(i => i is null || !catalog.ExercisesById.ContainsKey(i.ExerciseId ?? ""))) return null;
        }
        return new(id, () => new PlannedWorkout { Id = id }, e => e.Apply(d));
    }

    private static Prepared<WorkoutSession>? PrepareSession(WorkoutSessionDto d)
    {
        var id = SyncMapper.NormalizeGuid(d.Id);
        var plannedId = d.PlannedWorkoutId is null ? null : SyncMapper.NormalizeGuid(d.PlannedWorkoutId);
        if (id is null || !Vocab.DayTypes.Contains(d.DayType ?? "") || (d.PlannedWorkoutId is not null && plannedId is null))
            return null;
        return new(id, () => new WorkoutSession { Id = id }, e => e.Apply(d, plannedId));
    }

    private Prepared<SetLog>? PrepareSet(SetLogDto d)
    {
        var id = SyncMapper.NormalizeGuid(d.Id);
        var sessionId = SyncMapper.NormalizeGuid(d.SessionId);
        if (id is null || sessionId is null
            || !catalog.ExercisesById.ContainsKey(d.ExerciseId ?? "")
            || !Vocab.Sections.Contains(d.Section ?? ""))
            return null;
        return new(id, () => new SetLog { Id = id }, e => e.Apply(d, sessionId));
    }

    private static Prepared<BodyMetric>? PrepareBodyMetric(BodyMetricDto d)
    {
        var id = SyncMapper.NormalizeGuid(d.Id);
        return id is null ? null : new(id, () => new BodyMetric { Id = id }, e => e.Apply(d));
    }
}
