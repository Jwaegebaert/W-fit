using System.Globalization;
using System.Text.RegularExpressions;
using WFit.Api.Ai;
using WFit.Api.Domain;

namespace WFit.Api.Tests;

public class LimitationFilterTests
{
    private static readonly DateOnly Today = TestEnv.Today;

    private static CatalogExerciseItem Ex(string id, string[] primary, string[]? stress, string category = "strength", string[]? secondary = null) =>
        new(id, id, category, ["push", "pull", "legs"], primary, secondary ?? [], "pattern", [], 1, true, false, "reps", 3, 8, 12, null, 90, 2.5,
            null, [], null, null, stress);

    private static readonly CatalogExerciseItem Shrug = Ex("shrug", ["traps"], ["neck"]);
    private static readonly CatalogExerciseItem OverheadPress = Ex("ohp", ["front_delts"], ["neck", "shoulder", "lower_back"]);
    private static readonly CatalogExerciseItem FacePull = Ex("face-pull", ["rear_delts"], []);
    private static readonly CatalogExerciseItem UprightRowNoStress = Ex("cable-shrug", ["traps"], []);
    private static readonly CatalogExerciseItem LegExtension = Ex("leg-extension", ["quads"], ["knee"]);
    private static readonly CatalogExerciseItem LegPress = Ex("leg-press", ["quads", "glutes"], ["knee", "hip"]);
    private static readonly CatalogExerciseItem RomanianDeadlift = Ex("rdl", ["hamstrings", "glutes"], ["lower_back", "hip"]);
    private static readonly CatalogExerciseItem NoStressInfo = Ex("v2-exercise", ["quads"], null);

    private static LimitationFilter Filter(params Limitation[] limitations) => new(limitations, Today);

    [Fact]
    public void Mild_region_pain_penalises_stressing_exercises_but_keeps_them_allowed()
    {
        var filter = Filter(new Limitation("pain", "neck", 1, null));

        var verdict = filter.Evaluate(Shrug);
        Assert.Equal(LimitationEffect.Penalised, verdict.Effect);
        Assert.Equal(LimitationFilter.MildRegionPenalty, verdict.Penalty);
        Assert.Equal(["neck"], verdict.CautionRegions);
        Assert.Contains("mild neck pain", verdict.Reason);
        Assert.False(filter.Excludes(Shrug));
        Assert.Equal(LimitationEffect.None, filter.Evaluate(FacePull).Effect);
        Assert.Equal(LimitationEffect.None, filter.Evaluate(UprightRowNoStress).Effect);
    }

    [Fact]
    public void Moderate_region_pain_excludes_exercises_that_stress_the_region()
    {
        var filter = Filter(new Limitation("pain", "neck", 2, null));

        Assert.True(filter.Excludes(Shrug));
        Assert.True(filter.Excludes(OverheadPress));
        Assert.Equal("moderate neck pain: loads the neck", filter.Evaluate(OverheadPress).Reason);
        // Direct traps work without neck stress stays allowed below severity 3.
        Assert.False(filter.Excludes(UprightRowNoStress));
        Assert.False(filter.Excludes(FacePull));
        Assert.Empty(filter.AvoidedMuscles);
    }

    [Fact]
    public void Severe_region_pain_also_excludes_direct_work_for_related_muscles()
    {
        var filter = Filter(new Limitation("pain", "neck", 3, null));

        Assert.True(filter.Excludes(UprightRowNoStress));
        Assert.Contains("direct traps work", filter.Evaluate(UprightRowNoStress).Reason);
        Assert.False(filter.Excludes(FacePull));
        Assert.Equal(["traps"], filter.AvoidedMuscles);

        // Secondary involvement is not "direct work".
        var rowWithTrapsSecondary = Ex("row", ["upper_back"], [], secondary: ["traps"]);
        Assert.False(filter.Excludes(rowWithTrapsSecondary));
    }

    [Theory]
    [InlineData("knee", 3, "leg-press", true)]
    [InlineData("knee", 3, "v2-exercise", true)]   // quads are related to the knee
    [InlineData("knee", 2, "v2-exercise", false)]  // no stress data: only severity 3 can exclude
    [InlineData("hip", 2, "leg-extension", false)]
    [InlineData("hip", 2, "rdl", true)]
    [InlineData("lower_back", 2, "leg-press", false)]
    public void Region_rules_follow_stress_tags_and_related_muscles(string region, int severity, string exerciseId, bool excluded)
    {
        var exercises = new[] { LegPress, NoStressInfo, LegExtension, RomanianDeadlift }.ToDictionary(e => e.Id);
        Assert.Equal(excluded, Filter(new Limitation("discomfort", region, severity, null)).Excludes(exercises[exerciseId]));
    }

