using System.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Azure.Identity;
using WFit.Api.Ai;
using WFit.Api.Domain;
using WFit.Api.Sync;
using Xunit.Abstractions;

namespace WFit.Api.Tests;

/// <summary>Runs only with <c>WFIT_LIVE_AI=1</c> and <c>AZURE_OPENAI_ENDPOINT</c> set (auth: DefaultAzureCredential, e.g. <c>az login</c>).</summary>
public sealed class LiveFactAttribute : FactAttribute
{
    public LiveFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("WFIT_LIVE_AI") != "1")
            Skip = "Live AI evaluation: set WFIT_LIVE_AI=1 (and AZURE_OPENAI_ENDPOINT).";
        else if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("AZURE_OPENAI_ENDPOINT")))
            Skip = "Live AI evaluation: AZURE_OPENAI_ENDPOINT is not set.";
    }
}

/// <summary>
/// Live evaluation of the coach against the deployed model (IMPROVEMENT-PLAN §6.4). Scenario briefs are built in code with
/// real catalog ids; the assertions check hard constraints and that the rationale addresses the scenario.
/// <code>$env:WFIT_LIVE_AI="1"; $env:AZURE_OPENAI_ENDPOINT="https://<openai-account>.openai.azure.com/"
/// dotnet test backend\WFit.sln --filter "FullyQualifiedName~LiveCoachEvalTests" --logger "console;verbosity=detailed"</code>
/// </summary>
public sealed class LiveCoachEvalTests(ITestOutputHelper output)
{
    private static readonly CatalogService Catalog = TestEnv.Catalog;
    private static readonly DateOnly Today = DateOnly.FromDateTime(DateTime.UtcNow);

    private sealed class RecordingClient(IAiClient inner) : IAiClient
    {
        public List<AiCompletion> Completions { get; } = [];

        public async Task<AiCompletion> CompleteAsync(AiPrompt prompt, string deployment, CancellationToken ct)
        {
            var completion = await inner.CompleteAsync(prompt, deployment, ct);
            Completions.Add(completion);
            return completion;
        }
    }

