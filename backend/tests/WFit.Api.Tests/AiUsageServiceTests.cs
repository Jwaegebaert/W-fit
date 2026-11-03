using WFit.Api.Ai;
using WFit.Api.Data;
using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class AiUsageServiceTests
{
    private static readonly AiPrompt Prompt = new("test", "system", "user", AiSchemas.Insights());
    private const string ValidJson = """{"summary":"s","highlights":[],"recommendations":[],"nextFocus":"n"}""";

    [Fact]
    public async Task Disabled_kill_switch_returns_ai_disabled_without_calling_model()
    {
        await using var db = TestEnv.CreateDb();
        var client = new FakeAiClient().Returns(ValidJson);
        var usage = TestEnv.Usage(db, client, new ManualTimeProvider(TestEnv.Now), TestEnv.Settings(enabled: false));

        var ex = await Assert.ThrowsAsync<ApiException>(() => usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_disabled", ex.Error);
        Assert.Empty(client.Prompts);
        Assert.False((await usage.GetUsageAsync(default)).Enabled);
    }

    [Fact]
    public async Task Daily_call_limit_is_enforced_and_resets_next_day()
    {
        await using var db = TestEnv.CreateDb();
        var time = new ManualTimeProvider(TestEnv.Now);
        var client = new FakeAiClient().Returns(ValidJson).Returns(ValidJson).Returns(ValidJson);
        var usage = TestEnv.Usage(db, client, time, TestEnv.Settings(daily: 2));

        await usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        await usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        var ex = await Assert.ThrowsAsync<ApiException>(() => usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(429, ex.StatusCode);
        Assert.Equal("ai_limit_reached", ex.Error);
        Assert.Equal(2, client.Prompts.Count);

        time.Advance(TimeSpan.FromDays(1));
        await usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        Assert.Equal(1, (await usage.GetUsageAsync(default)).CallsToday);
    }

    [Fact]
    public async Task Monthly_token_limit_is_enforced_and_counts_only_current_month()
    {
        await using var db = TestEnv.CreateDb();
        var time = new ManualTimeProvider(TestEnv.Now);
        db.AiUsage.Add(new AiUsage { Day = new DateOnly(2026, 10, 31), Calls = 5, InputTokens = 900_000, OutputTokens = 900_000 });
        db.AiUsage.Add(new AiUsage { Day = new DateOnly(2026, 11, 1), Calls = 1, InputTokens = 7_000, OutputTokens = 3_000 });
        await db.SaveChangesAsync();
        var usage = TestEnv.Usage(db, new FakeAiClient().Returns(ValidJson), time, TestEnv.Settings(monthly: 10_000));

        var current = await usage.GetUsageAsync(default);
        Assert.Equal(10_000, current.TokensThisMonth);
        Assert.Equal(0, current.CallsToday);

        var ex = await Assert.ThrowsAsync<ApiException>(() => usage.EnsureAllowedAsync(default));
        Assert.Equal(429, ex.StatusCode);
    }

    [Fact]
    public async Task Successful_call_records_calls_and_tokens()
    {
        await using var db = TestEnv.CreateDb();
        var usage = TestEnv.Usage(db, new FakeAiClient().Returns(ValidJson, 1200, 340), new ManualTimeProvider(TestEnv.Now));

        await usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);

        var dto = await usage.GetUsageAsync(default);
        Assert.Equal(1, dto.CallsToday);
        Assert.Equal(1540, dto.TokensThisMonth);
        Assert.Equal(25, dto.DailyCallLimit);
        Assert.Equal(2_000_000, dto.MonthlyTokenLimit);
    }

    [Fact]
    public async Task Upstream_failure_counts_the_call_and_maps_to_ai_unavailable()
    {
        await using var db = TestEnv.CreateDb();
        var client = new FakeAiClient().Throws(new HttpRequestException("boom"));
        var usage = TestEnv.Usage(db, client, new ManualTimeProvider(TestEnv.Now));

        var ex = await Assert.ThrowsAsync<ApiException>(() => usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.DoesNotContain("boom", ex.Message);
        Assert.Equal(1, (await usage.GetUsageAsync(default)).CallsToday);
    }

    [Fact]
    public async Task Invalid_json_from_model_is_ai_unavailable_but_tokens_are_counted()
    {
        await using var db = TestEnv.CreateDb();
        var usage = TestEnv.Usage(db, new FakeAiClient().Returns("{not json", 100, 50), new ManualTimeProvider(TestEnv.Now));

        var ex = await Assert.ThrowsAsync<ApiException>(() => usage.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.Equal(150, (await usage.GetUsageAsync(default)).TokensThisMonth);
    }
}