    [Fact]
    public void Exercise_specific_pain_excludes_and_discomfort_excludes_for_four_weeks_then_penalises()
    {
        Assert.True(Filter(new Limitation("pain", null, 1, "leg-extension", Today.AddDays(-200))).Excludes(LegExtension));
        Assert.True(Filter(new Limitation("discomfort", null, 1, "leg-extension", Today.AddDays(-27))).Excludes(LegExtension));
        Assert.True(Filter(new Limitation("discomfort", null, 1, "leg-extension")).Excludes(LegExtension)); // no date: stay safe

        var old = Filter(new Limitation("discomfort", null, 1, "leg-extension", Today.AddDays(-28))).Evaluate(LegExtension);
        Assert.Equal(LimitationEffect.Penalised, old.Effect);
        Assert.Equal(LimitationFilter.OldDiscomfortPenalty, old.Penalty);
        Assert.False(Filter(new Limitation("pain", null, 3, "leg-extension")).Excludes(LegPress));
    }

    [Fact]
    public void Exercise_and_region_on_the_same_entry_apply_both_rules()
    {
        var filter = Filter(new Limitation("pain", "knee", 1, "leg-extension"));
        Assert.True(filter.Excludes(LegExtension));
        Assert.Equal(LimitationEffect.Penalised, filter.Evaluate(LegPress).Effect);
    }

    [Fact]
    public void Default_severity_and_invalid_entries()
    {
        // pain without severity = moderate (excluded), discomfort without severity = mild (penalised).
        Assert.True(Filter(new Limitation("pain", "knee", null, null)).Excludes(LegExtension));
        Assert.Equal(LimitationEffect.Penalised, Filter(new Limitation("discomfort", "knee", null, null)).Evaluate(LegExtension).Effect);

        var ignored = Filter(
            new Limitation("too_hard", "knee", 3, null),
            new Limitation("pain", "toe", 3, null),
            new Limitation("pain", null, 3, null),
            new Limitation("unavailable", null, null, "leg-extension"));
        Assert.True(ignored.IsEmpty);
        Assert.False(ignored.Excludes(LegExtension));

        Assert.Equal(3, Filter(new Limitation("PAIN", "knee", 9, null)).RegionSeverity["knee"]);
    }

    [Fact]
    public void Penalties_add_up_across_mild_regions()
    {
        var filter = Filter(new Limitation("pain", "neck", 1, null), new Limitation("discomfort", "shoulder", 1, null));
        Assert.Equal(2 * LimitationFilter.MildRegionPenalty, filter.Penalty(OverheadPress));
    }

    [Fact]
    public void Selector_excludes_and_ranks_with_limitations()
    {
        var catalog = TestEnv.StressCatalog;
        var limits = new LimitationFilter([new Limitation("pain", "neck", 2, null)], Today);
        var ctx = SelectionContext.Create(catalog, "beginner", limitations: limits);
        var candidates = ExerciseSelector.CandidatesByCategory(catalog.Exercises, ctx, "push");
        Assert.DoesNotContain(candidates["strength"], e => e.Id == "seated-dumbbell-shoulder-press");
        Assert.Contains(candidates["strength"], e => e.Id == "machine-shoulder-press");

        var mild = SelectionContext.Create(catalog, "beginner", limitations: new LimitationFilter([new Limitation("pain", "shoulder", 1, null)], Today));
        var original = catalog.ExercisesById["seated-dumbbell-shoulder-press"];
        var neutral = ExerciseSelector.RankSwapCandidates(original, catalog.Exercises, SelectionContext.Create(catalog, "beginner"), "push").ToList();
        var ranked = ExerciseSelector.RankSwapCandidates(original, catalog.Exercises, mild, "push").ToList();
        Assert.DoesNotContain("shoulder", ranked[0].Stress ?? []);
        Assert.Contains(ranked, e => e.Id == "machine-shoulder-press"); // penalised, not excluded
        Assert.True(ranked.FindIndex(e => e.Id == "machine-shoulder-press") > neutral.FindIndex(e => e.Id == "machine-shoulder-press"));
    }