    private (AiGateway Gateway, RecordingClient Client) Live()
    {
        var config = new ConfigurationBuilder().AddEnvironmentVariables().Build();
        var settings = AiSettings.FromConfiguration(config) with { DailyCallLimit = 1000, MonthlyTokenLimit = long.MaxValue };
        // Developer credentials (az login, Visual Studio, ...): the managed-identity probe can hang on a workstation.
        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ExcludeManagedIdentityCredential = true,
            ExcludeWorkloadIdentityCredential = true,
        });
        var client = new RecordingClient(new AzureOpenAiClient(settings, credential));
        var gateway = new AiGateway(settings, client, new InMemoryAiUsageStore(), TimeProvider.System, NullLogger<AiGateway>.Instance);
        return (gateway, client);
    }

    private void Report(string scenario, RecordingClient client, long elapsedMs)
    {
        foreach (var c in client.Completions)
            output.WriteLine($"[{scenario}] model={c.Model} latency={c.LatencyMs} ms (end-to-end {elapsedMs} ms) tokens in={c.InputTokens} out={c.OutputTokens} reasoning={c.ReasoningTokens}");
    }

    private void Print(AiWorkoutDto workout)
    {
        output.WriteLine($"{workout.Title} — {workout.CoachNote}");
        foreach (var block in workout.Blocks)
        foreach (var item in block.Items)
            output.WriteLine($"  {block.Section,-8} {item.ExerciseId,-36} {item.Sets}x{item.RepMin}-{item.RepMax}{(item.DurationSeconds is { } s ? $" {s}s" : "")} {item.TargetWeightKg?.ToString() ?? "-"} kg  {item.Notes}");
        foreach (var line in workout.Meta.Rationale) output.WriteLine($"  • {line}");
        foreach (var change in workout.Meta.Changes) output.WriteLine($"  ↺ {change.From} → {change.To}: {change.Reason}");
    }

    // ---------------- Scenario data ----------------

    private static WorkoutItemDto Item(string id, int sets, int? repMin, int? repMax, int rest, double? kg = null, int? seconds = null) =>
        new() { ExerciseId = id, Sets = sets, RepMin = repMin, RepMax = repMax, DurationSeconds = seconds, RestSeconds = rest, TargetWeightKg = kg, Notes = "" };

    private static WorkoutBlockDto Block(string section, params WorkoutItemDto[] items) => new() { Section = section, Items = [.. items] };

    private static PlanInput PushDraft(bool deload = false) => new()
    {
        Title = "Push A · chest strength",
        Blocks =
        [
            Block("warmup", Item("rowing-easy", 1, null, null, 0, seconds: 300), Item("band-pull-apart", 2, 12, 15, 15), Item("arm-circles", 1, null, null, 0, seconds: 45)),
            Block("main",
                Item("machine-chest-press", deload ? 2 : 3, 6, 10, 150, 50),
                Item("seated-dumbbell-shoulder-press", deload ? 2 : 3, 8, 12, 120, 12),
                Item("incline-dumbbell-press", deload ? 2 : 3, 8, 12, 120, 16),
                Item("dumbbell-lateral-raise", deload ? 2 : 3, 12, 15, 60, 6),
                Item("cable-triceps-pushdown", deload ? 2 : 3, 10, 15, 60, 20)),
            Block("cooldown", Item("chest-doorway-stretch", 1, null, null, 0, seconds: 60)),
        ],
        Meta = new PlanMetaInput { Program = "Block 2 · Week 3 · Push A", Variant = "A", Deload = deload, Rationale = ["Chest press is the block anchor."] },
    };

    private static PlanInput PullDraft() => new()
    {
        Title = "Pull B · rows",
        Blocks =
        [
            Block("warmup", Item("rowing-easy", 1, null, null, 0, seconds: 300), Item("band-pull-apart", 2, 12, 15, 15)),
            Block("main",
                Item("seated-cable-row", 3, 6, 10, 150, 45),
                Item("lat-pulldown", 3, 8, 12, 120, 40),
                Item("face-pull", 3, 12, 15, 60, 15),
                Item("reverse-dumbbell-fly", 2, 12, 15, 60, 5),
                Item("dumbbell-biceps-curl", 2, 10, 12, 60, 10)),
            Block("cooldown", Item("childs-pose", 1, null, null, 0, seconds: 60)),
        ],
        Meta = new PlanMetaInput { Program = "Block 2 · Week 3 · Pull B", Variant = "B" },
    };

    private static PlanInput LegsDraft(bool deload = false) => new()
    {
        Title = "Legs A · squat pattern",
        Blocks =
        [
            Block("warmup", Item("bike-easy", 1, null, null, 0, seconds: 300), Item("leg-swings", 1, 10, 12, 0), Item("bodyweight-squat", 1, 10, 12, 0)),
            Block("main",
                Item("leg-press", deload ? 2 : 3, 8, 12, 150, deload ? 90 : 100),
                Item("dumbbell-romanian-deadlift", deload ? 2 : 3, 8, 12, 120, 18),
                Item("leg-extension", deload ? 2 : 3, 10, 15, 75, 30),
                Item("lying-leg-curl", deload ? 2 : 3, 10, 15, 75, 25),
                Item("standing-calf-raise", deload ? 2 : 3, 10, 15, 60, 40)),
            Block("cooldown", Item("standing-quad-stretch", 1, null, null, 0, seconds: 45), Item("hamstring-stretch", 1, null, null, 0, seconds: 45)),
        ],
        Meta = new PlanMetaInput { Program = deload ? "Block 2 · Week 6 · Legs A · Deload" : "Block 2 · Week 3 · Legs A", Variant = "A", Deload = deload },
    };

    private static List<BriefMuscle?> Balanced(params BriefMuscle[] overrides)
    {
        var list = Anatomy.TrackedMuscles.Select(m => (BriefMuscle?)new BriefMuscle
        {
            Muscle = m.Id, ThisWeek = Math.Round(m.Min * 0.6, 1), LastWeek = Math.Round((m.Min + m.Max) / 2, 1), RecentAvg = Math.Round((m.Min + m.Max) / 2, 1),
            TargetMin = m.Min, TargetMax = m.Max, Status = "ok", WeeksUnder = 0, DaysSinceTrained = 3, Trend = "flat",
        }).ToList();
        foreach (var o in overrides)
        {
            var index = list.FindIndex(m => m!.Muscle == o.Muscle);
            list[index] = o;
        }
        return list;
    }

    private static CoachBrief Brief(
        List<BriefLimitation?>? limitations = null,
        BriefProgram? program = null,
        BriefBalance? balance = null,
        List<BriefExerciseHistory?>? history = null) => new()
    {
        Today = AiPrompts.Date(Today),
        Profile = new BriefProfile
        {
            Experience = "beginner", Goals = "Balanced strength and muscle; stay fit for badminton", SessionMinutes = 60, IncludeCore = false,
            TrainingDays = [1, 3, 5], Age = 34, HeightCm = 180, BodyweightKg = 78.5, Injuries = "", Notes = "Machine-heavy gym, limited floor space.",
        },
        Equipment = new BriefEquipment { Unavailable = [], Occupied = [] },
        Preferences = new BriefPreferences { Liked = ["machine-chest-press"], Disliked = [], Banned = [] },
        Limitations = limitations ?? [],
        ExerciseFeedback = [],
        Program = program ?? new BriefProgram
        {
            BlockNumber = 2, BlockWeek = 3, BlockLength = 6, Phase = "accumulation", Deload = false, Variant = "A",
            VariantFocus = "horizontal press heavy", TargetRir = 2, CompletedSessions = 23, WeeksTraining = 8,
        },
        Balance = balance ?? new BriefBalance { Muscles = Balanced(), Priorities = [], Ratios = new BriefRatios { PushPull = 1.05, QuadHam = 1.3 }, Notes = [] },
        ExerciseHistory = history ??
        [
            new BriefExerciseHistory
            {
                ExerciseId = "machine-chest-press", Trend = "progressing", LastPerformed = AiPrompts.Date(Today.AddDays(-7)),
                Exposures = [new BriefExposure { Date = AiPrompts.Date(Today.AddDays(-7)), Sets = "47.5x10, 47.5x10, 47.5x9", E1rm = 63.3 }],
            },
        ],
        RecentSessions =
        [
            new BriefSession { Date = AiPrompts.Date(Today.AddDays(-2)), DayType = "legs", Title = "Legs B", Rating = 4, Effort = 7, DurationMin = 58, Notes = "", Exercises = ["leg-press", "dumbbell-romanian-deadlift", "lying-leg-curl"] },
            new BriefSession { Date = AiPrompts.Date(Today.AddDays(-4)), DayType = "pull", Title = "Pull A", Rating = 4, Effort = 7, DurationMin = 60, Notes = "", Exercises = ["lat-pulldown", "seated-cable-row", "face-pull"] },
            new BriefSession { Date = AiPrompts.Date(Today.AddDays(-7)), DayType = "push", Title = "Push A", Rating = 4, Effort = 8, DurationMin = 61, Notes = "", Exercises = ["machine-chest-press", "seated-dumbbell-shoulder-press"] },
        ],
        Weekly = [new BriefWeek { WeekStart = AiPrompts.Date(Today.AddDays(-7)), Sessions = 3, Sets = 52, VolumeKg = 12000 }],
    };

    private static double EffectiveSets(IEnumerable<WorkoutBlockDto?>? blocks, string muscle) =>
        (blocks ?? []).OfType<WorkoutBlockDto>().Where(b => b.Section == "main").SelectMany(b => b.Items)
            .Sum(i => i.Sets * Anatomy.EffectiveSetWeight(Catalog.ExercisesById[i.ExerciseId], muscle));

    private static string AllText(AiWorkoutDto w) =>
        string.Join("\n", w.Meta.Rationale.Append(w.CoachNote).Concat(w.Blocks.SelectMany(b => b.Items).Select(i => i.Notes))
            .Concat(w.Meta.Changes.Select(c => c.Reason))).ToLowerInvariant();

    private async Task<AiWorkoutDto> GenerateAsync(string scenario, string dayType, CoachBrief brief, PlanInput draft, string? userNote = null)
    {
        var (gateway, client) = Live();
        var service = new WorkoutAiService(Catalog, gateway, TimeProvider.System);
        var stopwatch = Stopwatch.StartNew();
        var response = await service.GenerateAsync(new AiWorkoutRequest
        {
            DayType = Enum.Parse<DayType>(dayType, ignoreCase: true), Date = Today, SessionMinutes = 60, IncludeCore = false,
            UserNote = userNote, Brief = brief, Draft = draft,
        }, CancellationToken.None);
        Report(scenario, client, stopwatch.ElapsedMilliseconds);
        Print(response.Workout);
        return response.Workout;
    }

    // ---------------- Scenarios ----------------

    [LiveFact]
    public async Task A_neck_pain_on_push_day_removes_neck_stress_and_explains_it()
    {
        var brief = Brief(limitations:
        [
            new BriefLimitation { Id = Guid.NewGuid().ToString(), Kind = "pain", Region = "neck", Severity = 2, Note = "Neck stiff and painful when I look up, since Saturday", Since = AiPrompts.Date(Today.AddDays(-2)) },
        ]);

        var workout = await GenerateAsync("neck-pain", "push", brief, PushDraft());

        var neckStress = workout.Blocks.SelectMany(b => b.Items).Where(i => (Catalog.ExercisesById[i.ExerciseId].Stress ?? []).Contains("neck")).ToList();
        Assert.Empty(neckStress);
        Assert.Contains("neck", AllText(workout));
    }

    [LiveFact]
    public async Task B_biceps_under_target_for_two_weeks_gets_more_biceps_volume()
    {
        var balance = new BriefBalance
        {
            Muscles = Balanced(new BriefMuscle
            {
                Muscle = "biceps", ThisWeek = 0, LastWeek = 3.0, RecentAvg = 3.2, TargetMin = 4, TargetMax = 10, Status = "under",
                WeeksUnder = 2, DaysSinceTrained = 4, Trend = "down",
            }),
            Priorities = [new BriefPriority { Muscle = "biceps", Score = 0.85, ExtraSets = 2, Reason = "below target 2 weeks running" }],
            Ratios = new BriefRatios { PushPull = 1.15, QuadHam = 1.3 },
            Notes = ["Biceps below target in 2 of the last 2 weeks"],
        };
        var brief = Brief(balance: balance, program: new BriefProgram
        {
            BlockNumber = 2, BlockWeek = 3, BlockLength = 6, Phase = "accumulation", Deload = false, Variant = "B", VariantFocus = "row heavy (+ traps)", TargetRir = 2,
        });
        var draft = PullDraft();

        var workout = await GenerateAsync("biceps-deficit", "pull", brief, draft);

        var before = EffectiveSets(draft.Blocks, "biceps");
        var after = EffectiveSets(workout.Blocks, "biceps");
        output.WriteLine($"biceps effective sets: draft {before} → plan {after}");
        Assert.True(after >= before + 1, $"Expected ≥ {before + 1} biceps sets, got {after}.");
        Assert.Contains(workout.Meta.Rationale, l => l.Contains("biceps", StringComparison.OrdinalIgnoreCase));
    }

    [LiveFact]
    public async Task C_stalled_anchor_lift_is_addressed()
    {
        var weeks = Enumerable.Range(1, 4).Select(w => (BriefExposure?)new BriefExposure
        {
            Date = AiPrompts.Date(Today.AddDays(-7 * w)), Sets = "50x8, 50x8, 50x7", E1rm = 63.3,
        }).ToList();
        var brief = Brief(history:
        [
            new BriefExerciseHistory { ExerciseId = "machine-chest-press", Trend = "stalled", LastPerformed = weeks[0]!.Date, Exposures = weeks },
            new BriefExerciseHistory
            {
                ExerciseId = "incline-dumbbell-press", Trend = "progressing", LastPerformed = weeks[0]!.Date,
                Exposures = [new BriefExposure { Date = weeks[0]!.Date, Sets = "16x12, 16x11, 16x10", E1rm = 22.4 }],
            },
        ]);

        var workout = await GenerateAsync("stalled-anchor", "push", brief, PushDraft());

        var text = AllText(workout);
        string[] stallWords = ["stall", "plateau", "deload", "variation", "reps", "rep range", "reset", "drop", "back off", "swap", "instead", "%"];
        Assert.True(stallWords.Any(text.Contains), $"No stall handling found in:\n{text}");
        Assert.True(text.Contains("chest press") || text.Contains("machine-chest-press") || workout.Meta.Changes.Any(c => c.From == "machine-chest-press"),
            "The rationale should name the stalled chest press.");
    }

    [LiveFact]
    public async Task D_deload_week_caps_every_main_item_at_three_sets()
    {
        var brief = Brief(program: new BriefProgram
        {
            BlockNumber = 2, BlockWeek = 6, BlockLength = 6, Phase = "deload", Deload = true, DeloadReason = "planned end-of-block deload",
            Variant = "A", TargetRir = 3, CompletedSessions = 30, WeeksTraining = 10,
        });

        var workout = await GenerateAsync("deload", "legs", brief, LegsDraft(deload: true));

        Assert.True(workout.Meta.Deload);
        Assert.All(workout.Blocks.Where(b => b.Section == "main").SelectMany(b => b.Items), i => Assert.InRange(i.Sets, 1, 3));
    }

    [LiveFact]
    public async Task E_adjust_broken_leg_press_and_sore_knee()
    {
        var (gateway, client) = Live();
        var service = new AdjustAiService(Catalog, gateway, TimeProvider.System, NullLogger<AdjustAiService>.Instance);
        var draft = LegsDraft();
        var stopwatch = Stopwatch.StartNew();

        var response = await service.AdjustAsync(new AdjustRequest
        {
            Message = "the leg press is broken and my left knee feels a bit sore",
            ExerciseId = "leg-press",
            SessionInProgress = true,
            Plan = draft with { Id = Guid.NewGuid().ToString(), Date = AiPrompts.Date(Today), DayType = "legs" },
            Brief = Brief(),
        }, CancellationToken.None);

        Report("adjust-leg-press", client, stopwatch.ElapsedMilliseconds);
        output.WriteLine($"reply: {response.Reply}");
        foreach (var f in response.Feedback)
            output.WriteLine($"  feedback {f.Kind} region={f.Region} severity={f.Severity} exercise={f.ExerciseId} equipment={f.EquipmentId} review={f.ReviewInDays} — {f.Note}");
        if (response.Plan is { } p)
        {
            foreach (var block in p.Blocks)
            foreach (var item in block.Items)
                output.WriteLine($"  {block.Section,-8} {item.ExerciseId,-36} {item.Sets}x{item.RepMin}-{item.RepMax}");
            foreach (var line in p.Meta.Rationale) output.WriteLine($"  • {line}");
        }

        Assert.Contains(response.Feedback, f =>
            (f.Kind == "unavailable" && (f.ExerciseId == "leg-press" || f.EquipmentId == "leg_press"))
            || (f.Kind is "pain" or "discomfort" && f.Region == "knee"));
        Assert.NotNull(response.Plan);
        Assert.DoesNotContain(response.Plan!.Blocks.SelectMany(b => b.Items), i => i.ExerciseId == "leg-press");
    }
}
