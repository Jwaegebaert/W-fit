using System.Collections.Concurrent;
using System.Globalization;
using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace WFit.Api.Ai;

public sealed record AiUsageTotals(int CallsToday, long TokensThisMonth);

/// <summary>Usage to add for one logical AI call (fallback attempts included).</summary>
public sealed record AiUsageDelta(int Calls, long InputTokens, long OutputTokens, long ReasoningTokens);

/// <summary>Daily AI usage counters (calls and tokens per UTC day). Never backed by SQL so a paused database can't block the coach.</summary>
public interface IAiUsageStore
{
    Task<AiUsageTotals> GetAsync(DateOnly today, CancellationToken ct);

    /// <summary>Atomically adds <paramref name="delta"/> to the counters of <paramref name="day"/> and returns the new totals.</summary>
    Task<AiUsageTotals> AddAsync(DateOnly day, AiUsageDelta delta, CancellationToken ct);
}

public static class AiUsageStoreConfig
{
    public const string EndpointSetting = "AZURE_STORAGE_TABLE_ENDPOINT";
    public const string AccountNameSetting = "AzureWebJobsStorage__accountName";

    /// <summary><c>AZURE_STORAGE_TABLE_ENDPOINT</c>, else derived from the Functions host storage account name; null ⇒ in-memory.</summary>
    public static string? ResolveTableEndpoint(IConfiguration c)
    {
        var endpoint = c[EndpointSetting];
        if (!string.IsNullOrWhiteSpace(endpoint)) return endpoint.Trim();
        var account = c[AccountNameSetting];
        return string.IsNullOrWhiteSpace(account) ? null : $"https://{account.Trim()}.table.core.windows.net";
    }
}

/// <summary>Process-local store for tests and local development (resets on restart).</summary>
public sealed class InMemoryAiUsageStore : IAiUsageStore
{
    private readonly ConcurrentDictionary<DateOnly, AiUsageDelta> _days = new();

    public Task<AiUsageTotals> GetAsync(DateOnly today, CancellationToken ct) => Task.FromResult(Totals(today));

    public Task<AiUsageTotals> AddAsync(DateOnly day, AiUsageDelta delta, CancellationToken ct)
    {
        _days.AddOrUpdate(day, delta, (_, d) => new AiUsageDelta(
            d.Calls + delta.Calls, d.InputTokens + delta.InputTokens, d.OutputTokens + delta.OutputTokens, d.ReasoningTokens + delta.ReasoningTokens));
        return Task.FromResult(Totals(day));
    }

    /// <summary>Seeds a day directly (tests).</summary>
    public void Set(DateOnly day, int calls, long inputTokens, long outputTokens) =>
        _days[day] = new AiUsageDelta(calls, inputTokens, outputTokens, 0);

    private AiUsageTotals Totals(DateOnly today)
    {
        var calls = _days.TryGetValue(today, out var d) ? d.Calls : 0;
        var tokens = _days.Where(kv => kv.Key.Year == today.Year && kv.Key.Month == today.Month)
            .Sum(kv => kv.Value.InputTokens + kv.Value.OutputTokens);
        return new AiUsageTotals(calls, tokens);
    }
}

/// <summary>
/// Azure Table Storage store: table <c>aiusage</c>, PartitionKey <c>usage</c>, RowKey <c>yyyy-MM-dd</c> (UTC day),
/// properties Calls / InputTokens / OutputTokens / ReasoningTokens. Increments use optimistic concurrency (ETag) with retries.
/// </summary>
public sealed class TableAiUsageStore(TableClient table, ILogger<TableAiUsageStore> logger) : IAiUsageStore
{
    public const string TableName = "aiusage";
    public const string Partition = "usage";
    public const int MaxAttempts = 8;

    public static string RowKeyFor(DateOnly day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public async Task<AiUsageTotals> GetAsync(DateOnly today, CancellationToken ct)
    {
        var from = RowKeyFor(new DateOnly(today.Year, today.Month, 1));
        var to = RowKeyFor(new DateOnly(today.Year, today.Month, DateTime.DaysInMonth(today.Year, today.Month)));
        var todayKey = RowKeyFor(today);
        var filter = TableClient.CreateQueryFilter($"PartitionKey eq {Partition} and RowKey ge {from} and RowKey le {to}");

        var calls = 0;
        long tokens = 0;
        try
        {
            await foreach (var e in table.QueryAsync<TableEntity>(filter, cancellationToken: ct))
            {
                tokens += Long(e, "InputTokens") + Long(e, "OutputTokens");
                if (e.RowKey == todayKey) calls = (int)Long(e, "Calls");
            }
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return new AiUsageTotals(0, 0); // table not created yet
        }
        return new AiUsageTotals(calls, tokens);
    }

    public async Task<AiUsageTotals> AddAsync(DateOnly day, AiUsageDelta delta, CancellationToken ct)
    {
        var rowKey = RowKeyFor(day);
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                var existing = await table.GetEntityIfExistsAsync<TableEntity>(Partition, rowKey, cancellationToken: ct);
                if (!existing.HasValue || existing.Value is null)
                {
                    var entity = new TableEntity(Partition, rowKey);
                    Write(entity, delta);
                    await table.AddEntityAsync(entity, ct);
                }
                else
                {
                    var entity = existing.Value;
                    Write(entity, new AiUsageDelta(
                        (int)Long(entity, "Calls") + delta.Calls,
                        Long(entity, "InputTokens") + delta.InputTokens,
                        Long(entity, "OutputTokens") + delta.OutputTokens,
                        Long(entity, "ReasoningTokens") + delta.ReasoningTokens));
                    await table.UpdateEntityAsync(entity, entity.ETag, TableUpdateMode.Replace, ct);
                }
                return await GetAsync(day, ct);
            }
            catch (RequestFailedException ex) when (ex.Status is 409 or 412)
            {
                // Concurrent writer won the race: re-read and try again.
                await Task.Delay(Random.Shared.Next(10, 40 * attempt), ct);
            }
            catch (RequestFailedException ex) when (ex.Status == 404 && attempt < MaxAttempts)
            {
                logger.LogWarning("AI usage table '{Table}' missing; creating it.", TableName);
                await table.CreateIfNotExistsAsync(ct);
            }
        }
        throw new InvalidOperationException($"Could not record AI usage after {MaxAttempts} attempts.");
    }

    private static void Write(TableEntity entity, AiUsageDelta values)
    {
        entity["Calls"] = values.Calls;
        entity["InputTokens"] = values.InputTokens;
        entity["OutputTokens"] = values.OutputTokens;
        entity["ReasoningTokens"] = values.ReasoningTokens;
    }

    private static long Long(TableEntity entity, string key) =>
        entity.TryGetValue(key, out var value) && value is not null
            ? Convert.ToInt64(value, CultureInfo.InvariantCulture)
            : 0;
}
