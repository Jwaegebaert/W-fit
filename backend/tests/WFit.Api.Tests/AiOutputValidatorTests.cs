using WFit.Api.Ai;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Tests;

public class AiOutputValidatorTests
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyList<CatalogExerciseItem>> PushCandidates =
        ExerciseSelector.CandidatesByCategory(
            TestEnv.Catalog.Exercises, SelectionContext.Create(TestEnv.Catalog, "beginner"), "push");

    private static WorkoutItemDto Item(string id, int sets = 3, int? repMin = 8, int? repMax = 12, int? duration = null, int rest = 90, double? kg = null) =>
        new() { ExerciseId = id, Sets = sets, RepMin = repMin, RepMax = repMax, DurationSeconds = duration, RestSeconds = rest, TargetWeightKg = kg, Notes = "cue" };

    private static AiWorkoutOutput Output(params WorkoutBlockDto[] blocks) =>
        new() { Title = "Push day", CoachNote = "Nice.", EstimatedMinutes = 58, Blocks = [.. blocks] };

    private static WorkoutBlockDto Block(string section, params WorkoutItemDto[] items) => new() { Section = section, Items = [.. items] };

    [Fact]
    public void Unknown_and_wrong_section_ids_are_dropped_and_duplicates_removed()
    {
        var output = Output(
            Block("warmup", Item("rowing-easy", 1, null, null, 300, 0), Item("dumbbell-bench-press")),
            Block("main",
                Item("dumbbell-bench-press"),
                Item("not-a-real-exercise"),
                Item("goblet-squat"),            // legs only, not a push candidate
                Item("plank"),                   // core exercise in main block
                Item("dumbbell-bench-press"),    // duplicate
                Item("seated-dumbbell-shoulder-press")));

        var result = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60);

        var warmup = result.Blocks.Single(b => b.Section == "warmup");
        Assert.Equal(["rowing-easy"], warmup.Items.Select(i => i.ExerciseId));
        var main = result.Blocks.Single(b => b.Section == "main");
        Assert.Equal(["dumbbell-bench-press", "seated-dumbbell-shoulder-press"], main.Items.Select(i => i.ExerciseId));
    }

    [Fact]
    public void Values_are_clamped_to_safe_bounds()
    {
        var output = Output(
            Block("warmup", Item("rowing-easy", sets: 9, repMin: 10, repMax: 10, duration: 5000, rest: 999)),
            Block("main",
                Item("dumbbell-bench-press", sets: 12, repMin: 30, repMax: 1, rest: 5, kg: 1000),
                Item("machine-chest-press", sets: 0, repMin: null, repMax: null, rest: 900, kg: -4)),
            Block("cooldown", Item("chest-doorway-stretch", sets: 1, repMin: null, repMax: null, duration: 2, rest: 0)));

        var result = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60);
        var all = result.Blocks.SelectMany(b => b.Items).ToDictionary(i => i.ExerciseId);

        var row = all["rowing-easy"];
        Assert.Equal(5, row.Sets);
        Assert.Null(row.RepMin);
        Assert.Equal(600, row.DurationSeconds);
        Assert.Equal(180, row.RestSeconds);

        var bench = all["dumbbell-bench-press"];
        Assert.Equal(5, bench.Sets);
        Assert.Equal(3, bench.RepMin);
        Assert.Equal(20, bench.RepMax);
        Assert.True(bench.RepMin <= bench.RepMax);
        Assert.Equal(30, bench.RestSeconds);
        Assert.Equal(300, bench.TargetWeightKg);
        Assert.Null(bench.DurationSeconds);

        var machine = all["machine-chest-press"];
        Assert.Equal(1, machine.Sets);
        Assert.Equal(TestEnv.Exercise("machine-chest-press").RepMin, machine.RepMin);
        Assert.Equal(240, machine.RestSeconds);
        Assert.Null(machine.TargetWeightKg);

        Assert.Equal(10, all["chest-doorway-stretch"].DurationSeconds);
    }

    [Fact]
    public void At_most_seven_main_items()
    {
        var mainIds = PushCandidates["strength"].Select(e => e.Id).Take(10).ToArray();
        Assert.True(mainIds.Length >= 8);
        var output = Output(Block("main", mainIds.Select(id => Item(id)).ToArray()));

        var result = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: false, "push", 60);
        Assert.Equal(7, result.Blocks.Single(b => b.Section == "main").Items.Count);
    }

    [Fact]
    public void Fewer_than_two_main_items_is_ai_unavailable()
    {
        var output = Output(Block("main", Item("dumbbell-bench-press"), Item("unknown")));
        var ex = Assert.Throws<ApiException>(() => AiOutputValidator.ValidateWorkout(output, PushCandidates, true, "push", 60));
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal("ai_unavailable", ex.Error);
    }

    [Fact]
    public void Core_block_is_omitted_when_not_requested_and_sections_are_ordered()
    {
        var output = Output(
            Block("cooldown", Item("childs-pose", 1, null, null, 60, 0)),
            Block("core", Item("plank", 2, null, null, 30, 30)),
            Block("main", Item("dumbbell-bench-press"), Item("machine-shoulder-press")),
            Block("warmup", Item("arm-circles", 1, null, null, 60, 0)));

        var without = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: false, "push", 60);
        Assert.Equal(["warmup", "main", "cooldown"], without.Blocks.Select(b => b.Section));

        var with = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60);
        Assert.Equal(["warmup", "main", "core", "cooldown"], with.Blocks.Select(b => b.Section));
    }

    [Fact]
    public void Swap_validation_keeps_only_candidates_and_clamps()
    {
        var candidates = new[] { TestEnv.Exercise("machine-chest-press"), TestEnv.Exercise("push-up") };
        var output = new AiSwapOutput
        {
            Suggestions =
            [
                new("barbell-row", "no", 3, 8, 12, 90),
                new("machine-chest-press", "Same pattern.", 9, 25, 2, 10),
                new("machine-chest-press", "dup", 3, 8, 12, 90),
                new("push-up", "", 3, 8, 12, 600),
            ],
        };

        var result = AiOutputValidator.ValidateSwap(output, candidates, WorkoutSection.Main);

        Assert.Equal(["machine-chest-press", "push-up"], result.Select(s => s.ExerciseId));
        Assert.Equal(5, result[0].Sets);
        Assert.Equal(3, result[0].RepMin);
        Assert.Equal(20, result[0].RepMax);
        Assert.Equal(30, result[0].RestSeconds);
        Assert.Equal(240, result[1].RestSeconds);
        Assert.False(string.IsNullOrWhiteSpace(result[1].Why));
    }
}
