using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Migrations.Operations;
using WFit.Api.Data;
using WFit.Api.Data.Migrations;

namespace WFit.Api.Tests;

public class MigrationTests
{
    private static WFitDbContext SqlServerContext() =>
        new(new DbContextOptionsBuilder<WFitDbContext>()
            .UseSqlServer("Server=(localdb)\\mssqllocaldb;Database=wfit-model-check;Trusted_Connection=True;")
            .Options);

    [Fact]
    public void Model_has_no_changes_missing_from_the_migrations()
    {
        using var db = SqlServerContext();
        Assert.False(db.Database.HasPendingModelChanges(), "Run `dotnet ef migrations add <Name>` – the model differs from the snapshot.");
        Assert.Equal("MuscleFocus", db.Database.GetMigrations().Last().Split('_', 2)[1]);
    }

    [Fact]
    public void ProfileTrainingPrefs_adds_rest_cooldown_and_bar_weights_with_defaults()
    {
        var added = new ProfileTrainingPrefs().UpOperations.OfType<AddColumnOperation>().ToDictionary(o => o.Name);

        Assert.All(added.Values, o => Assert.Equal("Profiles", o.Table));
        Assert.Equal("normal", added["RestMode"].DefaultValue);
        Assert.Equal(3, added["CooldownStretches"].DefaultValue);
        Assert.Equal("{}", added["BarWeightsJson"].DefaultValue);
    }

    [Fact]
    public void CoachV3_adds_feedback_and_meta_and_drops_the_sql_ai_tables()
    {
        var operations = new CoachV3().UpOperations;

        Assert.Contains(operations, o => o is CreateTableOperation { Name: "FeedbackEntries" });
        Assert.Contains(operations, o => o is AddColumnOperation { Table: "PlannedWorkouts", Name: "Meta", DefaultValue: "{}" });
        Assert.Contains(operations, o => o is AddColumnOperation { Table: "CatalogExercises", Name: "Stress" });
        Assert.Equal(["AiUsage", "InsightsCache"], operations.OfType<DropTableOperation>().Select(o => o.Name).Order());
    }

    [Fact]
    public void Meta_column_is_limited_to_8000_characters()
    {
        using var db = SqlServerContext();
        var meta = db.Model.FindEntityType(typeof(PlannedWorkout))!.FindProperty(nameof(PlannedWorkout.MetaJson))!;
        Assert.Equal(Len.Meta, meta.GetMaxLength());
        Assert.Equal("Meta", meta.GetColumnName());
    }
}
