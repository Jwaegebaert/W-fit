using System.Text.Json.Nodes;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using WFit.Api.Ai;
using WFit.Api.Data;
using WFit.Api.Domain;

namespace WFit.Api.Tests;

public sealed class ManualTimeProvider(DateTimeOffset start) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = start;

    public override DateTimeOffset GetUtcNow() => Now;

    public void Advance(TimeSpan by) => Now = Now.Add(by);
}

public sealed class FakeAiClient : IAiClient
{
    private readonly Queue<Func<AiPrompt, string, CancellationToken, Task<AiCompletion>>> _responses = new();

    public List<(AiPrompt Prompt, string Deployment)> Calls { get; } = [];

    public List<AiPrompt> Prompts => Calls.Select(c => c.Prompt).ToList();

    public FakeAiClient Returns(string json, int input = 1000, int output = 300, int reasoning = 100)
    {
        _responses.Enqueue((_, deployment, _) => Task.FromResult(new AiCompletion(json, input, output, reasoning, deployment, 5)));
        return this;
    }

    /// <summary>Answer computed from the prompt (e.g. to pick ids from the offered candidates).</summary>
    public FakeAiClient ReturnsFrom(Func<AiPrompt, string> answer)
    {
        _responses.Enqueue((prompt, deployment, _) => Task.FromResult(new AiCompletion(answer(prompt), 1000, 300, 100, deployment, 5)));
        return this;
    }

    public FakeAiClient Throws(Exception ex)
    {
        _responses.Enqueue((_, _, _) => Task.FromException<AiCompletion>(ex));
        return this;
    }

    /// <summary>Never answers; only the caller's cancellation (timeout) ends the call.</summary>
    public FakeAiClient Hangs()
    {
        _responses.Enqueue(async (_, _, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            throw new InvalidOperationException("unreachable");
        });
        return this;
    }

    public Task<AiCompletion> CompleteAsync(AiPrompt prompt, string deployment, CancellationToken ct)
    {
        Calls.Add((prompt, deployment));
        if (_responses.Count == 0) throw new InvalidOperationException("No canned AI response configured.");
        return _responses.Dequeue()(prompt, deployment, ct);
    }
}

public static class TestEnv
{
    public static readonly CatalogService Catalog = new();

    /// <summary>
    /// The embedded catalog with fixed <c>stress</c> tags for the exercises the safety tests rely on, so the tests are
    /// independent of the catalog's own tagging.
    /// </summary>
    public static readonly CatalogService StressCatalog = WithStress(new Dictionary<string, string[]>
    {
        ["seated-dumbbell-shoulder-press"] = ["neck", "shoulder"],
        ["machine-shoulder-press"] = ["shoulder"],
        ["machine-chest-press"] = ["shoulder"],
        ["dumbbell-bench-press"] = ["shoulder"],
        ["incline-dumbbell-press"] = ["shoulder"],
        ["barbell-bench-press"] = ["shoulder", "wrist"],
        ["dumbbell-lateral-raise"] = [],
        ["cable-lateral-raise"] = [],
        ["pec-deck-fly"] = ["shoulder"],
        ["cable-triceps-pushdown"] = ["elbow"],
        ["barbell-back-squat"] = ["neck", "lower_back", "hip", "knee"],
        ["leg-press"] = ["knee", "hip"],
        ["leg-extension"] = ["knee"],
        ["goblet-squat"] = ["knee", "hip"],
        ["lying-leg-curl"] = ["knee"],
        ["dumbbell-romanian-deadlift"] = ["lower_back", "hip"],
        ["hip-abduction-machine"] = ["hip"],
        ["standing-calf-raise"] = ["ankle"],
    });

    public static readonly DateTimeOffset Now = new(2026, 11, 9, 8, 0, 0, TimeSpan.Zero);
    public static readonly DateOnly Today = DateOnly.FromDateTime(Now.UtcDateTime);

    public static AiSettings Settings(bool enabled = true, int daily = 40, long monthly = 3_000_000, string? fallback = "gpt-6-luna", TimeSpan? timeout = null) =>
        new()
        {
            Enabled = enabled,
            DailyCallLimit = daily,
            MonthlyTokenLimit = monthly,
            MaxOutputTokens = 8000,
            Endpoint = "https://example.invalid/",
            Deployment = "gpt-6-sol",
            FallbackDeployment = fallback,
            CallTimeout = timeout ?? TimeSpan.FromSeconds(60),
        };

    public static AiGateway Gateway(IAiClient client, TimeProvider time, AiSettings? settings = null, IAiUsageStore? store = null) =>
        new(settings ?? Settings(), client, store ?? new InMemoryAiUsageStore(), time, NullLogger<AiGateway>.Instance);

    public static WFitDbContext CreateDb(string? name = null)
    {
        var options = new DbContextOptionsBuilder<WFitDbContext>()
            .UseInMemoryDatabase(name ?? Guid.NewGuid().ToString())
            .ConfigureWarnings(w => w.Ignore(InMemoryEventId.TransactionIgnoredWarning))
            .Options;
        var db = new WFitDbContext(options);
        db.Database.EnsureCreated();
        return db;
    }

    public static CatalogExerciseItem Exercise(string id) => Catalog.ExercisesById[id];

    public static CatalogService WithStress(IReadOnlyDictionary<string, string[]> stress)
    {
        var root = JsonNode.Parse(CatalogService.EmbeddedJson())!.AsObject();
        foreach (var exercise in root["exercises"]!.AsArray())
        {
            var id = exercise!["id"]!.GetValue<string>();
            if (stress.TryGetValue(id, out var regions))
                exercise["stress"] = new JsonArray([.. regions.Select(r => (JsonNode)JsonValue.Create(r))]);
        }
        return new CatalogService(root.ToJsonString());
    }
}
