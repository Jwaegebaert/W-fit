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
        Assert.Equal(AiOutputValidator.MaxSetsCompound, bench.Sets); // no padding beyond the compound cap
        Assert.Equal(3, bench.RepMin);
        Assert.Equal(12 + AiOutputValidator.RepCeilingAboveCatalog, bench.RepMax); // catalog 8-12
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
    public void At_most_one_floor_exercise_per_non_main_block_when_standing_options_exist()
    {
        var output = Output(
            Block("warmup", Item("cat-cow", 1, 8, 10, null, 0), Item("inchworm", 1, 5, 6, null, 0), Item("arm-circles", 1, null, null, 45, 0)),
            Block("main", Item("dumbbell-bench-press"), Item("machine-shoulder-press")),
            Block("cooldown",
                Item("childs-pose", 1, null, null, 45, 0),
                Item("hip-90-90", 1, 8, 10, null, 0),
                Item("chest-doorway-stretch", 1, null, null, 60, 0)));

        var result = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60);

        Assert.Equal(["cat-cow", "arm-circles"], result.Blocks.Single(b => b.Section == "warmup").Items.Select(i => i.ExerciseId));
        Assert.Equal(["childs-pose", "chest-doorway-stretch"], result.Blocks.Single(b => b.Section == "cooldown").Items.Select(i => i.ExerciseId));
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

    [Fact]
    public void Focus_changes_keep_tracked_muscles_once_with_a_valid_level()
    {
        var result = AiOutputValidator.ValidateFocusChanges(
        [
            new AiFocusChangeOutput { Muscle = "side_delts", Level = "less", Light = true, Reason = "Shoulder niggles" },
            new AiFocusChangeOutput { Muscle = "side_delts", Level = "more" },
            new AiFocusChangeOutput { Muscle = "neck", Level = "less" },
            new AiFocusChangeOutput { Muscle = "glutes", Level = "lots" },
            null,
        ]);

        Assert.Equal(2, result.Count);
        Assert.Equal(new FocusChangeDto("side_delts", "less", true, "Shoulder niggles"), result[0]);
        Assert.Equal("normal", result[1].Level); // unknown level falls back to normal
    }

    [Fact]
    public void Spare_time_is_not_filled_by_inflating_reps_holds_or_sets()
    {
        var draft = AiOutputValidator.ItemsById([Block("main", Item("dumbbell-bench-press", sets: 3, repMin: 8, repMax: 12))]);
        var output = Output(
            Block("main",
                Item("dumbbell-bench-press", sets: 5, repMin: 15, repMax: 20),
                Item("machine-shoulder-press", sets: 5)),
            Block("cooldown", Item("chest-doorway-stretch", sets: 1, repMin: null, repMax: null, duration: 300, rest: 0)));

        var result = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 90, draftItems: draft);
        var all = result.Blocks.SelectMany(b => b.Items).ToDictionary(i => i.ExerciseId);

        Assert.Equal(AiOutputValidator.MaxSetsCompound, all["dumbbell-bench-press"].Sets);
        Assert.Equal(15, all["dumbbell-bench-press"].RepMax);
        Assert.Equal(AiOutputValidator.MaxSetsCompound, all["machine-shoulder-press"].Sets);
        Assert.True(all["chest-doorway-stretch"].DurationSeconds <= 60, "hold time at most twice the catalog time");
    }

    [Fact]
    public void Deload_caps_every_item_at_three_sets()
    {
        var output = Output(
            Block("warmup", Item("rowing-easy", sets: 4, repMin: null, repMax: null, duration: 300, rest: 0)),
            Block("main", Item("dumbbell-bench-press", sets: 5), Item("machine-shoulder-press", sets: 2)));

        var normal = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60);
        Assert.Equal(AiOutputValidator.MaxSetsCompound, normal.Blocks.Single(b => b.Section == "main").Items[0].Sets);
        var drafted = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60,
            draftItems: AiOutputValidator.ItemsById([Block("main", Item("dumbbell-bench-press", sets: 5))]));
        Assert.Equal(5, drafted.Blocks.Single(b => b.Section == "main").Items[0].Sets); // the draft already had 5

        var deload = AiOutputValidator.ValidateWorkout(output, PushCandidates, includeCore: true, "push", 60, deload: true);
        Assert.All(deload.Blocks.SelectMany(b => b.Items), i => Assert.InRange(i.Sets, 1, AiOutputValidator.MaxDeloadSets));
        Assert.Equal(2, deload.Blocks.Single(b => b.Section == "main").Items[1].Sets);
    }

    [Fact]
    public void Meta_is_validated_against_vocabulary_plan_and_limits()
    {
        var limits = new LimitationFilter([new Limitation("pain", "elbow", 3, null)], TestEnv.Today);
        var longLine = new string('x', 400);
        var meta = AiOutputValidator.ValidateMeta(
            focus: ["biceps", "side_delts", "chest", "chest", "neck", "rotator_cuff", "quads", "glutes", "calves"],
            rationale: ["a", " ", longLine, "b", "c", "d", "e", "f", "g"],
            changes:
            [
                new PlanChangeDto { From = "barbell-bench-press", To = "machine-chest-press", Reason = "shoulder" },
                new PlanChangeDto { From = "barbell-bench-press", To = "machine-chest-press", Reason = "dup" },
                new PlanChangeDto { From = "made-up", To = "machine-chest-press", Reason = "x" },
                new PlanChangeDto { From = "push-up", To = "push-up", Reason = "same" },
                new PlanChangeDto { From = "push-up", To = "lat-pulldown", Reason = "not in plan" },
                null!,
            ],
            planIds: ["machine-chest-press", "dumbbell-lateral-raise"],
            TestEnv.Catalog,
            program: "  Block 2 · Week 3 · Push B ",
            variant: "B",
            deload: false,
            limits);

        // biceps are avoided while the elbow pain is severe; rotator_cuff and neck are not tracked muscles; max 4.
        Assert.Equal(["side_delts", "chest", "quads", "glutes"], meta.Focus);
        Assert.Equal(AiOutputValidator.MaxRationaleLines, meta.Rationale.Count);
        Assert.All(meta.Rationale, l => Assert.True(l.Length <= AiOutputValidator.MaxRationaleLength));
        Assert.EndsWith("…", meta.Rationale[1]);
        var change = Assert.Single(meta.Changes);
        Assert.Equal(("barbell-bench-press", "machine-chest-press"), (change.From, change.To));
        Assert.Equal("Block 2 · Week 3 · Push B", meta.Program);
        Assert.Equal("B", meta.Variant);
    }

    [Fact]
    public void Feedback_is_validated_against_the_section_4_3_vocabulary()
    {
        var result = AiOutputValidator.ValidateFeedback(
        [
            new AiFeedbackOutput { Kind = "pain", Region = "neck", Severity = 5, Note = "neck hurts", ReviewInDays = 0 },
            new AiFeedbackOutput { Kind = "discomfort", Region = "knee", Severity = null, Note = "knee niggle" },
            new AiFeedbackOutput { Kind = "pain", Region = "toe", Note = "bad region, no exercise" },
            new AiFeedbackOutput { Kind = "discomfort", Region = null, ExerciseId = "leg-extension", Severity = 1, Note = "only on this one" },
            new AiFeedbackOutput { Kind = "unavailable", ExerciseId = "leg-press", EquipmentId = "leg_press", Severity = 2, Note = "broken", ReviewInDays = 3 },
            new AiFeedbackOutput { Kind = "unavailable", EquipmentId = "warp_drive", Note = "unknown equipment" },
            new AiFeedbackOutput { Kind = "too_easy", ExerciseId = null, Note = "no exercise" },
            new AiFeedbackOutput { Kind = "hungry", Note = "unknown kind" },
            new AiFeedbackOutput { Kind = "note", Note = new string('n', 2500), EquipmentId = "leg_press" },
        ], TestEnv.Catalog);

        Assert.Equal(["pain", "discomfort", "discomfort", "unavailable", "note"], result.Select(f => f.Kind));
        Assert.Equal((3, 1), (result[0].Severity!.Value, result[0].ReviewInDays!.Value));       // clamped
        Assert.Equal((1, 14), (result[1].Severity!.Value, result[1].ReviewInDays!.Value));      // defaults
        Assert.Equal("leg-extension", result[2].ExerciseId);
        Assert.Null(result[2].Region);
        Assert.Null(result[3].Severity);                                                      // not pain-like
        Assert.Equal(("leg-press", "leg_press", 3), (result[3].ExerciseId, result[3].EquipmentId, result[3].ReviewInDays!.Value));
        Assert.Null(result[4].EquipmentId);
        Assert.Null(result[4].ReviewInDays);
        Assert.Equal(AiOutputValidator.MaxFeedbackNote, result[4].Note.Length);
    }
}
