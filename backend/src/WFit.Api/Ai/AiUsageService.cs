using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using WFit.Api.Data;
using WFit.Api.Infrastructure;

namespace WFit.Api.Ai;

/// <summary>Cost guard: kill switch, daily call limit and monthly token cap around every model call.</summary>
public sealed class AiUsageService(
    WFitDbContext db,
    AiSettings settings,
    IAiClient client,
    TimeProvider time,
    ILogger<AiUsageService> logger)
{
    private DateOnly Today => DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime);

    public async Task<AiUsageDto> GetUsageAsync(CancellationToken ct)
    {
        var today = Today;
        var monthStart = new DateOnly(today.Year, today.Month, 1);
        var rows = await db.AiUsage.AsNoTracking().Where(u => u.Day >= monthStart).ToListAsync(ct);
        var callsToday = rows.Where(r => r.Day == today).Sum(r => r.Calls);
        var tokens = rows.Sum(r => r.InputTokens + r.OutputTokens);
        return new AiUsageDto(settings.Enabled, callsToday, settings.DailyCallLimit, tokens, settings.MonthlyTokenLimit);
    }

    /// <summary>Throws 503 <c>ai_disabled</c> or 429 <c>ai_limit_reached</c> when a call is not allowed.</summary>
    public async Task EnsureAllowedAsync(CancellationToken ct)
    {
        if (!settings.Enabled) throw ApiException.AiDisabled();
        var usage = await GetUsageAsync(ct);
        if (usage.CallsToday >= settings.DailyCallLimit)
            throw ApiException.AiLimitReached($"Daily AI call limit ({settings.DailyCallLimit}) reached.");
        if (usage.TokensThisMonth >= settings.MonthlyTokenLimit)
            throw ApiException.AiLimitReached("Monthly AI token limit reached.");
    }

    public async Task RecordAsync(int inputTokens, int outputTokens, CancellationToken ct)
    {
        var today = Today;
        var row = await db.AiUsage.FirstOrDefaultAsync(u => u.Day == today, ct);
        if (row is null)
        {
            row = new AiUsage { Day = today };
            db.AiUsage.Add(row);
        }
        row.Calls += 1;
        row.InputTokens += Math.Max(0, inputTokens);
        row.OutputTokens += Math.Max(0, outputTokens);
        await db.SaveChangesAsync(ct);
    }

    /// <summary>Checks limits, calls the model (45 s timeout), records usage (also on failure) and parses the JSON answer.</summary>
    public async Task<T> CompleteJsonAsync<T>(AiPrompt prompt, CancellationToken ct) where T : class
    {
        await EnsureAllowedAsync(ct);

        AiCompletion completion;
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            timeout.CancelAfter(AiSettings.CallTimeout);
            try
            {
                completion = await client.CompleteAsync(prompt, timeout.Token);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                var (input, output) = ex is AiResponseException r ? (r.InputTokens, r.OutputTokens) : (0, 0);
                await RecordAsync(input, output, CancellationToken.None);
                logger.LogWarning(ex, "AI call {Schema} failed.", prompt.SchemaName);
                throw ApiException.AiUnavailable();
            }
        }

        await RecordAsync(completion.InputTokens, completion.OutputTokens, CancellationToken.None);
        logger.LogInformation("AI call {Schema}: {Input} in / {Output} out tokens.", prompt.SchemaName, completion.InputTokens, completion.OutputTokens);

        try
        {
            return JsonSerializer.Deserialize<T>(completion.Content, JsonDefaults.Options)
                   ?? throw new JsonException("Empty JSON.");
        }
        catch (JsonException ex)
        {
            logger.LogWarning(ex, "AI call {Schema} returned invalid JSON.", prompt.SchemaName);
            throw ApiException.AiUnavailable();
        }
    }
}
