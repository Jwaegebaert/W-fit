using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using WFit.Api.Ai;
using WFit.Api.Data;
using WFit.Api.Functions;
using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class AiEndpointTests
{
    private readonly ManualTimeProvider _time = new(TestEnv.Now);
    private readonly WFitDbContext _db = TestEnv.CreateDb();
    private readonly FakeAiClient _ai = new();

    private const string CannedWorkout = """
        {
          "title": "Push day: press & power",
          "coachNote": "Smooth reps, 2-3 in reserve.",
          "estimatedMinutes": 58,
          "blocks": [
            { "section": "warmup", "items": [
              { "exerciseId": "rowing-easy", "sets": 1, "repMin": null, "repMax": null, "durationSeconds": 300, "restSeconds": 0, "targetWeightKg": null, "notes": "Easy pace" },
              { "exerciseId": "band-pull-apart", "sets": 2, "repMin": 12, "repMax": 15, "durationSeconds": null, "restSeconds": 15, "targetWeightKg": null, "notes": "" } ] },
            { "section": "main", "items": [
              { "exerciseId": "medicine-ball-chest-pass", "sets": 3, "repMin": 5, "repMax": 6, "durationSeconds": null, "restSeconds": 90, "targetWeightKg": 4, "notes": "Explode" },
              { "exerciseId": "dumbbell-bench-press", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 120, "targetWeightKg": 16, "notes": "" },
              { "exerciseId": "lat-pulldown", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 90, "targetWeightKg": 30, "notes": "wrong day" },
              { "exerciseId": "seated-dumbbell-shoulder-press", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 400, "targetWeightKg": 10, "notes": "" } ] },
            { "section": "core", "items": [
              { "exerciseId": "plank", "sets": 2, "repMin": null, "repMax": null, "durationSeconds": 30, "restSeconds": 30, "targetWeightKg": null, "notes": "" } ] },
            { "section": "cooldown", "items": [
              { "exerciseId": "chest-doorway-stretch", "sets": 1, "repMin": null, "repMax": null, "durationSeconds": 60, "restSeconds": 0, "targetWeightKg": null, "notes": "" } ] }
          ]
        }
        """;

    private AiUsageService Usage(AiSettings? settings = null) => TestEnv.Usage(_db, _ai, _time, settings);

    private AiFunctions Functions(AiSettings? settings = null)
    {
        var usage = Usage(settings);
        var reader = new TrainingDataReader(_db, TestEnv.Catalog);
        return new AiFunctions(
            new WorkoutAiService(_db, TestEnv.Catalog, reader, usage, _time),
            new SwapAiService(TestEnv.Catalog, reader, usage),
            new InsightsService(_db, TestEnv.Catalog, usage, _time),
            usage);
    }

    private static HttpRequest Request(string? body)
    {
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = "POST";
        ctx.Request.ContentType = "application/json";
        ctx.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes(body ?? ""));
        ctx.Response.Body = new MemoryStream();
        return ctx.Request;
    }

    private static async Task<(int Status, JsonElement Body)> Execute(IActionResult result, HttpRequest req)
    {
        await result.ExecuteResultAsync(new ActionContext(req.HttpContext, new RouteData(), new ActionDescriptor()));
        var stream = (MemoryStream)req.HttpContext.Response.Body;
        using var doc = JsonDocument.Parse(stream.ToArray());
        return (req.HttpContext.Response.StatusCode, doc.RootElement.Clone());
    }

    private static async Task<(int Status, JsonElement Body)> Invoke(Func<HttpRequest, Task<IActionResult>> function, string body)
    {
        var req = Request(body);
        return await Execute(await function(req), req);
    }

    [Fact]
    public async Task Workout_endpoint_validates_saves_and_returns_contract_shape()
    {
        _ai.Returns(CannedWorkout, 2500, 700);
        _db.EquipmentStatuses.Add(new EquipmentStatus { EquipmentId = "cable_machine", Available = false, UpdatedAt = TestEnv.Now, ServerUpdatedAt = TestEnv.Now });
        await _db.SaveChangesAsync();

        var req = Request("""{ "dayType": "push", "date": "2026-11-04", "sessionMinutes": 60, "includeCore": false, "occupiedEquipment": ["flat_bench"], "userNote": "left shoulder a bit stiff" }""");
        var (status, body) = await Execute(await Functions().Workout(req), req);

        Assert.Equal(200, status);
        var workout = body.GetProperty("workout");
        Assert.Equal("push", workout.GetProperty("dayType").GetString());
        Assert.Equal("2026-11-04", workout.GetProperty("date").GetString());
        Assert.Equal("ai", workout.GetProperty("source").GetString());
        Assert.Equal("planned", workout.GetProperty("status").GetString());
        Assert.True(Guid.TryParse(workout.GetProperty("id").GetString(), out _));
        Assert.EndsWith("Z", workout.GetProperty("updatedAt").GetString());

        var sections = workout.GetProperty("blocks").EnumerateArray().Select(b => b.GetProperty("section").GetString()).ToList();
        Assert.Equal(["warmup", "main", "cooldown"], sections); // includeCore=false drops core

        var main = workout.GetProperty("blocks")[1].GetProperty("items").EnumerateArray().ToList();
        var mainIds = main.Select(i => i.GetProperty("exerciseId").GetString()).ToList();
        // dumbbell-bench-press needs the occupied flat bench; lat-pulldown is not a push exercise.
        Assert.Equal(["medicine-ball-chest-pass", "seated-dumbbell-shoulder-press"], mainIds);
        Assert.Equal(240, main[1].GetProperty("restSeconds").GetInt32());

        var usage = body.GetProperty("usage");
        Assert.Equal(1, usage.GetProperty("callsToday").GetInt32());
        Assert.Equal(3200, usage.GetProperty("tokensThisMonth").GetInt64());

        var saved = await _db.PlannedWorkouts.AsNoTracking().SingleAsync();
        Assert.Equal("ai", saved.Source);
        Assert.Equal(TestEnv.Now, saved.ServerUpdatedAt);

        // Prompt only offered eligible candidates.
        var prompt = _ai.Prompts.Single();
        Assert.DoesNotContain("cable-lateral-raise", prompt.UserPrompt); // cable machine unavailable
        Assert.DoesNotContain("\"dumbbell-bench-press\"", prompt.JsonSchema); // flat bench occupied
        Assert.Contains("left shoulder a bit stiff", prompt.UserPrompt);
    }

    [Fact]
    public async Task Workout_endpoint_requires_day_type()
    {
        var req = Request("""{ "date": "2026-11-04" }""");
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(req));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public async Task Workout_endpoint_rejects_invalid_enum()
    {
        var req = Request("""{ "dayType": "arms" }""");
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(req));
        Assert.Equal("bad_request", ex.Error);
    }

    [Fact]
    public async Task Workout_with_unusable_ai_output_is_ai_unavailable()
    {
        _ai.Returns("""{"title":"x","coachNote":"","estimatedMinutes":50,"blocks":[{"section":"main","items":[]}]}""");
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(Request("""{ "dayType": "legs" }""")));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.Empty(_db.PlannedWorkouts);
    }

    [Fact]
    public async Task Workout_includes_recent_history_in_context()
    {
        var sessionId = Guid.NewGuid().ToString();
        _db.WorkoutSessions.Add(new WorkoutSession { Id = sessionId, DayType = "push", Title = "Push", StartedAt = TestEnv.Now.AddDays(-2), Rating = 4, PerceivedEffort = 7 });
        _db.SetLogs.Add(new SetLog { Id = Guid.NewGuid().ToString(), SessionId = sessionId, ExerciseId = "dumbbell-bench-press", Section = "main", WeightKg = 16, Reps = 10, Completed = true });
        _db.SetLogs.Add(new SetLog { Id = Guid.NewGuid().ToString(), SessionId = sessionId, ExerciseId = "dumbbell-bench-press", Section = "main", WeightKg = 18, Reps = 6, Completed = true });
        await _db.SaveChangesAsync();
        _ai.Returns(CannedWorkout);

        await Functions().Workout(Request("""{ "dayType": "push" }"""));

        Assert.Contains("18kg x 6", _ai.Prompts.Single().UserPrompt);
    }

    [Fact]
    public async Task Swap_returns_validated_ai_suggestions()
    {
        _ai.Returns("""{"suggestions":[{"exerciseId":"machine-chest-press","why":"Same pressing pattern, no bench needed.","sets":3,"repMin":8,"repMax":12,"restSeconds":90},{"exerciseId":"barbell-bench-press","why":"original","sets":3,"repMin":8,"repMax":12,"restSeconds":90}]}""");
        var req = Request("""{ "exerciseId": "barbell-bench-press", "reason": "occupied", "dayType": "push", "section": "main", "excludeExerciseIds": ["incline-dumbbell-press"], "occupiedEquipment": ["flat_bench"], "note": "" }""");

        var (status, body) = await Execute(await Functions().Swap(req), req);

        Assert.Equal(200, status);
        Assert.Equal("ai", body.GetProperty("source").GetString());
        var suggestions = body.GetProperty("suggestions").EnumerateArray().ToList();
        Assert.Single(suggestions);
        Assert.Equal("machine-chest-press", suggestions[0].GetProperty("exerciseId").GetString());
        Assert.Equal(1, body.GetProperty("usage").GetProperty("callsToday").GetInt32());
        Assert.DoesNotContain("\"dumbbell-bench-press\"", _ai.Prompts.Single().JsonSchema); // needs occupied flat bench
    }

    [Fact]
    public async Task Swap_falls_back_to_rule_ranking_when_ai_returns_nothing_valid()
    {
        _ai.Returns("""{"suggestions":[]}""");
        var req = Request("""{ "exerciseId": "barbell-bench-press", "reason": "preference", "dayType": "push", "section": "main" }""");

        var (status, body) = await Execute(await Functions().Swap(req), req);

        Assert.Equal(200, status);
        Assert.Equal("rules", body.GetProperty("source").GetString());
        var suggestions = body.GetProperty("suggestions").EnumerateArray().ToList();
        Assert.Equal(3, suggestions.Count);
        Assert.All(suggestions, s => Assert.NotEqual("barbell-bench-press", s.GetProperty("exerciseId").GetString()));
    }

    [Fact]
    public async Task Swap_unknown_exercise_is_bad_request()
    {
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Swap(Request("""{ "exerciseId": "nope" }""")));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public async Task Insights_without_sessions_uses_rules_and_no_ai_call()
    {
        var req = Request("");
        var (status, body) = await Execute(await Functions().Insights(req), req);

        Assert.Equal(200, status);
        Assert.Equal("rules", body.GetProperty("source").GetString());
        Assert.False(body.GetProperty("cached").GetBoolean());
        Assert.Empty(_ai.Prompts);
        Assert.Equal(0, body.GetProperty("usage").GetProperty("callsToday").GetInt32());
    }

    [Fact]
    public async Task Insights_are_cached_per_day_and_force_bypasses_cache()
    {
        var sessionId = Guid.NewGuid().ToString();
        _db.WorkoutSessions.Add(new WorkoutSession { Id = sessionId, DayType = "legs", Title = "Legs", StartedAt = TestEnv.Now.AddDays(-3), Rating = 4 });
        _db.SetLogs.Add(new SetLog { Id = Guid.NewGuid().ToString(), SessionId = sessionId, ExerciseId = "goblet-squat", Section = "main", WeightKg = 20, Reps = 10, Completed = true });
        _db.BodyMetrics.Add(new BodyMetric { Id = Guid.NewGuid().ToString(), Date = new DateOnly(2026, 10, 1), WeightKg = 80 });
        _db.BodyMetrics.Add(new BodyMetric { Id = Guid.NewGuid().ToString(), Date = new DateOnly(2026, 11, 2), WeightKg = 78.5 });
        await _db.SaveChangesAsync();
        const string answer = """{"summary":"Good start.","highlights":["a","b","c","d","e"],"recommendations":["r"],"nextFocus":"Keep going."}""";
        _ai.Returns(answer).Returns(answer);

        var first = await Invoke(r => Functions().Insights(r), """{ "force": false }""");
        Assert.Equal("ai", first.Body.GetProperty("source").GetString());
        Assert.False(first.Body.GetProperty("cached").GetBoolean());
        Assert.Equal(4, first.Body.GetProperty("highlights").GetArrayLength());
        Assert.Contains("goblet-squat", _ai.Prompts[0].UserPrompt);
        Assert.Contains("-1.5", _ai.Prompts[0].UserPrompt); // bodyweight change

        var second = await Invoke(r => Functions().Insights(r), """{ "force": false }""");
        Assert.True(second.Body.GetProperty("cached").GetBoolean());
        Assert.Single(_ai.Prompts);
        Assert.Equal(1, second.Body.GetProperty("usage").GetProperty("callsToday").GetInt32());

        var forced = await Invoke(r => Functions().Insights(r), """{ "force": true }""");
        Assert.False(forced.Body.GetProperty("cached").GetBoolean());
        Assert.Equal(2, _ai.Prompts.Count);
        Assert.Equal(2, forced.Body.GetProperty("usage").GetProperty("callsToday").GetInt32());
    }

    [Fact]
    public async Task Usage_endpoint_returns_contract_shape()
    {
        var req = Request(null);
        var (status, body) = await Execute(await Functions(TestEnv.Settings(daily: 10)).Usage(req), req);

        Assert.Equal(200, status);
        Assert.True(body.GetProperty("enabled").GetBoolean());
        Assert.Equal(0, body.GetProperty("callsToday").GetInt32());
        Assert.Equal(10, body.GetProperty("dailyCallLimit").GetInt32());
        Assert.Equal(0, body.GetProperty("tokensThisMonth").GetInt64());
        Assert.Equal(2_000_000, body.GetProperty("monthlyTokenLimit").GetInt64());
    }

    [Fact]
    public async Task Health_returns_ok()
    {
        var req = Request(null);
        var (status, body) = await Execute(new HealthFunction().Run(req), req);
        Assert.Equal(200, status);
        Assert.Equal("ok", body.GetProperty("status").GetString());
        Assert.Equal("1.0.0", body.GetProperty("version").GetString());
    }
}
