using System.Diagnostics.CodeAnalysis;
using System.Text.RegularExpressions;
using Azure;
using Azure.Core;
using Azure.Data.Tables;
using Azure.Data.Tables.Models;
using Microsoft.Extensions.Logging.Abstractions;
using WFit.Api.Ai;

namespace WFit.Api.Tests;

public class TableAiUsageStoreTests
{
    private static readonly DateOnly Day = new(2026, 11, 9);

    private static TableAiUsageStore Store(FakeTableClient table) => new(table, NullLogger<TableAiUsageStore>.Instance);

    [Fact]
    public async Task Records_per_day_rows_and_sums_the_current_month()
    {
        var table = new FakeTableClient();
        var store = Store(table);

        await store.AddAsync(new DateOnly(2026, 10, 31), new AiUsageDelta(4, 500_000, 100_000, 50_000), default);
        await store.AddAsync(new DateOnly(2026, 11, 1), new AiUsageDelta(1, 6_000, 1_000, 300), default);
        await store.AddAsync(Day, new AiUsageDelta(1, 5_000, 1_200, 400), default);
        var totals = await store.AddAsync(Day, new AiUsageDelta(1, 4_000, 800, 200), default);

        Assert.Equal(new AiUsageTotals(2, 18_000), totals);
        var row = table.Rows["2026-11-09"];
        Assert.Equal(TableAiUsageStore.Partition, row.PartitionKey);
        Assert.Equal(2, Convert.ToInt32(row["Calls"]));
        Assert.Equal(9_000L, row["InputTokens"]);
        Assert.Equal(600L, row["ReasoningTokens"]);
        Assert.Equal(new AiUsageTotals(0, 18_000), await store.GetAsync(Day.AddDays(1), default));
    }

    [Fact]
    public async Task Concurrent_updates_are_retried_with_optimistic_concurrency()
    {
        var table = new FakeTableClient();
        var store = Store(table);
        await store.AddAsync(Day, new AiUsageDelta(1, 100, 10, 0), default);

        // Another instance writes between our read and our update (412), then another one wins the insert race (409).
        table.InterfereOnNextUpdate = () => table.Bump("2026-11-09", calls: 1, input: 1_000);
        var totals = await store.AddAsync(Day, new AiUsageDelta(1, 100, 10, 0), default);

        Assert.Equal(1, table.PreconditionFailures);
        Assert.Equal(new AiUsageTotals(3, 1_220), totals);

        table.InterfereOnNextAdd = () => table.Bump("2026-11-10", calls: 1, input: 50);
        var next = await store.AddAsync(Day.AddDays(1), new AiUsageDelta(1, 10, 0, 0), default);
        Assert.Equal(1, table.Conflicts);
        Assert.Equal(2, next.CallsToday);
    }

    [Fact]
    public async Task Missing_table_reads_as_zero_and_is_created_on_first_write()
    {
        var table = new FakeTableClient { Exists = false };
        var store = Store(table);

        Assert.Equal(new AiUsageTotals(0, 0), await store.GetAsync(Day, default));
        var totals = await store.AddAsync(Day, new AiUsageDelta(1, 10, 5, 0), default);

        Assert.True(table.Exists);
        Assert.Equal(new AiUsageTotals(1, 15), totals);
    }

    [Fact]
    public void Row_keys_are_iso_dates() => Assert.Equal("2026-01-05", TableAiUsageStore.RowKeyFor(new DateOnly(2026, 1, 5)));

    /// <summary>In-memory TableClient with ETags, insert conflicts and a month-range query (only what the store uses).</summary>
    private sealed class FakeTableClient : TableClient
    {
        public Dictionary<string, TableEntity> Rows { get; } = new(StringComparer.Ordinal);
        public bool Exists { get; set; } = true;
        public Action? InterfereOnNextUpdate { get; set; }
        public Action? InterfereOnNextAdd { get; set; }
        public int PreconditionFailures { get; private set; }
        public int Conflicts { get; private set; }

        public void Bump(string rowKey, int calls, long input)
        {
            if (!Rows.TryGetValue(rowKey, out var row))
            {
                row = new TableEntity(TableAiUsageStore.Partition, rowKey) { ["Calls"] = 0, ["InputTokens"] = 0L, ["OutputTokens"] = 0L, ["ReasoningTokens"] = 0L };
                Rows[rowKey] = row;
            }
            row["Calls"] = Convert.ToInt32(row["Calls"]) + calls;
            row["InputTokens"] = Convert.ToInt64(row["InputTokens"]) + input;
            row.ETag = new ETag(Guid.NewGuid().ToString());
        }

