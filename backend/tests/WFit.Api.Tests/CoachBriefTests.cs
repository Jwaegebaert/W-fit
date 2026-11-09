using System.Text.Json;
using WFit.Api.Ai;
using WFit.Api.Infrastructure;

namespace WFit.Api.Tests;

public class CoachBriefTests
{
    [Fact]
    public void Brief_json_is_parsed_tolerantly()
    {
        const string json = """
            { "today": "2026-11-09", "somethingNew": { "x": 1 },
              "profile": { "experience": "novice", "sessionMinutes": 60.0, "includeCore": null, "trainingDays": [1, 3.0, 5], "bodyweightKg": 78.5, "extra": true },
              "equipment": null,
              "preferences": { "liked": null, "disliked": ["push-up", null], "banned": [] },
              "limitations": [ null, { "kind": "pain", "region": "neck", "severity": 2.0, "since": "2026-11-07" } ],
              "program": { "blockNumber": 2, "blockWeek": 3.0, "deload": null, "variant": "B", "targetRir": 2 },
              "balance": { "muscles": [ { "muscle": "biceps", "thisWeek": 3.5, "targetMin": 4, "targetMax": 10, "weeksUnder": 2 } ], "ratios": { "pushPull": null } },
              "weekly": [ { "weekStart": "2026-11-02", "sessions": 3, "sets": 52.0, "volumeKg": 12000.5 } ] }
            """;

        var brief = CoachBriefRules.Sanitize(JsonSerializer.Deserialize<CoachBrief>(json, JsonDefaults.Options));

        Assert.Equal("novice", brief.Experience());
        Assert.Equal(60, brief.Profile!.SessionMinutes);
        Assert.Null(brief.Profile.IncludeCore);
        Assert.Equal(["push-up"], brief.Preferences!.Disliked!);
        var limitation = Assert.Single(brief.Limitations!);
        Assert.Equal("neck", limitation!.Region);
        Assert.False(brief.IsDeload());
        Assert.Equal("Block 2 · Week 3 · Push B", brief.ProgramLabel("push"));
        Assert.True(brief.HasTrainingData());
        Assert.DoesNotContain("somethingNew", AiPrompts.Serialize(brief));
    }

    [Fact]
    public void Lists_and_strings_are_capped_before_prompting()
    {
        var brief = CoachBriefRules.Sanitize(new CoachBrief
        {
            Profile = new BriefProfile { Experience = "pro", Notes = new string('n', 5000) },
            Limitations = [.. Enumerable.Range(0, 50).Select(i => (BriefLimitation?)new BriefLimitation { Kind = "pain", Region = "knee", Note = new string('x', 900) })],
            ExerciseFeedback = [.. Enumerable.Range(0, 60).Select(i => (BriefExerciseFeedback?)new BriefExerciseFeedback { ExerciseId = "push-up", Kind = "too_easy" })],
            ExerciseHistory =
            [
                .. Enumerable.Range(0, 40).Select(i => (BriefExerciseHistory?)new BriefExerciseHistory
                {
                    ExerciseId = $"ex-{i}",
                    Exposures = [.. Enumerable.Range(0, 10).Select(_ => (BriefExposure?)new BriefExposure { Date = "2026-11-03", Sets = "50x10" })],
                }),
            ],
            RecentSessions = [.. Enumerable.Range(0, 20).Select(i => (BriefSession?)new BriefSession { Date = "2026-11-01", Exercises = [.. Enumerable.Range(0, 30).Select(x => (string?)$"e{x}")] })],
            Weekly = [.. Enumerable.Range(0, 20).Select(i => (BriefWeek?)new BriefWeek { Sessions = 3 })],
            Equipment = new BriefEquipment { Unavailable = [.. Enumerable.Range(0, 300).Select(i => (string?)$"eq{i}")] },
        });

        Assert.Equal("beginner", brief.Experience()); // unknown experience
        Assert.Equal(CoachBriefRules.MaxNote, brief.Profile!.Notes!.Length);
        Assert.Equal(CoachBriefRules.MaxLimitations, brief.Limitations!.Count);
        Assert.Equal(CoachBriefRules.MaxNote, brief.Limitations[0]!.Note!.Length);
        Assert.Equal(CoachBriefRules.MaxExerciseFeedback, brief.ExerciseFeedback!.Count);
        Assert.Equal(CoachBriefRules.MaxExerciseHistory, brief.ExerciseHistory!.Count);
        Assert.All(brief.ExerciseHistory, h => Assert.Equal(CoachBriefRules.MaxExposures, h!.Exposures!.Count));
        Assert.Equal(CoachBriefRules.MaxRecentSessions, brief.RecentSessions!.Count);
        Assert.All(brief.RecentSessions, s => Assert.Equal(CoachBriefRules.MaxSessionExercises, s!.Exercises!.Count));
        Assert.Equal(CoachBriefRules.MaxWeekly, brief.Weekly!.Count);
        Assert.Equal(CoachBriefRules.MaxIdList, brief.Equipment!.Unavailable!.Count);
    }

    [Fact]
    public void Empty_brief_is_safe()
    {
        var brief = CoachBriefRules.Sanitize(null);
        Assert.Equal("beginner", brief.Experience());
        Assert.False(brief.HasTrainingData());
        Assert.Null(brief.ProgramLabel("legs"));
        Assert.True(brief.ToSelectionContext(TestEnv.Catalog, TestEnv.Today).Limitations.IsEmpty);
    }

    [Theory]
    [InlineData("2026-11-09", 2026, 11, 9)]
    [InlineData("2026-11-09T23:30:00Z", 2026, 11, 9)]
    [InlineData(" 2026-01-02 ", 2026, 1, 2)]
    public void Dates_are_parsed_leniently(string value, int y, int m, int d) =>
        Assert.Equal(new DateOnly(y, m, d), CoachBriefRules.ParseDate(value));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("09/11/2026")]
    [InlineData("soon")]
    public void Invalid_dates_are_null(string? value) => Assert.Null(CoachBriefRules.ParseDate(value));
}
