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
    public async Task Profile_training_preferences_round_trip_and_are_clamped()
    {
        var response = await Service().SyncAsync(new SyncRequest
        {
            Since = null,
            Changes = new SyncChanges
            {
                Profile = new ProfileDto
                {
                    Name = "Alex", RestMode = "turbo", CooldownStretches = 9,
                    BarWeights = new() { ["smith_machine"] = 15, ["barbell"] = 500 },
                    MuscleFocus = new MuscleFocusDto { Less = ["side_delts", "neck"], More = ["glutes", "side_delts"], Light = ["lower_back"] },
                    UpdatedAt = TestEnv.Now,
                },
            },
        }, default);

        var p = response.Changes.Profile!;
        Assert.Equal("normal", p.RestMode);
        Assert.Equal(3, p.CooldownStretches);
        Assert.Equal(new Dictionary<string, double> { ["smith_machine"] = 15 }, p.BarWeights);
        Assert.Empty(p.MuscleFocus!.Less); // "neck" is not tracked, side_delts moved to more
        Assert.Equal(["glutes", "side_delts"], p.MuscleFocus.More);
        Assert.Equal(["lower_back"], p.MuscleFocus.Light);
    }

    [Fact]
    public async Task Numbered_stacks_round_trip_and_survive_an_older_app()
    {
        var setId = NewId();
        var response = await Service().SyncAsync(new SyncRequest
        {
            Changes = new SyncChanges
            {
                Profile = new ProfileDto { StackPlates = new() { ["seated_row_machine"] = 4.54, ["leg_curl"] = 0, ["leg_press"] = 80 }, UpdatedAt = TestEnv.Now },
                Sets = [new SetLogDto { Id = setId, SessionId = NewId(), ExerciseId = "seated-cable-row", WeightKg = 31.78, Plate = 7, Reps = 10, Completed = true, UpdatedAt = TestEnv.Now }],
            },
        }, default);

        Assert.Equal(new Dictionary<string, double> { ["seated_row_machine"] = 4.54 }, response.Changes.Profile!.StackPlates);
        var set = Assert.Single(response.Changes.Sets);
        Assert.Equal((31.78, 7d), (set.WeightKg, set.Plate));

        // An app that does not know the setting leaves it alone; an empty one clears it.
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { Profile = new ProfileDto { Name = "Alex", UpdatedAt = TestEnv.Now.AddMinutes(1) } } }, default);
        var kept = await Service().SyncAsync(new SyncRequest(), default);
        Assert.Equal("Alex", kept.Changes.Profile!.Name);
        Assert.Single(kept.Changes.Profile.StackPlates!);
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { Profile = new ProfileDto { StackPlates = [], UpdatedAt = TestEnv.Now.AddMinutes(2) } } }, default);
        Assert.Empty((await Service().SyncAsync(new SyncRequest(), default)).Changes.Profile!.StackPlates!);
    }

    [Theory]
    [InlineData(128, 128)]
    [InlineData(30, 30)]
    [InlineData(230, 230)]
    [InlineData(12, null)]
    [InlineData(400, null)]
    [InlineData(null, null)]
    public void Session_heart_rate_is_kept_only_when_plausible(int? bpm, int? expected) =>
        Assert.Equal(expected, SyncMapper.HeartRate(bpm));

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
            Blocks = [new WorkoutBlockDto { Section = "warmup", Items = [new WorkoutItemDto { ExerciseId = "rowing-easy", Sets = 1, DurationSeconds = 300, PerSide = true }] }],
        };

        var response = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { PlannedWorkouts = [dto] } }, default);

        var pulled = response.Changes.PlannedWorkouts.Single();
        Assert.Equal("rowing-easy", pulled.Blocks.Single().Items.Single().ExerciseId);
        Assert.True(pulled.Blocks.Single().Items.Single().PerSide); // the app's per-side marker survives the round trip
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
        foreach (var name in new[] { "equipment", "exercisePreferences", "plannedWorkouts", "sessions", "sets", "bodyMetrics", "feedbackEntries" })
            Assert.Equal(JsonValueKind.Array, changes.GetProperty(name).ValueKind);
    }

    private static FeedbackEntryDto Feedback(string kind = "pain", string? region = "neck", int? severity = 2, string? exerciseId = null) => new()
    {
        Id = NewId(), CreatedAt = TestEnv.Now.AddHours(-1), Kind = kind, Region = region, Severity = severity, ExerciseId = exerciseId,
        SessionId = NewId(), Note = "Neck stiff after shrugs", Status = "active", ReviewOn = new DateOnly(2026, 11, 16),
        Source = "user", UpdatedAt = TestEnv.Now,
    };

    [Fact]
    public async Task Feedback_entries_round_trip()
    {
        var entry = Feedback();
        var resolved = Feedback("discomfort", "knee", 1, "leg-extension") with
        {
            Status = "resolved", ResolvedAt = TestEnv.Now, SessionId = null, Source = "coach", Note = new string('n', 2500),
        };

        var response = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { FeedbackEntries = [entry, resolved] } }, default);

        var pulled = response.Changes.FeedbackEntries.ToDictionary(f => f.Id);
        Assert.Equal(2, pulled.Count);
        var neck = pulled[entry.Id];
        Assert.Equal(("pain", "neck", 2), (neck.Kind, neck.Region, neck.Severity!.Value));
        Assert.Equal(entry.SessionId, neck.SessionId);
        Assert.Equal(new DateOnly(2026, 11, 16), neck.ReviewOn);
        Assert.Equal(TestEnv.Now.AddHours(-1), neck.CreatedAt);
        Assert.Equal("Neck stiff after shrugs", neck.Note);
        var knee = pulled[resolved.Id];
        Assert.Equal(("resolved", "coach", "leg-extension"), (knee.Status, knee.Source, knee.ExerciseId));
        Assert.Equal(TestEnv.Now, knee.ResolvedAt);
        Assert.Null(knee.SessionId);
        Assert.Equal(2000, knee.Note!.Length);
    }

    [Fact]
    public async Task Invalid_feedback_entries_are_skipped()
    {
        var good = Feedback();
        var noCreatedAt = Feedback("too_easy", null, null, "push-up") with { CreatedAt = null };
        var response = await Service().SyncAsync(new SyncRequest
        {
            Changes = new SyncChanges
            {
                FeedbackEntries =
                [
                    good,
                    noCreatedAt,
                    Feedback() with { Id = "not-a-guid" },
                    Feedback() with { SessionId = "not-a-guid" },
                    Feedback("hungry"),
                    Feedback() with { Status = "open" },
                    Feedback() with { Source = "doctor" },
                    Feedback(region: "toe"),
                    Feedback(severity: 4),
                    Feedback(severity: 0),
                    Feedback(exerciseId: "push-up-9000"),
                    Feedback("pain", region: null, severity: 2, exerciseId: null),
                ],
            },
        }, default);

        Assert.Equal(new[] { good.Id, noCreatedAt.Id }.Order(), response.Changes.FeedbackEntries.Select(f => f.Id).Order());
        Assert.Equal(TestEnv.Now, response.Changes.FeedbackEntries.Single(f => f.Id == noCreatedAt.Id).CreatedAt); // defaults to updatedAt
    }

    [Fact]
    public async Task Feedback_entries_use_last_write_wins_and_since()
    {
        var entry = Feedback();
        var first = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { FeedbackEntries = [entry] } }, default);

        _time.Advance(TimeSpan.FromMinutes(5));
        var resolved = entry with { Status = "resolved", ResolvedAt = _time.Now, UpdatedAt = _time.Now };
        var stale = entry with { Note = "stale", UpdatedAt = TestEnv.Now.AddMinutes(-1) };
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { FeedbackEntries = [resolved] } }, default);
        await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { FeedbackEntries = [stale] } }, default);

        var pull = await Service().SyncAsync(new SyncRequest { Since = first.ServerTime }, default);
        var pulled = Assert.Single(pull.Changes.FeedbackEntries);
        Assert.Equal("resolved", pulled.Status);
        Assert.Equal("Neck stiff after shrugs", pulled.Note);
    }

    [Fact]
    public async Task Planned_workout_meta_json_round_trips_and_invalid_meta_becomes_empty_object()
    {
        const string meta = """{"program":"Block 2 · Week 3 · Push B","variant":"B","deload":false,"focus":["biceps"],"rationale":["Biceps 3.5 of 4-10 sets"],"changes":[]}""";
        PlannedWorkoutDto Plan(string? metaJson) => new()
        {
            Id = NewId(), Date = new DateOnly(2026, 11, 9), DayType = "push", Title = "Push B", Source = "ai", Status = "planned",
            EstimatedMinutes = 58, UpdatedAt = TestEnv.Now, MetaJson = metaJson,
            Blocks = [new WorkoutBlockDto { Section = "main", Items = [new WorkoutItemDto { ExerciseId = "machine-chest-press", Sets = 3 }] }],
        };
        var good = Plan(meta);
        var missing = Plan(null);
        var array = Plan("[1,2]");
        var broken = Plan("{not json");
        var tooLong = Plan($$"""{"rationale":["{{new string('x', 8000)}}"]}""");

        var response = await Service().SyncAsync(new SyncRequest { Changes = new SyncChanges { PlannedWorkouts = [good, missing, array, broken, tooLong] } }, default);

        var byId = response.Changes.PlannedWorkouts.ToDictionary(p => p.Id, p => p.MetaJson);
        Assert.Equal(5, byId.Count);
        Assert.Equal(meta, byId[good.Id]);
        Assert.All(new[] { missing, array, broken, tooLong }, p => Assert.Equal("{}", byId[p.Id]));

        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(response.Changes.PlannedWorkouts[0], JsonDefaults.Options));
        Assert.Equal(JsonValueKind.String, doc.RootElement.GetProperty("metaJson").ValueKind);
    }

    [Fact]
    public void Feedback_request_json_from_contract_deserializes()
    {
        const string json = """
            { "since": null, "changes": { "feedbackEntries": [ { "id": "4c9a3f0e-55e4-4ab4-9a59-3b8c2f4f7d10", "createdAt": "2026-11-07T18:00:00Z",
              "kind": "pain", "region": "neck", "severity": 2, "exerciseId": null, "sessionId": null, "note": "stiff", "status": "active",
              "reviewOn": "2026-11-14", "resolvedAt": null, "source": "user", "updatedAt": "2026-11-07T18:00:00Z", "deleted": false } ] } }
            """;
        var request = JsonSerializer.Deserialize<SyncRequest>(json, JsonDefaults.Options)!;
        var entry = request.Changes!.FeedbackEntries.Single();
        Assert.Equal(new DateOnly(2026, 11, 14), entry.ReviewOn);
        Assert.Equal(2, entry.Severity);
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
