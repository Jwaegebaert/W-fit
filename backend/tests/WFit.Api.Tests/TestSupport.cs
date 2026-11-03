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
    private readonly Queue<Func<AiPrompt, AiCompletion>> _responses = new();

    public List<AiPrompt> Prompts { get; } = [];

    public FakeAiClient Returns(string json, int input = 1000, int output = 300)
    {
        _responses.Enqueue(_ => new AiCompletion(json, input, output));
        return this;
    }

    public FakeAiClient Throws(Exception ex)
    {
        _responses.Enqueue(_ => throw ex);
        return this;
    }

    public Task<AiCompletion> CompleteAsync(AiPrompt prompt, CancellationToken ct)
    {
        Prompts.Add(prompt);
        if (_responses.Count == 0) throw new InvalidOperationException("No canned AI response configured.");
        return Task.FromResult(_responses.Dequeue()(prompt));
    }
}

public static class TestEnv
{
    public static readonly CatalogService Catalog = new();

    public static readonly DateTimeOffset Now = new(2026, 11, 3, 19, 0, 0, TimeSpan.Zero);

    public static AiSettings Settings(bool enabled = true, int daily = 25, long monthly = 2_000_000) =>
        new(enabled, daily, monthly, 1800, "https://example.invalid/", "gpt-4.1-mini");

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

    public static AiUsageService Usage(WFitDbContext db, IAiClient client, TimeProvider time, AiSettings? settings = null) =>
        new(db, settings ?? Settings(), client, time, NullLogger<AiUsageService>.Instance);

    public static CatalogExerciseItem Exercise(string id) => Catalog.ExercisesById[id];
}