    [Fact]
    public void Brief_limitations_become_a_selection_context()
    {
        var brief = CoachBriefRules.Sanitize(new CoachBrief
        {
            Profile = new BriefProfile { Experience = "intermediate" },
            Equipment = new BriefEquipment { Unavailable = ["leg_press", null], Occupied = ["cable_machine"] },
            Preferences = new BriefPreferences { Liked = ["leg-extension"], Banned = ["leg-extension", "goblet-squat"] },
            Limitations = [new BriefLimitation { Kind = "pain", Region = "knee", Severity = 2.0, Since = "2026-11-07T10:00:00Z" }, null],
        });

        var ctx = brief.ToSelectionContext(TestEnv.StressCatalog, Today, extraOccupied: ["smith_machine"]);

        Assert.Equal("intermediate", ctx.Experience);
        Assert.False(ctx.EquipmentAvailability["leg_press"]);
        Assert.Equal(["cable_machine", "smith_machine"], ctx.OccupiedEquipment.Order());
        Assert.Equal("banned", ctx.PreferenceOf("leg-extension"));
        Assert.Equal(2, ctx.Limitations.RegionSeverity["knee"]);
        Assert.Equal(new DateOnly(2026, 11, 7), ctx.Limitations.Active.Single().Since);
    }
}

public class AnatomyTests
{
    [Fact]
    public void Vocabulary_matches_the_plan()
    {
        Assert.Equal(19, Anatomy.TrackedMuscles.Count);
        Assert.Equal((4, 10), (Anatomy.Targets["biceps"].Min, Anatomy.Targets["biceps"].Max));
        Assert.Equal(9, Anatomy.Regions.Count);
        Assert.Equal(23, Anatomy.MuscleVocabulary.Count);
        Assert.Equal(["front_delts", "rear_delts", "rotator_cuff", "side_delts"], Anatomy.RelatedMusclesOf("shoulder").Order());
        Assert.Empty(Anatomy.RelatedMusclesOf("toe"));
        Assert.Equal(0.5, Anatomy.EffectiveSetWeight(TestEnv.Exercise("lat-pulldown"), "biceps"));
        Assert.Equal(1, Anatomy.EffectiveSetWeight(TestEnv.Exercise("lat-pulldown"), "lats"));
    }

    /// <summary>The backend mirror must stay identical to app/lib/domain/muscles.dart.</summary>
    [Fact]
    public void Mirrors_the_dart_vocabulary()
    {
        var path = FindRepoFile(Path.Combine("app", "lib", "domain", "muscles.dart"));
        if (path is null) return; // source tree not available (e.g. packaged test run)
        var dart = File.ReadAllText(path);

        var muscles = Regex.Matches(dart, @"MuscleInfo\('(\w+)', '[^']*', MuscleGroup\.(\w+), MuscleTarget\(([\d.]+), ([\d.]+)\)\)")
            .Select(m => (Id: m.Groups[1].Value, Group: m.Groups[2].Value,
                Min: double.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture), Max: double.Parse(m.Groups[4].Value, CultureInfo.InvariantCulture)))
            .ToList();
        Assert.Equal(Anatomy.TrackedMuscles.Select(m => (m.Id, m.Group, m.Min, m.Max)), muscles);

        var vocabulary = Regex.Match(dart, @"muscleVocabulary = \{(.*?)\};", RegexOptions.Singleline).Groups[1].Value;
        var extras = Regex.Matches(vocabulary, @"'(\w+)'").Select(m => m.Groups[1].Value);
        Assert.Equal(Anatomy.MuscleVocabulary.Order(), Anatomy.TrackedMuscleIds.Concat(extras).Order());

        var regionIds = Regex.Matches(dart, @"^\s*(\w+)\('([a-z_]+)', '[^']*'\)[,;]", RegexOptions.Multiline)
            .ToDictionary(m => m.Groups[1].Value, m => m.Groups[2].Value);
        Assert.Equal(Anatomy.Regions, regionIds.Values);

        var related = Regex.Matches(dart, @"BodyRegion\.(\w+) => const \{([^}]*)\}")
            .ToDictionary(m => regionIds[m.Groups[1].Value], m => Regex.Matches(m.Groups[2].Value, @"'(\w+)'").Select(x => x.Groups[1].Value).Order().ToList());
        Assert.Equal(Anatomy.Regions.Count, related.Count);
        foreach (var (region, list) in related)
            Assert.Equal(Anatomy.RelatedMusclesOf(region).Order(), list);

        Assert.Contains($"secondarySetWeight = {Anatomy.SecondarySetWeight.ToString(CultureInfo.InvariantCulture)};", dart);
    }

    internal static string? FindRepoFile(string relative)
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, relative);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
