using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using WFit.Api.Infrastructure;

namespace WFit.Api.Ai;

public sealed record AiUsageDto(bool Enabled, int CallsToday, int DailyCallLimit, long TokensThisMonth, long MonthlyTokenLimit, string Model);

/// <summary>
/// Every model call goes through here: kill switch, daily call limit and monthly token cap (Table Storage),
/// per-attempt timeout, one fallback attempt on throttling / 5xx / timeout, usage recording and per-call telemetry.
/// </summary>
public sealed class AiGateway(
    AiSettings settings,
    IAiClient client,
    IAiUsageStore store,
    TimeProvider time,
    ILogger<AiGateway> logger)
{
    private AiUsageTotals? _latest;

    private DateOnly Today => DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime);

    public AiSettings Settings => settings;

    public async Task<AiUsageDto> GetUsageAsync(CancellationToken ct)
    {
        var totals = _latest ?? await ReadTotalsAsync(ct);
        return ToDto(totals);
    }

    private AiUsageDto ToDto(AiUsageTotals totals) => new(
        settings.Enabled, totals.CallsToday, settings.DailyCallLimit, totals.TokensThisMonth, settings.MonthlyTokenLimit, settings.Deployment);

    private async Task<AiUsageTotals> ReadTotalsAsync(CancellationToken ct)
    {
        try
        {
            return _latest = await store.GetAsync(Today, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            // Fail closed: without usage numbers the cost limits can't be enforced.
            logger.LogError(ex, "AI usage store unavailable.");
            throw ApiException.AiUnavailable("AI usage limits can't be checked right now.", ex);
        }
    }

    /// <summary>Throws 503 <c>ai_disabled</c> or 429 <c>ai_limit_reached</c> when a call is not allowed.</summary>
    public async Task EnsureAllowedAsync(CancellationToken ct)
    {
        if (!settings.Enabled) throw ApiException.AiDisabled();
        var usage = await ReadTotalsAsync(ct);
        if (usage.CallsToday >= settings.DailyCallLimit)
            throw ApiException.AiLimitReached($"Daily AI call limit ({settings.DailyCallLimit}) reached.");
        if (usage.TokensThisMonth >= settings.MonthlyTokenLimit)
            throw ApiException.AiLimitReached("Monthly AI token limit reached.");
    }

    /// <summary>Checks limits, calls the model (fallback once), records usage (also on failure) and parses the JSON answer.</summary>
    public async Task<T> CompleteJsonAsync<T>(AiPrompt prompt, CancellationToken ct) where T : class
    {
        await EnsureAllowedAsync(ct);

        long input = 0, output = 0, reasoning = 0;
        var started = Stopwatch.StartNew();
        AiCompletion? completion = null;
        Exception? failure = null;
        var deployment = settings.Deployment;
        var usedFallback = false;

        try
        {
            while (true)
            {
                try
                {
                    completion = await AttemptAsync(prompt, deployment, ct);
                    break;
                }
                catch (Exception ex) when (IsTransient(ex, ct) && !usedFallback && settings.FallbackDeployment is { } fallback)
                {
                    logger.LogWarning("AI {Schema}: {Model} failed ({Reason}); falling back to {Fallback}.",
                        prompt.SchemaName, deployment, Describe(ex), fallback);
                    deployment = fallback;
                    usedFallback = true;
                }
            }
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            failure = ex;
            if (ex is AiResponseException r) (input, output, reasoning) = (r.InputTokens, r.OutputTokens, r.ReasoningTokens);
        }

        if (completion is not null) (input, output, reasoning) = (completion.InputTokens, completion.OutputTokens, completion.ReasoningTokens);
        await RecordAsync(new AiUsageDelta(1, input, output, reasoning));

        if (failure is not null || completion is null)
        {
            logger.LogWarning(failure, "AI {Schema} failed: model={Model} effort={Effort} latencyMs={LatencyMs} fallback={Fallback} in={InputTokens} out={OutputTokens} reasoning={ReasoningTokens}.",
                prompt.SchemaName, deployment, prompt.Effort, started.ElapsedMilliseconds, usedFallback, input, output, reasoning);
            throw ApiException.AiUnavailable(inner: failure);
        }

        logger.LogInformation("AI {Schema}: model={Model} effort={Effort} latencyMs={LatencyMs} fallback={Fallback} in={InputTokens} out={OutputTokens} reasoning={ReasoningTokens}.",
            prompt.SchemaName, deployment, prompt.Effort, started.ElapsedMilliseconds, usedFallback, input, output, reasoning);

        try
        {
            return JsonSerializer.Deserialize<T>(completion.Content, JsonDefaults.Options)
                   ?? throw new JsonException("Empty JSON.");
        }
        catch (JsonException ex)
        {
            logger.LogWarning(ex, "AI {Schema} returned invalid JSON.", prompt.SchemaName);
            throw ApiException.AiUnavailable();
        }
    }

    private async Task<AiCompletion> AttemptAsync(AiPrompt prompt, string deployment, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(settings.CallTimeout);
        try
        {
            return await client.CompleteAsync(prompt, deployment, timeout.Token);
        }
        catch (OperationCanceledException ex) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException($"AI call timed out after {settings.CallTimeout.TotalSeconds:0} s.", ex);
        }
    }

    private static bool IsTransient(Exception ex, CancellationToken ct) =>
        !ct.IsCancellationRequested && ex is TimeoutException or AiUpstreamException { Transient: true };

    private static string Describe(Exception ex) => ex switch
    {
        AiUpstreamException u => u.Status == 0 ? "network" : u.Status.ToString(System.Globalization.CultureInfo.InvariantCulture),
        TimeoutException => "timeout",
        _ => ex.GetType().Name,
    };

    private async Task RecordAsync(AiUsageDelta delta)
    {
        try
        {
            _latest = await store.AddAsync(Today, delta, CancellationToken.None);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to record AI usage ({Calls} call, {Input} in / {Output} out tokens).", delta.Calls, delta.InputTokens, delta.OutputTokens);
            if (_latest is { } known)
                _latest = known with { CallsToday = known.CallsToday + delta.Calls, TokensThisMonth = known.TokensThisMonth + delta.InputTokens + delta.OutputTokens };
        }
    }
}
