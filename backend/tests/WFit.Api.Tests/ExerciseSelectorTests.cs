using WFit.Api.Domain;

namespace WFit.Api.Tests;

public class ExerciseSelectorTests
{
    private static readonly CatalogService Catalog = TestEnv.Catalog;

    private static SelectionContext Ctx(
        string experience = "beginner",
        Dictionary<string, bool>? equipment = null,
        string[]? occupied = null,
        Dictionary<string, string>? prefs = null) =>
        SelectionContext.Create(Catalog, experience, equipment, occupied, prefs);

    [Fact]
    public void Missing_equipment_status_means_available()
    {
        Assert.True(ExerciseSelector.IsEligible(TestEnv.Exercise("dumbbell-bench-press"), Ctx()));
    }

    [Fact]
    public void Unavailable_equipment_excludes_exercise()
    {
        var ctx = Ctx(equipment: new() { ["flat_bench"] = false });
        Assert.False(ExerciseSelector.IsEligible(TestEnv.Exercise("dumbbell-bench-press"), ctx));
        Assert.True(ExerciseSelector.IsEligible(TestEnv.Exercise("machine-chest-press"), ctx));
    }

    [Fact]
    public void Occupied_equipment_excludes_exercise()
    {
        var ctx = Ctx(occupied: ["chest_press_machine"]);
        Assert.False(ExerciseSelector.IsEligible(TestEnv.Exercise("machine-chest-press"), ctx));
    }

    [Fact]
    public void Bodyweight_is_always_available_even_if_marked_otherwise()
    {
        var ctx = Ctx(equipment: new() { ["bodyweight"] = false }, occupied: ["bodyweight"]);
        Assert.True(ExerciseSelector.IsEquipmentUsable("bodyweight", ctx));
        Assert.True(ExerciseSelector.IsEligible(TestEnv.Exercise("push-up"), ctx));
    }

    [Fact]
    public void Banned_exercise_is_excluded_but_disliked_is_not()
    {
        var ctx = Ctx(prefs: new() { ["push-up"] = "banned", ["dumbbell-bench-press"] = "disliked" });
        Assert.False(ExerciseSelector.IsEligible(TestEnv.Exercise("push-up"), ctx));
        Assert.True(ExerciseSelector.IsEligible(TestEnv.Exercise("dumbbell-bench-press"), ctx));
    }

    [Theory]
    [InlineData("beginner", 2)]
    [InlineData("novice", 2)]
    [InlineData("intermediate", 3)]
    public void Difficulty_cap_depends_on_experience(string experience, int max)
    {
        Assert.Equal(max, ExerciseSelector.MaxDifficulty(experience));
    }

    [Fact]
    public void Difficulty_above_level_is_excluded()
    {
        var hard = new CatalogExerciseItem("hard", "Hard", "strength", ["push"], ["chest"], [], "horizontal_push", [], 3,
            true, false, "reps", 3, 6, 10, null, 90, 2.5, null, [], null);
        Assert.False(ExerciseSelector.IsEligible(hard, Ctx("beginner")));
        Assert.True(ExerciseSelector.IsEligible(hard, Ctx("intermediate")));
    }

    [Fact]
    public void Candidates_are_filtered_by_split_and_grouped_by_category()
    {
        var candidates = ExerciseSelector.CandidatesByCategory(Catalog.Exercises, Ctx(), "push");

        Assert.All(candidates.SelectMany(c => c.Value), e => Assert.Contains("push", e.Splits));
        Assert.All(candidates, kv => Assert.All(kv.Value, e => Assert.Equal(kv.Key, e.Category)));
        Assert.DoesNotContain(candidates["strength"], e => e.Id == "goblet-squat");
        Assert.Contains(candidates["strength"], e => e.Id == "dumbbell-bench-press");
        Assert.True(candidates.ContainsKey("warmup"));
        Assert.True(candidates.ContainsKey("cooldown"));
    }
}

public class SwapRankingTests
{
    private static SelectionContext Ctx(Dictionary<string, string>? prefs = null, string[]? occupied = null) =>
        SelectionContext.Create(TestEnv.Catalog, "beginner", null, occupied, prefs);

    [Fact]
    public void Score_rewards_pattern_and_muscle_overlap()
    {
        var original = TestEnv.Exercise("barbell-bench-press");
        var ctx = Ctx();
        var samePattern = ExerciseSelector.SwapScore(original, TestEnv.Exercise("machine-chest-press"), ctx, "push");
        var other = ExerciseSelector.SwapScore(original, TestEnv.Exercise("dumbbell-lateral-raise"), ctx, "push");

        // pattern +3, chest primary +2, split +1 (+ secondary overlap if any)
        Assert.True(samePattern >= 6, $"score {samePattern}");
        Assert.True(samePattern > other);
    }

    [Fact]
    public void Liked_and_disliked_adjust_score()
    {
        var original = TestEnv.Exercise("barbell-bench-press");
        var candidate = TestEnv.Exercise("machine-chest-press");
        var neutral = ExerciseSelector.SwapScore(original, candidate, Ctx(), "push");
        var liked = ExerciseSelector.SwapScore(original, candidate, Ctx(new() { ["machine-chest-press"] = "liked" }), "push");
        var disliked = ExerciseSelector.SwapScore(original, candidate, Ctx(new() { ["machine-chest-press"] = "disliked" }), "push");

        Assert.Equal(neutral + 1, liked);
        Assert.Equal(neutral - 2, disliked);
    }

    [Fact]
    public void Ranking_keeps_category_excludes_original_excluded_and_ineligible()
    {
        var original = TestEnv.Exercise("barbell-bench-press");
        var ranked = ExerciseSelector.RankSwapCandidates(
            original, TestEnv.Catalog.Exercises, Ctx(occupied: ["chest_press_machine"]), "push", ["dumbbell-bench-press"]);

        Assert.NotEmpty(ranked);
        Assert.DoesNotContain(ranked, e => e.Id is "barbell-bench-press" or "dumbbell-bench-press" or "machine-chest-press");
        Assert.All(ranked, e => Assert.Contains(e.Category, new[] { "strength", "power" }));
        Assert.Equal("horizontal_push", ranked[0].Pattern);
    }

    [Fact]
    public void Strength_and_power_are_interchangeable()
    {
        var original = TestEnv.Exercise("medicine-ball-chest-pass");
        var ranked = ExerciseSelector.RankSwapCandidates(original, TestEnv.Catalog.Exercises, Ctx(), "push");
        Assert.Contains(ranked, e => e.Category == "strength");
        Assert.DoesNotContain(ranked, e => e.Category is "core" or "warmup" or "cooldown");
    }

    [Fact]
    public void Disliked_candidate_ranks_below_equal_neutral_one()
    {
        var original = TestEnv.Exercise("barbell-bench-press");
        var baseline = ExerciseSelector.RankSwapCandidates(original, TestEnv.Catalog.Exercises, Ctx(), "push");
        var top = baseline[0].Id;
        var ranked = ExerciseSelector.RankSwapCandidates(original, TestEnv.Catalog.Exercises, Ctx(new() { [top] = "disliked" }), "push");
        Assert.NotEqual(top, ranked[0].Id);
    }
}
