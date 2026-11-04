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
    public void Every_exercise_has_two_to_three_mistakes()
    {
        Assert.Equal("2", Catalog.Version);
        Assert.All(Catalog.Exercises, e =>
        {
            Assert.NotNull(e.Mistakes);
            Assert.InRange(e.Mistakes!.Count, 2, 3);
            Assert.All(e.Mistakes, m => Assert.False(string.IsNullOrWhiteSpace(m), e.Id));
        });
    }

    [Fact]
    public void Every_equipment_has_a_description()
    {
        Assert.All(Catalog.Equipment, e => Assert.False(string.IsNullOrWhiteSpace(e.Description), e.Id));
        Assert.Equal("cardio", Catalog.EquipmentById["elliptical"].Group);
        Assert.Contains(Catalog.Exercises, e => e.Id == "elliptical-easy" && e.Equipment.SequenceEqual(["elliptical"]));
    }

    [Fact]
    public void Floor_exercises_are_marked_with_mat()
    {
        Assert.True(TestEnv.Exercise("plank").IsFloor);
        Assert.True(TestEnv.Exercise("childs-pose").IsFloor);
        Assert.False(TestEnv.Exercise("standing-quad-stretch").IsFloor);
        Assert.False(TestEnv.Exercise("pallof-press-cable").IsFloor);

        // Every day type can fill warm-up, core and a 3-item cooldown without floor work.
        var ctx = SelectionContext.Create(Catalog, "beginner");
        foreach (var day in Vocab.DayTypes)
        {
            var candidates = ExerciseSelector.CandidatesByCategory(Catalog.Exercises, ctx, day);
            Assert.True(candidates["cooldown"].Count(e => !e.IsFloor) >= 3, day);
            Assert.True(candidates["core"].Count(e => !e.IsFloor) >= 2, day);
            Assert.True(candidates["warmup"].Count(e => !e.IsFloor && e.Pattern != "cardio") >= 3, day);
        }
    }

    [Fact]
    public void Upper_power_work_exists_without_a_medicine_ball()
    {
        foreach (var day in new[] { "push", "pull" })
        {
            Assert.Contains(Catalog.Exercises, e =>
                e.Pattern == "plyo_upper" && e.Splits.Contains(day) && !e.Equipment.Contains("medicine_ball"));
        }
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
