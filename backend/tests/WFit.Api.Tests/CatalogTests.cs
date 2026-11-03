using Microsoft.EntityFrameworkCore;
using WFit.Api.Data;
using WFit.Api.Domain;

namespace WFit.Api.Tests;

public class CatalogTests
{
    private static readonly CatalogService Catalog = TestEnv.Catalog;

    [Fact]
    public void Loads_embedded_catalog_with_at_least_100_exercises()
    {
        Assert.False(string.IsNullOrWhiteSpace(Catalog.Version));
        Assert.True(Catalog.Exercises.Count >= 100, $"Only {Catalog.Exercises.Count} exercises.");
        Assert.NotEmpty(Catalog.Equipment);
    }

    [Fact]
    public void All_exercise_equipment_ids_exist_in_catalog()
    {
        var unknown = Catalog.Exercises
            .SelectMany(e => e.Equipment.Select(eq => (e.Id, eq)))
            .Where(x => !Catalog.EquipmentById.ContainsKey(x.eq))
            .ToList();
        Assert.Empty(unknown);
    }

    [Fact]
    public void Exercise_fields_use_known_vocabulary()
    {
        Assert.Equal(Catalog.Exercises.Count, Catalog.ExercisesById.Count); // unique ids
        foreach (var e in Catalog.Exercises)
        {
            Assert.Contains(e.Category, new[] { "warmup", "strength", "power", "core", "cooldown" });
            Assert.Contains(e.Measure, new[] { "reps", "time" });
            Assert.NotEmpty(e.Splits);
            Assert.All(e.Splits, s => Assert.Contains(s, Vocab.DayTypes));
            Assert.InRange(e.Difficulty, 1, 5);
        }
    }

    [Fact]
    public void Bodyweight_is_always_available()
    {
        Assert.True(Catalog.IsAlwaysAvailable("bodyweight"));
        Assert.False(Catalog.IsAlwaysAvailable("leg_press"));
    }

    [Fact]
    public async Task Seeding_persists_catalog_and_reseeds_only_on_version_change()
    {
        await using var db = TestEnv.CreateDb();

        Assert.True(await DatabaseInitializer.SeedCatalogAsync(db, Catalog, default));
        Assert.Equal(Catalog.Exercises.Count, await db.CatalogExercises.CountAsync());
        Assert.Equal(Catalog.Equipment.Count, await db.CatalogEquipment.CountAsync());
        Assert.Equal(Catalog.Version, (await db.AppMeta.SingleAsync(m => m.Key == DatabaseInitializer.CatalogVersionKey)).Value);

        Assert.False(await DatabaseInitializer.SeedCatalogAsync(db, Catalog, default));

        var meta = await db.AppMeta.SingleAsync();
        meta.Value = "old";
        db.CatalogExercises.Add(new CatalogExercise { Id = "removed-exercise", Name = "x", Category = "core", Pattern = "x", Measure = "reps" });
        await db.SaveChangesAsync();

        Assert.True(await DatabaseInitializer.SeedCatalogAsync(db, Catalog, default));
        Assert.Null(await db.CatalogExercises.FindAsync("removed-exercise"));
        Assert.Equal(Catalog.Exercises.Count, await db.CatalogExercises.CountAsync());
    }
}
