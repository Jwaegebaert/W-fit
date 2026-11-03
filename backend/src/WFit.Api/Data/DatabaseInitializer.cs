using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using Microsoft.Extensions.Logging;
using WFit.Api.Domain;

namespace WFit.Api.Data;

/// <summary>
/// Applies migrations and seeds the catalog lazily on the first DB-touching request (once per process;
/// registered as a singleton). A failed attempt (e.g. serverless SQL still waking up) is retried on the next request.
/// </summary>
public sealed class DatabaseInitializer(CatalogService catalog, ILogger<DatabaseInitializer> logger)
{
    public const string CatalogVersionKey = "catalogVersion";

    private readonly SemaphoreSlim _gate = new(1, 1);
    private volatile bool _ready;

    public bool IsReady => _ready;

    public async Task EnsureInitializedAsync(WFitDbContext db, CancellationToken ct)
    {
        if (_ready) return;
        await _gate.WaitAsync(ct);
        try
        {
            if (_ready) return;
            if (db.Database.IsRelational())
                await db.Database.MigrateAsync(ct);
            else
                await db.Database.EnsureCreatedAsync(ct);

            await SeedCatalogAsync(db, catalog, ct);
            _ready = true;
            logger.LogInformation("Database ready (catalog version {Version}).", catalog.Version);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Upserts the embedded catalog into SQL when the stored catalog version differs.</summary>
    public static async Task<bool> SeedCatalogAsync(WFitDbContext db, CatalogService catalog, CancellationToken ct)
    {
        var meta = await db.AppMeta.FirstOrDefaultAsync(m => m.Key == CatalogVersionKey, ct);
        if (meta?.Value == catalog.Version) return false;

        var exercises = await db.CatalogExercises.ToDictionaryAsync(e => e.Id, ct);
        foreach (var src in catalog.Exercises)
        {
            if (!exercises.Remove(src.Id, out var row))
            {
                row = new CatalogExercise { Id = src.Id };
                db.CatalogExercises.Add(row);
            }
            row.Name = src.Name;
            row.Category = src.Category;
            row.Pattern = src.Pattern;
            row.Splits = [.. src.Splits];
            row.Primary = [.. src.Primary];
            row.Secondary = [.. src.Secondary];
            row.Equipment = [.. src.Equipment];
            row.Difficulty = src.Difficulty;
            row.Compound = src.Compound;
            row.Unilateral = src.Unilateral;
            row.Measure = src.Measure;
            row.Sets = src.Sets;
            row.RepMin = src.RepMin;
            row.RepMax = src.RepMax;
            row.DurationSeconds = src.DurationSeconds;
            row.RestSeconds = src.Rest;
            row.IncrementKg = src.IncrementKg;
            row.Badminton = src.Badminton;
            row.Instructions = [.. src.Instructions];
            row.Tip = src.Tip;
        }
        db.CatalogExercises.RemoveRange(exercises.Values);

        var equipment = await db.CatalogEquipment.ToDictionaryAsync(e => e.Id, ct);
        foreach (var src in catalog.Equipment)
        {
            if (!equipment.Remove(src.Id, out var row))
            {
                row = new CatalogEquipment { Id = src.Id };
                db.CatalogEquipment.Add(row);
            }
            row.Name = src.Name;
            row.Group = src.Group;
            row.AlwaysAvailable = src.AlwaysAvailable;
        }
        db.CatalogEquipment.RemoveRange(equipment.Values);

        if (meta is null)
            db.AppMeta.Add(new AppMeta { Key = CatalogVersionKey, Value = catalog.Version });
        else
            meta.Value = catalog.Version;

        await db.SaveChangesAsync(ct);
        return true;
    }
}

/// <summary>Used by <c>dotnet ef</c> only; runtime configuration lives in Program.cs.</summary>
public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<WFitDbContext>
{
    public WFitDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<WFitDbContext>()
            .UseSqlServer("Server=(localdb)\\mssqllocaldb;Database=wfit;Trusted_Connection=True;")
            .Options;
        return new WFitDbContext(options);
    }
}
