using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using WFit.Api.Data;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Tests;

public class SyncServiceTests
{
    private readonly ManualTimeProvider _time = new(TestEnv.Now);
    private readonly WFitDbContext _db = TestEnv.CreateDb();

    private SyncService Service() => new(_db, TestEnv.Catalog, _time, NullLogger<SyncService>.Instance);

    private static string NewId() => Guid.NewGuid().ToString();

    private static BodyMetricDto Metric(string id, double kg, DateTimeOffset updatedAt) =>
        new() { Id = id, Date = new DateOnly(2026, 11, 3), WeightKg = kg, UpdatedAt = updatedAt };

    [Fact]
    public async Task Full_pull_returns_pushed_records_and_server_time()
    {
        var id = NewId();
        var response = await Service().SyncAsync(new SyncRequest
        {
            Since = null,
            Changes = new SyncChanges
            {
                Profile = new ProfileDto { Name = "Alex", Experience = "beginner", TrainingDays = [5, 1, 3, 9], UpdatedAt = TestEnv.Now },
                BodyMetrics = [Metric(id, 78.4, TestEnv.Now)],
            },
        }, default);

        Assert.Equal(TestEnv.Now, response.ServerTime);
        Assert.Equal("me", response.Changes.Profile!.Id);
        Assert.Equal([1, 3, 5], response.Changes.Profile.TrainingDays);
        Assert.Single(response.Changes.BodyMetrics);
        Assert.Equal(78.4, response.Changes.BodyMetrics[0].WeightKg);
    }

