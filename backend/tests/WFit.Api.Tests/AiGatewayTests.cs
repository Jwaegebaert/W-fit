using Microsoft.Extensions.Configuration;
using WFit.Api.Ai;
using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class AiGatewayTests
{
    private static readonly AiPrompt Prompt = new("test", "system", "user", AiSchemas.Insights(), AiEffort.Medium);
    private const string ValidJson = """{"summary":"s","highlights":[],"recommendations":[],"nextFocus":"n","focusMuscles":[]}""";

    private readonly ManualTimeProvider _time = new(TestEnv.Now);
    private readonly InMemoryAiUsageStore _store = new();

    private AiGateway Gateway(FakeAiClient client, AiSettings? settings = null) => TestEnv.Gateway(client, _time, settings, _store);

    [Fact]
    public async Task Disabled_kill_switch_returns_ai_disabled_without_calling_model()
    {
        var client = new FakeAiClient().Returns(ValidJson);
        var gateway = Gateway(client, TestEnv.Settings(enabled: false));

        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_disabled", ex.Error);
        Assert.Empty(client.Calls);
        Assert.False((await gateway.GetUsageAsync(default)).Enabled);
    }

    [Fact]
    public async Task Daily_call_limit_is_enforced_and_resets_next_day()
    {
        var client = new FakeAiClient().Returns(ValidJson).Returns(ValidJson).Returns(ValidJson);
        var settings = TestEnv.Settings(daily: 2);

        await Gateway(client, settings).CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        await Gateway(client, settings).CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        var ex = await Assert.ThrowsAsync<ApiException>(() => Gateway(client, settings).CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(429, ex.StatusCode);
        Assert.Equal("ai_limit_reached", ex.Error);
        Assert.Equal(2, client.Calls.Count);

        _time.Advance(TimeSpan.FromDays(1));
        var gateway = Gateway(client, settings);
        await gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);
        Assert.Equal(1, (await gateway.GetUsageAsync(default)).CallsToday);
    }

    [Fact]
    public async Task Monthly_token_limit_is_enforced_and_counts_only_current_month()
    {
        _store.Set(new DateOnly(2026, 10, 31), 5, 900_000, 900_000);
        _store.Set(new DateOnly(2026, 11, 1), 1, 7_000, 3_000);
        var gateway = Gateway(new FakeAiClient().Returns(ValidJson), TestEnv.Settings(monthly: 10_000));

        var current = await gateway.GetUsageAsync(default);
        Assert.Equal(10_000, current.TokensThisMonth);
        Assert.Equal(0, current.CallsToday);

        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.EnsureAllowedAsync(default));
        Assert.Equal(429, ex.StatusCode);
    }

    [Fact]
    public async Task Successful_call_records_calls_and_tokens_and_uses_the_primary_deployment()
    {
        var client = new FakeAiClient().Returns(ValidJson, 1200, 340, 120);
        var gateway = Gateway(client);

        var result = await gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);

        Assert.Equal("s", result.Summary);
        Assert.Equal("gpt-6-sol", client.Calls.Single().Deployment);
        var dto = await gateway.GetUsageAsync(default);
        Assert.Equal(1, dto.CallsToday);
        Assert.Equal(1540, dto.TokensThisMonth);
        Assert.Equal(40, dto.DailyCallLimit);
        Assert.Equal(3_000_000, dto.MonthlyTokenLimit);
        Assert.Equal("gpt-6-sol", dto.Model);
    }

    [Theory]
    [InlineData(429)]
    [InlineData(500)]
    [InlineData(503)]
    [InlineData(0)]
    public async Task Throttling_or_server_errors_fall_back_once_to_the_secondary_deployment(int status)
    {
        var client = new FakeAiClient()
            .Throws(new AiUpstreamException("upstream", status, AiUpstreamException.IsTransientStatus(status)))
            .Returns(ValidJson, 1000, 200);
        var gateway = Gateway(client);

        var result = await gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);

        Assert.Equal("n", result.NextFocus);
        Assert.Equal(["gpt-6-sol", "gpt-6-luna"], client.Calls.Select(c => c.Deployment));
        var usage = await gateway.GetUsageAsync(default);
        Assert.Equal(1, usage.CallsToday); // one logical call
        Assert.Equal(1200, usage.TokensThisMonth);
    }

    [Fact]
    public async Task Timeout_falls_back_and_the_fallback_gets_its_own_timeout()
    {
        var client = new FakeAiClient().Hangs().Returns(ValidJson);
        var gateway = Gateway(client, TestEnv.Settings(timeout: TimeSpan.FromMilliseconds(150)));

        await gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default);

        Assert.Equal(["gpt-6-sol", "gpt-6-luna"], client.Calls.Select(c => c.Deployment));
    }

    [Fact]
    public async Task Fallback_is_used_only_once()
    {
        var client = new FakeAiClient()
            .Throws(new AiUpstreamException("throttled", 429, true))
            .Throws(new AiUpstreamException("throttled", 429, true))
            .Returns(ValidJson);
        var gateway = Gateway(client);

        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.Equal(2, client.Calls.Count);
        Assert.Equal(1, (await gateway.GetUsageAsync(default)).CallsToday);
    }

    [Fact]
    public async Task Non_transient_errors_and_disabled_fallback_do_not_retry()
    {
        var badRequest = new FakeAiClient().Throws(new AiUpstreamException("bad schema", 400, false)).Returns(ValidJson);
        await Assert.ThrowsAsync<ApiException>(() => Gateway(badRequest).CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Single(badRequest.Calls);

        var noFallback = new FakeAiClient().Throws(new AiUpstreamException("throttled", 429, true)).Returns(ValidJson);
        await Assert.ThrowsAsync<ApiException>(() => Gateway(noFallback, TestEnv.Settings(fallback: null)).CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Single(noFallback.Calls);
    }

    [Fact]
    public async Task Upstream_failure_counts_the_call_and_maps_to_ai_unavailable()
    {
        var client = new FakeAiClient().Throws(new HttpRequestException("boom"));
        var gateway = Gateway(client);

        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.DoesNotContain("boom", ex.Message);
        Assert.Equal(1, (await gateway.GetUsageAsync(default)).CallsToday);
    }

    [Fact]
    public async Task Unusable_answer_counts_its_tokens()
    {
        var client = new FakeAiClient().Throws(new AiResponseException("length", 5000, 8000, 7000));
        var gateway = Gateway(client);

        await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Single(client.Calls); // not transient: no fallback
        Assert.Equal(13_000, (await gateway.GetUsageAsync(default)).TokensThisMonth);
    }

    [Fact]
    public async Task Invalid_json_from_model_is_ai_unavailable_but_tokens_are_counted()
    {
        var gateway = Gateway(new FakeAiClient().Returns("{not json", 100, 50));

        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal("ai_unavailable", ex.Error);
        Assert.Equal(150, (await gateway.GetUsageAsync(default)).TokensThisMonth);
    }

    [Fact]
    public async Task Usage_store_outage_fails_closed()
    {
        var gateway = TestEnv.Gateway(new FakeAiClient().Returns(ValidJson), _time, store: new BrokenStore());
        var ex = await Assert.ThrowsAsync<ApiException>(() => gateway.CompleteJsonAsync<AiInsightsOutput>(Prompt, default));
        Assert.Equal("ai_unavailable", ex.Error);
    }

    [Fact]
    public void Settings_defaults_and_overrides()
    {
        var defaults = AiSettings.FromConfiguration(new ConfigurationBuilder().Build());
        Assert.Equal("gpt-6-sol", defaults.Deployment);
        Assert.Equal("gpt-6-luna", defaults.FallbackDeployment);
        Assert.Equal(40, defaults.DailyCallLimit);
        Assert.Equal(3_000_000, defaults.MonthlyTokenLimit);
        Assert.Equal(8000, defaults.MaxOutputTokens);
        Assert.Equal(TimeSpan.FromSeconds(60), defaults.CallTimeout);
        Assert.True(defaults.Enabled);
        Assert.Null(defaults.Endpoint);

        var custom = AiSettings.FromConfiguration(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["AZURE_OPENAI_DEPLOYMENT"] = "my-sol",
            ["AZURE_OPENAI_FALLBACK_DEPLOYMENT"] = "none",
            ["AI_DAILY_CALL_LIMIT"] = "5",
            ["AI_CALL_TIMEOUT_SECONDS"] = "90",
            ["AI_ENABLED"] = "false",
            ["AZURE_OPENAI_ENDPOINT"] = "https://oai.example/",
        }).Build());
        Assert.Equal("my-sol", custom.Deployment);
        Assert.Null(custom.FallbackDeployment);
        Assert.Equal(5, custom.DailyCallLimit);
        Assert.Equal(TimeSpan.FromSeconds(90), custom.CallTimeout);
        Assert.False(custom.Enabled);
    }

    [Theory]
    [InlineData("https://my-openai.openai.azure.com/", "https://my-openai.openai.azure.com/openai/v1/")]
    [InlineData("https://my-openai.openai.azure.com", "https://my-openai.openai.azure.com/openai/v1/")]
    [InlineData("https://my-openai.openai.azure.com/openai/v1", "https://my-openai.openai.azure.com/openai/v1/")]
    public void Endpoint_is_normalised_to_the_v1_api(string endpoint, string expected) =>
        Assert.Equal(expected, AzureOpenAiClient.V1Endpoint(endpoint).ToString());

    [Fact]
    public void Table_endpoint_comes_from_setting_or_host_storage_account()
    {
        IConfiguration Config(params (string Key, string Value)[] values) =>
            new ConfigurationBuilder().AddInMemoryCollection(values.Select(v => new KeyValuePair<string, string?>(v.Key, v.Value))).Build();

        Assert.Equal("https://x.table.core.windows.net/", AiUsageStoreConfig.ResolveTableEndpoint(Config(("AZURE_STORAGE_TABLE_ENDPOINT", "https://x.table.core.windows.net/"))));
        Assert.Equal("https://mystorage.table.core.windows.net", AiUsageStoreConfig.ResolveTableEndpoint(Config(("AzureWebJobsStorage__accountName", "mystorage"))));
        Assert.Null(AiUsageStoreConfig.ResolveTableEndpoint(Config()));
    }

    private sealed class BrokenStore : IAiUsageStore
    {
        public Task<AiUsageTotals> GetAsync(DateOnly today, CancellationToken ct) => throw new InvalidOperationException("down");
        public Task<AiUsageTotals> AddAsync(DateOnly day, AiUsageDelta delta, CancellationToken ct) => throw new InvalidOperationException("down");
    }
}
