using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Logging.Abstractions;
using WFit.Api.Ai;
using WFit.Api.Domain;
using WFit.Api.Functions;
using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class AiEndpointTests
{
    private readonly ManualTimeProvider _time = new(TestEnv.Now);
    private readonly FakeAiClient _ai = new();
    private readonly InMemoryAiUsageStore _store = new();
    private static readonly CatalogService Catalog = TestEnv.StressCatalog;

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
              { "exerciseId": "dumbbell-bench-press", "sets": 4, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 120, "targetWeightKg": 16, "notes": "" },
              { "exerciseId": "lat-pulldown", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 90, "targetWeightKg": 30, "notes": "wrong day" },
              { "exerciseId": "seated-dumbbell-shoulder-press", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 400, "targetWeightKg": 10, "notes": "" },
              { "exerciseId": "machine-chest-press", "sets": 4, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 120, "targetWeightKg": 40, "notes": "" },
              { "exerciseId": "cable-lateral-raise", "sets": 3, "repMin": 12, "repMax": 15, "durationSeconds": null, "restSeconds": 60, "targetWeightKg": 5, "notes": "" } ] },
            { "section": "core", "items": [
              { "exerciseId": "plank", "sets": 2, "repMin": null, "repMax": null, "durationSeconds": 30, "restSeconds": 30, "targetWeightKg": null, "notes": "" } ] },
            { "section": "cooldown", "items": [
              { "exerciseId": "chest-doorway-stretch", "sets": 1, "repMin": null, "repMax": null, "durationSeconds": 60, "restSeconds": 0, "targetWeightKg": null, "notes": "" } ] }
          ],
          "focus": ["side_delts", "biceps", "not_a_muscle"],
          "rationale": ["Side delts 3 of 5-10 sets -> +1 set on lateral raises", "", "Kept the chest press anchor for progression"],
          "changes": [ { "from": "incline-dumbbell-press", "to": "machine-chest-press", "reason": "neck" },
                       { "from": "nope", "to": "machine-chest-press", "reason": "x" },
                       { "from": "incline-dumbbell-press", "to": "lat-pulldown", "reason": "not in plan" } ]
        }
        """;

    private const string Brief = """
        { "today": "2026-11-09",
          "profile": { "experience": "beginner", "goals": "strength", "sessionMinutes": 60.0, "includeCore": true, "trainingDays": [1,3,5],
                       "age": 34, "heightCm": 180, "bodyweightKg": 78.5, "injuries": "", "notes": "", "unknownField": 1 },
          "equipment": { "unavailable": ["cable_machine"], "occupied": ["flat_bench"] },
          "preferences": { "liked": ["machine-chest-press"], "disliked": [], "banned": ["pec-deck-fly"] },
          "limitations": [ { "id": "a", "kind": "pain", "region": "neck", "severity": 2, "exerciseId": null, "note": "stiff neck", "since": "2026-11-07" } ],
          "exerciseFeedback": [], "program": { "blockNumber": 2, "blockWeek": 3, "blockLength": 6, "phase": "accumulation", "deload": false, "variant": "B", "targetRir": 2 },
          "balance": { "muscles": [ { "muscle": "side_delts", "thisWeek": 3.0, "targetMin": 5, "targetMax": 10, "status": "under" } ], "priorities": [], "ratios": { "pushPull": 1.1, "quadHam": null }, "notes": [] },
          "exerciseHistory": [], "recentSessions": [ { "date": "2026-11-07", "dayType": "legs", "rating": 4, "effort": 7, "exercises": ["leg-press"] } ], "weekly": [] }
        """;

    private AiGateway Gateway(AiSettings? settings = null) => TestEnv.Gateway(_ai, _time, settings, _store);

    private AiFunctions Functions(AiSettings? settings = null)
    {
        var gateway = Gateway(settings);
        return new AiFunctions(
            new WorkoutAiService(Catalog, gateway, _time),
            new AdjustAiService(Catalog, gateway, _time, NullLogger<AdjustAiService>.Instance),
            new SwapAiService(Catalog, gateway, _time),
            new InsightsService(gateway, _time),
            gateway);
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

    private static List<string> Ids(JsonElement blocks, string section) =>
        blocks.EnumerateArray().Where(b => b.GetProperty("section").GetString() == section)
            .SelectMany(b => b.GetProperty("items").EnumerateArray())
            .Select(i => i.GetProperty("exerciseId").GetString()!)
            .ToList();

    [Fact]
    public async Task Workout_applies_brief_filters_validates_and_returns_contract_shape()
    {
        _ai.Returns(CannedWorkout, 2500, 700, 200);
        var draft = """{ "title": "Push B", "blocks": [ { "section": "main", "items": [ { "exerciseId": "incline-dumbbell-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "targetWeightKg": 14, "notes": "" }, { "exerciseId": "seated-dumbbell-shoulder-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "targetWeightKg": 10, "notes": "" } ] } ], "meta": { "program": "Block 2 · Week 3 · Push B", "variant": "B", "deload": false, "focus": [], "rationale": ["draft line"], "changes": [] } }""";
        var body = $$"""{ "dayType": "push", "date": "2026-11-10", "sessionMinutes": 60, "includeCore": false, "userNote": "left shoulder a bit stiff", "brief": {{Brief}}, "draft": {{draft}} }""";

        var (status, response) = await Invoke(r => Functions().Workout(r), body);

        Assert.Equal(200, status);
        var workout = response.GetProperty("workout");
        Assert.True(Guid.TryParse(workout.GetProperty("id").GetString(), out _));
        Assert.Equal("2026-11-10", workout.GetProperty("date").GetString());
        Assert.Equal("push", workout.GetProperty("dayType").GetString());
        Assert.Equal(58, workout.GetProperty("estimatedMinutes").GetInt32());
        Assert.Equal(
            ["blocks", "coachNote", "date", "dayType", "estimatedMinutes", "id", "meta", "title"],
            workout.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal));

        var blocks = workout.GetProperty("blocks");
        Assert.Equal(["warmup", "main", "cooldown"], blocks.EnumerateArray().Select(b => b.GetProperty("section").GetString())); // includeCore=false
        // dumbbell-bench-press needs the occupied flat bench, lat-pulldown is a pull exercise, the shoulder press loads the
        // painful neck (severity 2), cable-lateral-raise needs the unavailable cable machine.
        Assert.Equal(["medicine-ball-chest-pass", "machine-chest-press"], Ids(blocks, "main"));

        var meta = workout.GetProperty("meta");
        Assert.Equal("Block 2 · Week 3 · Push B", meta.GetProperty("program").GetString());
        Assert.Equal("B", meta.GetProperty("variant").GetString());
        Assert.False(meta.GetProperty("deload").GetBoolean());
        Assert.Equal(["side_delts", "biceps"], meta.GetProperty("focus").EnumerateArray().Select(f => f.GetString()));
        Assert.Equal(2, meta.GetProperty("rationale").GetArrayLength());
        var change = Assert.Single(meta.GetProperty("changes").EnumerateArray());
        Assert.Equal("incline-dumbbell-press", change.GetProperty("from").GetString());
        Assert.Equal("machine-chest-press", change.GetProperty("to").GetString());

        var usage = response.GetProperty("usage");
        Assert.Equal(1, usage.GetProperty("callsToday").GetInt32());
        Assert.Equal(3200, usage.GetProperty("tokensThisMonth").GetInt64());
        Assert.Equal("gpt-6-sol", usage.GetProperty("model").GetString());

        var (prompt, deployment) = _ai.Calls.Single();
        Assert.Equal("gpt-6-sol", deployment);
        Assert.Equal(AiEffort.Low, prompt.Effort);
        Assert.DoesNotContain("\"seated-dumbbell-shoulder-press\"", prompt.JsonSchema);
        Assert.DoesNotContain("\"cable-lateral-raise\"", prompt.JsonSchema);
        Assert.DoesNotContain("\"pec-deck-fly\"", prompt.JsonSchema); // banned
        Assert.Contains("left shoulder a bit stiff", prompt.UserPrompt);
        Assert.Contains("\"blocked\":\"moderate neck pain: loads the neck\"", prompt.UserPrompt);
        Assert.DoesNotContain("unknownField", prompt.UserPrompt);
    }

    [Fact]
    public async Task Workout_keeps_off_split_draft_items_and_allows_one_flex_exercise()
    {
        static string Main(params string[] ids) => string.Join(",", ids.Select(id =>
            $$"""{ "exerciseId": "{{id}}", "sets": 3, "repMin": 10, "repMax": 12, "durationSeconds": null, "restSeconds": 90, "targetWeightKg": null, "notes": "" }"""));
        string[] flex = [], allFlex = [];
        _ai.ReturnsFrom(prompt =>
        {
            using var doc = JsonDocument.Parse(prompt.UserPrompt);
            allFlex = [.. doc.RootElement.GetProperty("candidates").GetProperty("flex").EnumerateArray().Select(e => e.GetProperty("id").GetString()!)];
            flex = allFlex[..2];
            return $$"""{ "title": "Push", "coachNote": "", "estimatedMinutes": 55, "blocks": [ { "section": "main", "items": [ {{Main(["machine-chest-press", "hip-abduction-machine", flex[0], flex[1], "lying-leg-curl", "machine-shoulder-press"])}} ] } ], "focus": [], "rationale": [], "changes": [] }""";
        });
        var draft = $$"""{ "title": "Push A", "blocks": [ { "section": "main", "items": [ {{Main("machine-chest-press", "machine-shoulder-press", "hip-abduction-machine")}} ] } ] }""";
        var brief = """{ "balance": { "priorities": [ { "muscle": "biceps", "score": 0.9, "extraSets": 2 }, { "muscle": "traps" } ] }, "limitations": [ { "kind": "pain", "region": "neck", "severity": 3 } ] }""";

        var (_, response) = await Invoke(r => Functions().Workout(r), $$"""{ "dayType": "push", "includeCore": false, "brief": {{brief}}, "draft": {{draft}} }""");

        // hip-abduction-machine (legs) is kept because it is in the draft; only the first flex pick survives;
        // lying-leg-curl is off-split and neither in the draft nor a flex candidate.
        Assert.Equal(["machine-chest-press", "hip-abduction-machine", flex[0], "machine-shoulder-press"], Ids(response.GetProperty("workout").GetProperty("blocks"), "main"));
        var exercise = Catalog.ExercisesById[flex[0]];
        Assert.Contains("biceps", exercise.Primary);
        Assert.DoesNotContain("push", exercise.Splits);
        var schema = _ai.Prompts.Single().JsonSchema;
        Assert.Contains("\"hip-abduction-machine\"", schema);
        Assert.DoesNotContain("\"lying-leg-curl\"", schema);
        // Flex candidates train a priority muscle (traps are avoided while the neck pain is severe) and come from other splits.
        Assert.All(allFlex, id => Assert.Contains("biceps", Catalog.ExercisesById[id].Primary));
        Assert.All(allFlex, id => Assert.DoesNotContain("push", Catalog.ExercisesById[id].Splits));
    }

    [Fact]
    public async Task Off_split_draft_items_still_honour_limitations()
    {
        _ai.Returns(CannedWorkout);
        var draft = """{ "blocks": [ { "section": "main", "items": [ { "exerciseId": "hip-abduction-machine", "sets": 3, "repMin": 12, "repMax": 15, "restSeconds": 60, "notes": "" } ] } ] }""";
        var brief = """{ "limitations": [ { "kind": "pain", "region": "hip", "severity": 2 } ], "balance": { "priorities": [ { "muscle": "abductors" } ] } }""";

        await Invoke(r => Functions().Workout(r), $$"""{ "dayType": "push", "brief": {{brief}}, "draft": {{draft}} }""");

        var prompt = _ai.Prompts.Single();
        Assert.DoesNotContain("\"hip-abduction-machine\"", prompt.JsonSchema);
        Assert.Contains("\"blocked\":\"moderate hip pain: loads the hip\"", prompt.UserPrompt);
    }

    [Fact]
    public async Task Adjust_keeps_off_split_plan_items_when_removing_excluded_ones()
    {
        _ai.Returns("""{ "reply": "Noted.", "feedback": [ { "kind": "unavailable", "region": null, "severity": null, "exerciseId": "machine-chest-press", "equipmentId": null, "note": "taken", "reviewInDays": null } ], "plan": null }""");
        var plan = """{ "dayType": "push", "title": "Push A", "blocks": [ { "section": "main", "items": [ { "exerciseId": "machine-chest-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "notes": "" }, { "exerciseId": "machine-shoulder-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "notes": "" }, { "exerciseId": "dumbbell-biceps-curl", "sets": 2, "repMin": 10, "repMax": 12, "restSeconds": 60, "notes": "flex" } ] } ] }""";

        var (_, response) = await Invoke(r => Functions().Adjust(r), $$"""{ "message": "chest press is broken", "plan": {{plan}} }""");

        Assert.Equal(["machine-shoulder-press", "dumbbell-biceps-curl"], Ids(response.GetProperty("plan").GetProperty("blocks"), "main"));
    }

    [Fact]
    public async Task Workout_deload_caps_sets_at_three()
    {
        _ai.Returns(CannedWorkout);
        var brief = Brief.Replace("\"deload\": false", "\"deload\": true").Replace("\"unavailable\": [\"cable_machine\"]", "\"unavailable\": []");
        var (_, response) = await Invoke(r => Functions().Workout(r), $$"""{ "dayType": "push", "brief": {{brief}} }""");

        var workout = response.GetProperty("workout");
        Assert.True(workout.GetProperty("meta").GetProperty("deload").GetBoolean());
        Assert.Contains("Deload", workout.GetProperty("meta").GetProperty("program").GetString());
        Assert.All(workout.GetProperty("blocks").EnumerateArray().SelectMany(b => b.GetProperty("items").EnumerateArray()),
            i => Assert.InRange(i.GetProperty("sets").GetInt32(), 1, 3));
    }

    [Fact]
    public async Task Workout_without_brief_or_draft_still_works_and_uses_today()
    {
        _ai.Returns(CannedWorkout);
        var (status, response) = await Invoke(r => Functions().Workout(r), """{ "dayType": "push" }""");

        Assert.Equal(200, status);
        Assert.Equal("2026-11-09", response.GetProperty("workout").GetProperty("date").GetString());
        Assert.Null(response.GetProperty("workout").GetProperty("meta").GetProperty("program").GetString());
    }

    [Fact]
    public async Task Workout_endpoint_requires_day_type()
    {
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(Request("""{ "date": "2026-11-04" }""")));
        Assert.Equal(400, ex.StatusCode);
        Assert.Empty(_ai.Calls);
    }

    [Fact]
    public async Task Workout_endpoint_rejects_invalid_enum()
    {
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(Request("""{ "dayType": "arms" }""")));
        Assert.Equal("bad_request", ex.Error);
    }

    [Fact]
    public async Task Oversized_request_is_413()
    {
        var note = new string('x', CoachBriefRules.MaxRequestBytes);
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(Request($$"""{ "dayType": "push", "userNote": "{{note}}" }""")));
        Assert.Equal(413, ex.StatusCode);
        Assert.Equal("payload_too_large", ex.Error);
        Assert.Empty(_ai.Calls);
    }

    [Fact]
    public async Task Workout_with_unusable_ai_output_is_ai_unavailable_and_counts_the_call()
    {
        _ai.Returns("""{"title":"x","coachNote":"","estimatedMinutes":50,"blocks":[{"section":"main","items":[]}],"focus":[],"rationale":[],"changes":[]}""");
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Workout(Request("""{ "dayType": "legs" }""")));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.Equal(1, (await _store.GetAsync(TestEnv.Today, default)).CallsToday);
    }

    [Fact]
    public async Task Adjust_interprets_feedback_and_removes_broken_machine_and_painful_exercises()
    {
        const string answer = """
            { "reply": "Sorry about the knee - I swapped the leg press and leg extension.",
              "feedback": [
                { "kind": "unavailable", "region": null, "severity": null, "exerciseId": "leg-press", "equipmentId": "leg_press", "note": "Leg press is broken", "reviewInDays": null },
                { "kind": "discomfort", "region": "knee", "severity": 2, "exerciseId": null, "equipmentId": null, "note": "Left knee a bit sore", "reviewInDays": 90 },
                { "kind": "pain", "region": "elbowz", "severity": 2, "exerciseId": null, "equipmentId": null, "note": "bad region", "reviewInDays": 7 },
                { "kind": "too_hard", "region": null, "severity": 3, "exerciseId": "unknown-exercise", "equipmentId": null, "note": "", "reviewInDays": null }
              ],
              "plan": { "title": "Legs A (adjusted)", "coachNote": "Knee-friendly today.", "estimatedMinutes": 55,
                "blocks": [ { "section": "main", "items": [
                  { "exerciseId": "leg-press", "sets": 3, "repMin": 8, "repMax": 12, "durationSeconds": null, "restSeconds": 120, "targetWeightKg": 80, "notes": "" },
                  { "exerciseId": "dumbbell-romanian-deadlift", "sets": 3, "repMin": 8, "repMax": 10, "durationSeconds": null, "restSeconds": 120, "targetWeightKg": 16, "notes": "" },
                  { "exerciseId": "hip-abduction-machine", "sets": 3, "repMin": 12, "repMax": 15, "durationSeconds": null, "restSeconds": 60, "targetWeightKg": 30, "notes": "" },
                  { "exerciseId": "leg-extension", "sets": 3, "repMin": 10, "repMax": 15, "durationSeconds": null, "restSeconds": 60, "targetWeightKg": 25, "notes": "" } ] } ],
                "focus": ["hamstrings"], "rationale": ["Leg press broken -> removed", "Knee sore -> no knee-dominant work"],
                "changes": [ { "from": "leg-press", "to": "dumbbell-romanian-deadlift", "reason": "machine broken" } ] } }
            """;
        _ai.Returns(answer);
        var plan = """{ "id": "p1", "date": "2026-11-09", "dayType": "legs", "title": "Legs A", "blocks": [ { "section": "main", "items": [ { "exerciseId": "leg-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "targetWeightKg": 80, "notes": "" }, { "exerciseId": "lying-leg-curl", "sets": 3, "repMin": 10, "repMax": 12, "restSeconds": 90, "targetWeightKg": 25, "notes": "" } ] } ], "meta": { "program": "Block 1 · Week 2 · Legs A", "variant": "A" } }""";
        var body = $$"""{ "message": "the leg press is broken and my left knee feels a bit sore", "exerciseId": "leg-press", "sessionInProgress": true, "plan": {{plan}}, "brief": { "today": "2026-11-09" } }""";

        var (status, response) = await Invoke(r => Functions().Adjust(r), body);

        Assert.Equal(200, status);
        Assert.StartsWith("Sorry about the knee", response.GetProperty("reply").GetString());
        var feedback = response.GetProperty("feedback").EnumerateArray().ToList();
        Assert.Equal(2, feedback.Count);
        Assert.Equal("unavailable", feedback[0].GetProperty("kind").GetString());
        Assert.Equal("leg_press", feedback[0].GetProperty("equipmentId").GetString());
        Assert.Equal(JsonValueKind.Null, feedback[0].GetProperty("severity").ValueKind);
        Assert.Equal("discomfort", feedback[1].GetProperty("kind").GetString());
        Assert.Equal("knee", feedback[1].GetProperty("region").GetString());
        Assert.Equal(2, feedback[1].GetProperty("severity").GetInt32());
        Assert.Equal(42, feedback[1].GetProperty("reviewInDays").GetInt32());

        var adjusted = response.GetProperty("plan");
        // leg press: broken machine; leg extension: loads the sore knee (severity 2).
        Assert.Equal(["dumbbell-romanian-deadlift", "hip-abduction-machine"], Ids(adjusted.GetProperty("blocks"), "main"));
        Assert.Equal("Block 1 · Week 2 · Legs A", adjusted.GetProperty("meta").GetProperty("program").GetString());
        Assert.Single(adjusted.GetProperty("meta").GetProperty("changes").EnumerateArray());

        var prompt = _ai.Prompts.Single();
        Assert.Equal("plan_adjustment", prompt.SchemaName);
        Assert.Contains("\"exerciseName\":\"Leg Press\"", prompt.UserPrompt);
        Assert.Contains("\"anyOf\"", prompt.JsonSchema);
    }

    [Fact]
    public async Task Adjust_removes_newly_excluded_exercises_even_when_the_model_keeps_the_plan()
    {
        _ai.Returns("""{ "reply": "Noted.", "feedback": [ { "kind": "unavailable", "region": null, "severity": null, "exerciseId": "leg-press", "equipmentId": null, "note": "broken", "reviewInDays": null } ], "plan": null }""");
        var plan = """{ "dayType": "legs", "title": "Legs A", "blocks": [ { "section": "main", "items": [ { "exerciseId": "leg-press", "sets": 3, "repMin": 8, "repMax": 12, "restSeconds": 120, "notes": "" }, { "exerciseId": "lying-leg-curl", "sets": 3, "repMin": 10, "repMax": 12, "restSeconds": 90, "notes": "" }, { "exerciseId": "standing-calf-raise", "sets": 3, "repMin": 10, "repMax": 15, "restSeconds": 60, "notes": "" } ] } ] }""";

        var (_, response) = await Invoke(r => Functions().Adjust(r), $$"""{ "message": "leg press is out of order", "plan": {{plan}} }""");

        var adjusted = response.GetProperty("plan");
        Assert.Equal(["lying-leg-curl", "standing-calf-raise"], Ids(adjusted.GetProperty("blocks"), "main"));
        Assert.Contains("leg-press", adjusted.GetProperty("meta").GetProperty("rationale")[0].GetString());
    }

    [Fact]
    public async Task Adjust_without_plan_returns_feedback_only()
    {
        _ai.Returns("""{ "reply": "Glad it felt easy - I'll add weight next time.", "feedback": [ { "kind": "too_easy", "region": null, "severity": 2, "exerciseId": "machine-chest-press", "equipmentId": "leg_press", "note": "felt easy", "reviewInDays": 5 } ], "plan": null }""");

        var (status, response) = await Invoke(r => Functions().Adjust(r), """{ "message": "chest press felt way too easy", "exerciseId": "machine-chest-press", "sessionInProgress": false }""");

        Assert.Equal(200, status);
        Assert.Equal(JsonValueKind.Null, response.GetProperty("plan").ValueKind);
        var entry = Assert.Single(response.GetProperty("feedback").EnumerateArray());
        Assert.Equal("too_easy", entry.GetProperty("kind").GetString());
        Assert.Equal(JsonValueKind.Null, entry.GetProperty("severity").ValueKind);
        Assert.Equal(JsonValueKind.Null, entry.GetProperty("equipmentId").ValueKind);
        Assert.Equal(5, entry.GetProperty("reviewInDays").GetInt32());
        Assert.Contains("\"plan\":{\"type\":\"null\"}", _ai.Prompts.Single().JsonSchema);
    }

    [Fact]
    public async Task Adjust_requires_a_message_and_a_valid_plan_day()
    {
        var empty = await Assert.ThrowsAsync<ApiException>(() => Functions().Adjust(Request("""{ "message": "  " }""")));
        Assert.Equal(400, empty.StatusCode);
        var badDay = await Assert.ThrowsAsync<ApiException>(() => Functions().Adjust(Request("""{ "message": "hi", "plan": { "dayType": "arms", "blocks": [] } }""")));
        Assert.Equal(400, badDay.StatusCode);
        Assert.Empty(_ai.Calls);
    }

    [Fact]
    public async Task Swap_returns_validated_ai_suggestions_and_honours_the_brief()
    {
        _ai.Returns("""{"suggestions":[{"exerciseId":"machine-chest-press","why":"Same pressing pattern, no bench needed.","sets":3,"repMin":8,"repMax":12,"restSeconds":90},{"exerciseId":"barbell-bench-press","why":"original","sets":3,"repMin":8,"repMax":12,"restSeconds":90}]}""");
        var body = """{ "exerciseId": "barbell-bench-press", "reason": "occupied", "dayType": "push", "section": "main", "excludeExerciseIds": ["incline-dumbbell-press"], "occupiedEquipment": ["flat_bench"], "note": "", "brief": { "preferences": { "banned": ["smith-bench-press"] }, "limitations": [ { "kind": "pain", "region": "neck", "severity": 3 } ] } }""";

        var (status, response) = await Invoke(r => Functions().Swap(r), body);

        Assert.Equal(200, status);
        Assert.Equal("ai", response.GetProperty("source").GetString());
        var suggestion = Assert.Single(response.GetProperty("suggestions").EnumerateArray());
        Assert.Equal("machine-chest-press", suggestion.GetProperty("exerciseId").GetString());
        Assert.Equal(1, response.GetProperty("usage").GetProperty("callsToday").GetInt32());

        var schema = _ai.Prompts.Single().JsonSchema;
        Assert.DoesNotContain("\"dumbbell-bench-press\"", schema);          // needs the occupied flat bench
        Assert.DoesNotContain("\"smith-bench-press\"", schema);             // banned in the brief
        Assert.DoesNotContain("\"seated-dumbbell-shoulder-press\"", schema); // loads the painful neck
    }

    [Fact]
    public async Task Swap_falls_back_to_rule_ranking_when_ai_returns_nothing_valid()
    {
        _ai.Returns("""{"suggestions":[]}""");
        var (status, response) = await Invoke(r => Functions().Swap(r),
            """{ "exerciseId": "barbell-bench-press", "reason": "preference", "dayType": "push", "section": "main", "brief": { "program": { "deload": true } } }""");

        Assert.Equal(200, status);
        Assert.Equal("rules", response.GetProperty("source").GetString());
        var suggestions = response.GetProperty("suggestions").EnumerateArray().ToList();
        Assert.Equal(3, suggestions.Count);
        Assert.All(suggestions, s => Assert.NotEqual("barbell-bench-press", s.GetProperty("exerciseId").GetString()));
        Assert.All(suggestions, s => Assert.InRange(s.GetProperty("sets").GetInt32(), 1, 3));
    }

    [Fact]
    public async Task Swap_unknown_exercise_is_bad_request()
    {
        var ex = await Assert.ThrowsAsync<ApiException>(() => Functions().Swap(Request("""{ "exerciseId": "nope" }""")));
        Assert.Equal(400, ex.StatusCode);
    }

    [Fact]
    public async Task Insights_without_training_data_uses_rules_and_no_ai_call()
    {
        var (status, response) = await Invoke(r => Functions().Insights(r),
            """{ "brief": { "balance": { "priorities": [ { "muscle": "biceps" }, { "muscle": "shoulder" } ] } } }""");

        Assert.Equal(200, status);
        Assert.Equal("rules", response.GetProperty("source").GetString());
        Assert.Equal(["biceps"], response.GetProperty("focusMuscles").EnumerateArray().Select(m => m.GetString()));
        Assert.Empty(_ai.Calls);
        Assert.Equal(0, response.GetProperty("usage").GetProperty("callsToday").GetInt32());

        var (emptyStatus, _) = await Invoke(r => Functions().Insights(r), "");
        Assert.Equal(200, emptyStatus);
    }

    [Fact]
    public async Task Insights_are_generated_with_medium_effort_and_not_cached()
    {
        const string answer = """{"summary":"Good start.","highlights":["a","b","c","d","e"],"recommendations":["r"],"nextFocus":"Keep going.","focusMuscles":["rear_delts","traps","biceps","calves"]}""";
        _ai.Returns(answer).Returns(answer);
        var body = """{ "brief": { "today": "2026-11-09", "limitations": [ { "kind": "pain", "region": "neck", "severity": 3 } ], "recentSessions": [ { "date": "2026-11-07", "dayType": "legs", "exercises": ["goblet-squat"] } ] } }""";

        var first = await Invoke(r => Functions().Insights(r), body);
        Assert.Equal("ai", first.Body.GetProperty("source").GetString());
        Assert.Equal(4, first.Body.GetProperty("highlights").GetArrayLength());
        // traps are avoided while the neck pain is severe; max 3 focus muscles.
        Assert.Equal(["rear_delts", "biceps", "calves"], first.Body.GetProperty("focusMuscles").EnumerateArray().Select(m => m.GetString()));
        Assert.Equal(AiEffort.Medium, _ai.Prompts[0].Effort);
        Assert.Contains("goblet-squat", _ai.Prompts[0].UserPrompt);

        var second = await Invoke(r => Functions().Insights(r), body);
        Assert.Equal(2, _ai.Calls.Count);
        Assert.Equal(2, second.Body.GetProperty("usage").GetProperty("callsToday").GetInt32());
    }

    [Fact]
    public async Task Usage_endpoint_returns_contract_shape()
    {
        _store.Set(TestEnv.Today, 3, 30_000, 11_250);
        var (status, body) = await Invoke(r => Functions(TestEnv.Settings(daily: 10)).Usage(r), "");

        Assert.Equal(200, status);
        Assert.True(body.GetProperty("enabled").GetBoolean());
        Assert.Equal(3, body.GetProperty("callsToday").GetInt32());
        Assert.Equal(10, body.GetProperty("dailyCallLimit").GetInt32());
        Assert.Equal(41_250, body.GetProperty("tokensThisMonth").GetInt64());
        Assert.Equal(3_000_000, body.GetProperty("monthlyTokenLimit").GetInt64());
        Assert.Equal("gpt-6-sol", body.GetProperty("model").GetString());
    }

    [Fact]
    public async Task Health_returns_ok()
    {
        var req = Request(null);
        var (status, body) = await Execute(new HealthFunction().Run(req), req);
        Assert.Equal(200, status);
        Assert.Equal("ok", body.GetProperty("status").GetString());
        Assert.Equal(HealthFunction.ApiVersion, body.GetProperty("version").GetString());
    }

    [Fact]
    public void Ai_functions_do_not_initialize_the_database()
    {
        Assert.Equal([SyncFunction.Name], ApiMiddleware.DatabaseFunctions);
        var ctorTypes = typeof(AiFunctions).GetConstructors().Single().GetParameters()
            .SelectMany(p => p.ParameterType.GetConstructors().SelectMany(c => c.GetParameters()).Select(x => x.ParameterType).Append(p.ParameterType));
        Assert.DoesNotContain(typeof(WFit.Api.Data.WFitDbContext), ctorTypes);
    }
}