    [Fact]
    public async Task Last_write_wins_by_client_updated_at()
    {
        var id = NewId();
        var t0 = TestEnv.Now;
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = [Metric(id, 80, t0)] } }, default);

        // Older write loses.
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = [Metric(id, 70, t0.AddMinutes(-5))] } }, default);
        Assert.Equal(80, (await _db.BodyMetrics.AsNoTracking().SingleAsync()).WeightKg);

        // Equal timestamp wins (>=).
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = [Metric(id, 81, t0)] } }, default);
        Assert.Equal(81, (await _db.BodyMetrics.AsNoTracking().SingleAsync()).WeightKg);

        // Newer write wins, soft delete propagates.
        await Service().SyncAsync(new SyncRequest
        {
            Changes = new SyncChanges { BodyMetrics = [Metric(id, 82, t0.AddMinutes(1)) with { Deleted = true }] },
        }, default);
        var stored = await _db.BodyMetrics.AsNoTracking().SingleAsync();
        Assert.Equal(82, stored.WeightKg);
        Assert.True(stored.Deleted);
    }

    [Fact]
    public async Task Since_filter_returns_only_records_changed_after_it()
    {
        var first = NewId();
        var r1 = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = [Metric(first, 80, TestEnv.Now)] } }, default);

        _time.Advance(TimeSpan.FromMinutes(10));
        var second = NewId();
        var setId = NewId();
        await Service().SyncAsync(new SyncRequest
        {
            Changes = new SyncChanges
            {
                BodyMetrics = [Metric(second, 79, _time.Now)],
                Sets = [new SetLogDto { Id = setId, SessionId = NewId(), ExerciseId = "push-up", Section = "main", Reps = 10, Completed = true, UpdatedAt = _time.Now }],
            },
        }, default);

        _time.Advance(TimeSpan.FromMinutes(1));
        var pull = await Service().SyncAsync(new SyncRequest { Since = r1.ServerTime }, default);

        Assert.Equal([second], pull.Changes.BodyMetrics.Select(b => b.Id));
        Assert.Equal([setId], pull.Changes.Sets.Select(s => s.Id));
        Assert.Null(pull.Changes.Profile);

        var nothingNew = await Service().SyncAsync(new SyncRequest { Since = pull.ServerTime }, default);
        Assert.Empty(nothingNew.Changes.BodyMetrics);
        Assert.Empty(nothingNew.Changes.Sets);
    }

    [Fact]
    public async Task Invalid_records_are_skipped_without_failing_the_batch()
    {
        var good = NewId();
        var response = await Service().SyncAsync(new SyncRequest
        {
            Changes = new SyncChanges
            {
                Equipment =
                [
                    new EquipmentStatusDto { EquipmentId = "leg_press", Available = false, UpdatedAt = TestEnv.Now },
                    new EquipmentStatusDto { EquipmentId = "time_machine", Available = false, UpdatedAt = TestEnv.Now },
                ],
                ExercisePreferences =
                [
                    new ExercisePreferenceDto { ExerciseId = "push-up", Preference = "liked", UpdatedAt = TestEnv.Now },
                    new ExercisePreferenceDto { ExerciseId = "push-up-9000", Preference = "liked", UpdatedAt = TestEnv.Now },
                    new ExercisePreferenceDto { ExerciseId = "plank", Preference = "love", UpdatedAt = TestEnv.Now },
                ],
                Sets =
                [
                    new SetLogDto { Id = good, SessionId = NewId(), ExerciseId = "push-up", Section = "main", UpdatedAt = TestEnv.Now },
                    new SetLogDto { Id = NewId(), SessionId = NewId(), ExerciseId = "unknown", Section = "main", UpdatedAt = TestEnv.Now },
                    new SetLogDto { Id = "not-a-guid", SessionId = NewId(), ExerciseId = "push-up", Section = "main", UpdatedAt = TestEnv.Now },
                ],
                PlannedWorkouts =
                [
                    new PlannedWorkoutDto
                    {
                        Id = NewId(), Date = new DateOnly(2026, 11, 4), DayType = "push", Title = "Bad", UpdatedAt = TestEnv.Now,
                        Blocks = [new WorkoutBlockDto { Section = "main", Items = [new WorkoutItemDto { ExerciseId = "nope", Sets = 3 }] }],
                    },
                ],
                Sessions = [new WorkoutSessionDto { Id = NewId(), DayType = "arms", UpdatedAt = TestEnv.Now }],
            },
        }, default);

        Assert.Equal(["leg_press"], response.Changes.Equipment.Select(e => e.EquipmentId));
        Assert.Equal(["push-up"], response.Changes.ExercisePreferences.Select(e => e.ExerciseId));
        Assert.Equal([good], response.Changes.Sets.Select(s => s.Id));
        Assert.Empty(response.Changes.PlannedWorkouts);
        Assert.Empty(response.Changes.Sessions);
    }

    [Fact]
    public async Task Guid_ids_are_normalized_to_lower_case()
    {
        var upper = Guid.NewGuid().ToString().ToUpperInvariant();
        var response = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = [Metric(upper, 80, TestEnv.Now)] } }, default);
        Assert.Equal(upper.ToLowerInvariant(), response.Changes.BodyMetrics.Single().Id);
    }

    [Fact]
    public async Task Planned_workout_blocks_round_trip()
    {
        var id = NewId();
        var dto = new PlannedWorkoutDto
        {
            Id = id, Date = new DateOnly(2026, 11, 4), DayType = "push", Title = "Push day", Source = "rules", Status = "planned",
            EstimatedMinutes = 58, CoachNote = "Go.", UpdatedAt = TestEnv.Now,
            Blocks = [new WorkoutBlockDto { Section = "warmup", Items = [new WorkoutItemDto { ExerciseId = "rowing-easy", Sets = 1, DurationSeconds = 300 }] }],
        };

        var response = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { PlannedWorkouts = [dto] } }, default);

        var pulled = response.Changes.PlannedWorkouts.Single();
        Assert.Equal("rowing-easy", pulled.Blocks.Single().Items.Single().ExerciseId);
        Assert.Equal(300, pulled.Blocks[0].Items[0].DurationSeconds);
    }

    [Fact]
    public async Task More_than_2000_records_is_bad_request()
    {
        var metrics = Enumerable.Range(0, 2001).Select(_ => Metric(NewId(), 80, TestEnv.Now)).ToList();
        var ex = await Assert.ThrowsAsync<ApiException>(() =>
            Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { BodyMetrics = metrics } }, default));
        Assert.Equal(400, ex.StatusCode);
        Assert.Equal("bad_request", ex.Error);
    }

    [Fact]
    public void Contract_json_is_camel_case_with_utc_timestamps()
    {
        var json = JsonSerializer.Serialize(
            new SyncResponse(new DateTimeOffset(2026, 11, 3, 20, 0, 0, TimeSpan.FromHours(1)), new SyncChanges()),
            JsonDefaults.Options);

        using var doc = JsonDocument.Parse(json);
        Assert.Equal("2026-11-03T19:00:00Z", doc.RootElement.GetProperty("serverTime").GetString());
        var changes = doc.RootElement.GetProperty("changes");
        Assert.Equal(JsonValueKind.Null, changes.GetProperty("profile").ValueKind);
        foreach (var name in new[] { "equipment", "exercisePreferences", "plannedWorkouts", "sessions", "sets", "bodyMetrics" })
            Assert.Equal(JsonValueKind.Array, changes.GetProperty(name).ValueKind);
    }

    [Fact]
    public void Request_json_from_contract_deserializes()
    {
        const string json = """
            { "since": "2026-11-01T10:00:00Z",
              "changes": { "profile": null, "equipment": [ { "equipmentId": "leg_press", "available": false, "updatedAt": "2026-11-03T19:00:00Z", "deleted": false } ],
                           "exercisePreferences": [], "plannedWorkouts": [], "sessions": [], "sets": [], "bodyMetrics": [] } }
            """;
        var request = JsonSerializer.Deserialize<SyncRequest>(json, JsonDefaults.Options)!;
        Assert.Equal(new DateTimeOffset(2026, 11, 1, 10, 0, 0, TimeSpan.Zero), request.Since);
        Assert.False(request.Changes!.Equipment.Single().Available);
    }
}