        public override AsyncPageable<T> QueryAsync<T>(string filter, int? maxPerPage = null, IEnumerable<string>? select = null, CancellationToken cancellationToken = default)
        {
            EnsureExists();
            var match = Regex.Match(filter, @"RowKey ge '([^']+)' and RowKey le '([^']+)'");
            var rows = Rows.Values
                .Where(r => string.CompareOrdinal(r.RowKey, match.Groups[1].Value) >= 0 && string.CompareOrdinal(r.RowKey, match.Groups[2].Value) <= 0)
                .Select(r => (T)(object)Clone(r))
                .ToList();
            return AsyncPageable<T>.FromPages([Page<T>.FromValues(rows, null, new FakeResponse(200))]);
        }

        public override Task<NullableResponse<T>> GetEntityIfExistsAsync<T>(string partitionKey, string rowKey, IEnumerable<string>? select = null, CancellationToken cancellationToken = default)
        {
            EnsureExists();
            NullableResponse<T> response = Rows.TryGetValue(rowKey, out var row)
                ? new FakeNullableResponse<T>((T)(object)Clone(row))
                : new FakeNullableResponse<T>(null);
            return Task.FromResult(response);
        }

        public override Task<Response> AddEntityAsync<T>(T entity, CancellationToken cancellationToken = default)
        {
            EnsureExists();
            if (InterfereOnNextAdd is { } interfere)
            {
                InterfereOnNextAdd = null;
                interfere();
            }
            if (Rows.ContainsKey(entity.RowKey))
            {
                Conflicts++;
                throw new RequestFailedException(409, "EntityAlreadyExists", "EntityAlreadyExists", null);
            }
            var stored = Clone((TableEntity)(object)entity);
            stored.ETag = new ETag(Guid.NewGuid().ToString());
            Rows[entity.RowKey] = stored;
            return Task.FromResult<Response>(new FakeResponse(204));
        }

        public override Task<Response> UpdateEntityAsync<T>(T entity, ETag ifMatch, TableUpdateMode mode = TableUpdateMode.Merge, CancellationToken cancellationToken = default)
        {
            EnsureExists();
            if (InterfereOnNextUpdate is { } interfere)
            {
                InterfereOnNextUpdate = null;
                interfere();
            }
            if (!Rows.TryGetValue(entity.RowKey, out var current) || current.ETag != ifMatch)
            {
                PreconditionFailures++;
                throw new RequestFailedException(412, "UpdateConditionNotSatisfied", "UpdateConditionNotSatisfied", null);
            }
            var stored = Clone((TableEntity)(object)entity);
            stored.ETag = new ETag(Guid.NewGuid().ToString());
            Rows[entity.RowKey] = stored;
            return Task.FromResult<Response>(new FakeResponse(204));
        }

        public override Task<Response<TableItem>> CreateIfNotExistsAsync(CancellationToken cancellationToken = default)
        {
            Exists = true;
            return Task.FromResult(Response.FromValue(TableModelFactory.TableItem(TableAiUsageStore.TableName), new FakeResponse(204)));
        }

        private void EnsureExists()
        {
            if (!Exists) throw new RequestFailedException(404, "TableNotFound", "TableNotFound", null);
        }

        private static TableEntity Clone(TableEntity source)
        {
            var copy = new TableEntity(source.PartitionKey, source.RowKey) { ETag = source.ETag };
            foreach (var (key, value) in source)
            {
                if (key is not ("PartitionKey" or "RowKey" or "odata.etag" or "Timestamp")) copy[key] = value;
            }
            return copy;
        }
    }

    private sealed class FakeNullableResponse<T>(T? value) : NullableResponse<T>
    {
        public override bool HasValue => value is not null;
        public override T? Value => value;
        public override Response GetRawResponse() => new FakeResponse(HasValue ? 200 : 404);
    }

    private sealed class FakeResponse(int status) : Response
    {
        public override int Status => status;
        public override string ReasonPhrase => "";
        public override Stream? ContentStream { get; set; }
        public override string ClientRequestId { get; set; } = "";
        public override void Dispose() { }
        protected override bool TryGetHeader(string name, [NotNullWhen(true)] out string? value) { value = null; return false; }
        protected override bool TryGetHeaderValues(string name, [NotNullWhen(true)] out IEnumerable<string>? values) { values = null; return false; }
        protected override bool ContainsHeader(string name) => false;
        protected override IEnumerable<HttpHeader> EnumerateHeaders() => [];
    }
}
