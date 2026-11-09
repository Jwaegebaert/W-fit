using System.Text.Json;
using WFit.Api.Ai;
using WFit.Api.Domain;

namespace WFit.Api.Tests;

public class AiPromptTests
{
    public static TheoryData<string, string> Prompts => new()
    {
        { nameof(AiPrompts.WorkoutSystem), AiPrompts.WorkoutSystem },
        { nameof(AiPrompts.AdjustSystem), AiPrompts.AdjustSystem },
        { nameof(AiPrompts.SwapSystem), AiPrompts.SwapSystem },
        { nameof(AiPrompts.InsightsSystem), AiPrompts.InsightsSystem },
    };

    [Theory]
    [MemberData(nameof(Prompts))]
    public void System_prompts_are_compact_and_well_formed(string name, string prompt)
    {
        Assert.True(prompt.Length < 6500, $"{name} is {prompt.Length} chars – keep system prompts compact (token cost).");
        Assert.StartsWith("You are W-fit's head coach", prompt);
        Assert.Contains("Badminton is secondary", prompt);
        Assert.Contains("JSON only", prompt);
        Assert.DoesNotContain("\n        ", prompt); // raw-string indentation stripped
    }

    [Fact]
    public void Workout_prompt_encodes_the_coaching_principles()
    {
        var p = AiPrompts.WorkoutSystem;
        foreach (var principle in new[] { "double progression", "targetRir", "effective sets", "48 h", "push:pull", "quad:ham", "Deload", "Anchor", "never change for variety", "red flags", "never diagnose", "rationale" })
            Assert.Contains(principle, p, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Candidate_view_is_compact_and_flags_cautions()
    {
        var limits = new LimitationFilter([new Limitation("pain", "knee", 1, null)], TestEnv.Today);
        var view = AiPrompts.CandidateView(TestEnv.StressCatalog.ExercisesById["leg-extension"], limits);

        Assert.Equal("leg-extension", view["id"]);
        Assert.Equal("mild knee pain: loads the knee", view["caution"]);
        Assert.False(view.ContainsKey("name"));
        Assert.True(view.ContainsKey("reps"));

        var plank = AiPrompts.CandidateView(TestEnv.Exercise("plank"), LimitationFilter.None);
        Assert.Equal(true, plank["floor"]);
        Assert.False(plank.ContainsKey("equipment"));
        Assert.True(plank.ContainsKey("sec"));
    }

    [Fact]
    public void Schemas_are_strict_and_list_only_allowed_ids()
    {
        using var workout = JsonDocument.Parse(AiSchemas.Workout(["a", "b", "a"]));
        var item = workout.RootElement.GetProperty("properties").GetProperty("blocks").GetProperty("items")
            .GetProperty("properties").GetProperty("items").GetProperty("items");
        Assert.Equal(["a", "b"], item.GetProperty("properties").GetProperty("exerciseId").GetProperty("enum").EnumerateArray().Select(e => e.GetString()));
        Assert.False(workout.RootElement.GetProperty("additionalProperties").GetBoolean());
        Assert.Equal(19, workout.RootElement.GetProperty("properties").GetProperty("focus").GetProperty("items").GetProperty("enum").GetArrayLength());

        using var adjust = JsonDocument.Parse(AiSchemas.Adjust(["x"]));
        var feedback = adjust.RootElement.GetProperty("properties").GetProperty("feedback").GetProperty("items");
        Assert.Equal(8, feedback.GetProperty("properties").GetProperty("kind").GetProperty("enum").GetArrayLength());
        Assert.Equal(7, feedback.GetProperty("required").GetArrayLength());

        using var insights = JsonDocument.Parse(AiSchemas.Insights());
        Assert.Equal(5, insights.RootElement.GetProperty("required").GetArrayLength());
    }
}
