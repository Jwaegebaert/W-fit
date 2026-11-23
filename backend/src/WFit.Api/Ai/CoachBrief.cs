using System.Globalization;
using WFit.Api.Domain;

namespace WFit.Api.Ai;

// Coach brief (IMPROVEMENT-PLAN §4.4), built on the device and sent with every AI request.
// Deliberately tolerant: unknown fields are ignored, every field may be null, numbers are doubles
// (Dart may send 52.0 for counts) and list sizes / string lengths are capped by Sanitize() before prompting.

public sealed record CoachBrief
{
    public string? Today { get; init; }
    public BriefProfile? Profile { get; init; }
    public BriefEquipment? Equipment { get; init; }
    public BriefPreferences? Preferences { get; init; }
    public List<BriefLimitation?>? Limitations { get; init; }
    public List<BriefExerciseFeedback?>? ExerciseFeedback { get; init; }
    public BriefProgram? Program { get; init; }
    public BriefBalance? Balance { get; init; }
    public List<BriefExerciseHistory?>? ExerciseHistory { get; init; }
    public List<BriefSession?>? RecentSessions { get; init; }
    public List<BriefWeek?>? Weekly { get; init; }
}

public sealed record BriefProfile
{
    public string? Experience { get; init; }
    public string? Goals { get; init; }
    public double? SessionMinutes { get; init; }
    public bool? IncludeCore { get; init; }

    /// <summary>Rest between sets: short (x0.7) | normal | long (x1.3).</summary>
    public string? RestMode { get; init; }

    /// <summary>Cool-down stretches wanted, 0-3 (0 = no cool-down block).</summary>
    public double? CooldownStretches { get; init; }
    public List<double>? TrainingDays { get; init; }
    public double? Age { get; init; }
    public double? HeightCm { get; init; }
    public double? BodyweightKg { get; init; }
    public string? Injuries { get; init; }
    public string? Notes { get; init; }
}

public sealed record BriefEquipment
{
    public List<string?>? Unavailable { get; init; }
    public List<string?>? Occupied { get; init; }
}

public sealed record BriefPreferences
{
    public List<string?>? Liked { get; init; }
    public List<string?>? Disliked { get; init; }
    public List<string?>? Banned { get; init; }
}

public sealed record BriefLimitation
{
    public string? Id { get; init; }
    public string? Kind { get; init; }
    public string? Region { get; init; }
    public double? Severity { get; init; }
    public string? ExerciseId { get; init; }
    public string? Note { get; init; }
    public string? Since { get; init; }
}

public sealed record BriefExerciseFeedback
{
    public string? ExerciseId { get; init; }
    public string? Kind { get; init; }
    public string? Note { get; init; }
    public string? Date { get; init; }
}

public sealed record BriefProgram
{
    public double? BlockNumber { get; init; }
    public double? BlockWeek { get; init; }
    public double? BlockLength { get; init; }
    public string? Phase { get; init; }
    public bool? Deload { get; init; }
    public string? DeloadReason { get; init; }
    public string? Variant { get; init; }
    public string? VariantFocus { get; init; }
    public double? TargetRir { get; init; }
    public double? CompletedSessions { get; init; }
    public double? WeeksTraining { get; init; }
}

public sealed record BriefBalance
{
    public List<BriefMuscle?>? Muscles { get; init; }
    public List<BriefPriority?>? Priorities { get; init; }
    public BriefRatios? Ratios { get; init; }
    public List<string?>? Notes { get; init; }
}

public sealed record BriefMuscle
{
    public string? Muscle { get; init; }
    public double? ThisWeek { get; init; }
    public double? LastWeek { get; init; }
    public double? RecentAvg { get; init; }
    public double? TargetMin { get; init; }
    public double? TargetMax { get; init; }
    public string? Status { get; init; }
    public double? WeeksUnder { get; init; }
    public double? DaysSinceTrained { get; init; }
    public string? Trend { get; init; }
}

public sealed record BriefPriority
{
    public string? Muscle { get; init; }
    public double? Score { get; init; }
    public double? ExtraSets { get; init; }
    public string? Reason { get; init; }
}

public sealed record BriefRatios
{
    public double? PushPull { get; init; }
    public double? QuadHam { get; init; }
}

public sealed record BriefExerciseHistory
{
    public string? ExerciseId { get; init; }
    public string? Trend { get; init; }
    public string? LastPerformed { get; init; }

    /// <summary>Empty-bar weight on top of the logged kg (bar exercises log plates only).</summary>
    public double? BarKg { get; init; }
    public List<BriefExposure?>? Exposures { get; init; }
}

public sealed record BriefExposure
{
    public string? Date { get; init; }
    public string? Sets { get; init; }
    public double? E1rm { get; init; }
}

public sealed record BriefSession
{
    public string? Date { get; init; }
    public string? DayType { get; init; }
    public string? Title { get; init; }
    public double? Rating { get; init; }
    public double? Effort { get; init; }
    public double? DurationMin { get; init; }
    public string? Notes { get; init; }
    public List<string?>? Exercises { get; init; }
}

public sealed record BriefWeek
{
    public string? WeekStart { get; init; }
    public double? Sessions { get; init; }
    public double? Sets { get; init; }
    public double? VolumeKg { get; init; }
}

/// <summary>Brief size limits (documented in docs/API.md) and helpers to turn the brief into a selection context.</summary>
public static class CoachBriefRules
{
    public const int MaxRequestBytes = 256 * 1024;
    public const int MaxLimitations = 20;
    public const int MaxExerciseFeedback = 30;
    public const int MaxExerciseHistory = 25;
    public const int MaxExposures = 4;
    public const int MaxRecentSessions = 9;
    public const int MaxSessionExercises = 15;
    public const int MaxWeekly = 8;
    public const int MaxBalanceMuscles = 25;
    public const int MaxPriorities = 8;
    public const int MaxNotes = 8;
    public const int MaxIdList = 100;
    public const int MaxNote = 500;
    public const int MaxShort = 120;

    /// <summary>Copy with nulls removed, lists truncated to the documented limits and strings shortened.</summary>
    public static CoachBrief Sanitize(CoachBrief? brief)
    {
        if (brief is null) return new CoachBrief();
        return new CoachBrief
        {
            Today = Short(brief.Today, 10),
            Profile = brief.Profile is { } p
                ? p with
                {
                    Experience = Short(p.Experience, 16),
                    RestMode = p.RestMode is "short" or "long" ? p.RestMode : "normal",
                    CooldownStretches = p.CooldownStretches is { } c ? Math.Clamp(Math.Round(c), 0, 3) : null,
                    Goals = Short(p.Goals, MaxNote),
                    TrainingDays = p.TrainingDays?.Take(7).ToList(),
                    Injuries = Short(p.Injuries, 1000),
                    Notes = Short(p.Notes, MaxNote),
                }
                : null,
            Equipment = brief.Equipment is { } eq
                ? new BriefEquipment { Unavailable = Ids(eq.Unavailable), Occupied = Ids(eq.Occupied) }
                : null,
            Preferences = brief.Preferences is { } pr
                ? new BriefPreferences { Liked = Ids(pr.Liked), Disliked = Ids(pr.Disliked), Banned = Ids(pr.Banned) }
                : null,
            Limitations = brief.Limitations?.OfType<BriefLimitation>().Take(MaxLimitations)
                .Select(l => l with
                {
                    Id = Short(l.Id, 40), Kind = Short(l.Kind, 16), Region = Short(l.Region, 16),
                    ExerciseId = Short(l.ExerciseId, 64), Note = Short(l.Note, MaxNote), Since = Short(l.Since, 10),
                }).ToList<BriefLimitation?>(),
            ExerciseFeedback = brief.ExerciseFeedback?.OfType<BriefExerciseFeedback>().Take(MaxExerciseFeedback)
                .Select(f => f with { ExerciseId = Short(f.ExerciseId, 64), Kind = Short(f.Kind, 16), Note = Short(f.Note, 300), Date = Short(f.Date, 10) })
                .ToList<BriefExerciseFeedback?>(),
            Program = brief.Program is { } prog
                ? prog with
                {
                    Phase = Short(prog.Phase, 40), DeloadReason = Short(prog.DeloadReason, 200), Variant = Short(prog.Variant, 16),
                    VariantFocus = Short(prog.VariantFocus, 200),
                }
                : null,
            Balance = brief.Balance is { } b
                ? new BriefBalance
                {
                    Muscles = b.Muscles?.OfType<BriefMuscle>().Take(MaxBalanceMuscles)
                        .Select(m => m with { Muscle = Short(m.Muscle, 32), Status = Short(m.Status, 16), Trend = Short(m.Trend, 16) }).ToList<BriefMuscle?>(),
                    Priorities = b.Priorities?.OfType<BriefPriority>().Take(MaxPriorities)
                        .Select(x => x with { Muscle = Short(x.Muscle, 32), Reason = Short(x.Reason, 200) }).ToList<BriefPriority?>(),
                    Ratios = b.Ratios,
                    Notes = b.Notes?.OfType<string>().Take(MaxNotes).Select(n => Short(n, 200)).ToList(),
                }
                : null,
            ExerciseHistory = brief.ExerciseHistory?.OfType<BriefExerciseHistory>().Take(MaxExerciseHistory)
                .Select(h => h with
                {
                    ExerciseId = Short(h.ExerciseId, 64), Trend = Short(h.Trend, 16), LastPerformed = Short(h.LastPerformed, 10),
                    BarKg = h.BarKg is { } bar ? Math.Clamp(bar, 0, 60) : null,
                    Exposures = h.Exposures?.OfType<BriefExposure>().Take(MaxExposures)
                        .Select(x => x with { Date = Short(x.Date, 10), Sets = Short(x.Sets, 200) }).ToList<BriefExposure?>(),
                }).ToList<BriefExerciseHistory?>(),
            RecentSessions = brief.RecentSessions?.OfType<BriefSession>().Take(MaxRecentSessions)
                .Select(s => s with
                {
                    Date = Short(s.Date, 10), DayType = Short(s.DayType, 16), Title = Short(s.Title, 100), Notes = Short(s.Notes, MaxNote),
                    Exercises = Ids(s.Exercises, MaxSessionExercises),
                }).ToList<BriefSession?>(),
            Weekly = brief.Weekly?.OfType<BriefWeek>().Take(MaxWeekly).Select(w => w with { WeekStart = Short(w.WeekStart, 10) }).ToList<BriefWeek?>(),
        };
    }

    public static DateOnly? ParseDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var s = value.Trim();
        if (s.Length > 10) s = s[..10];
        return DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;
    }

    public static string Experience(this CoachBrief brief) =>
        brief.Profile?.Experience is { } e && Vocab.Experiences.Contains(e) ? e : Vocab.Experience.Beginner;

    public static bool IsDeload(this CoachBrief brief) => brief.Program?.Deload == true;

    /// <summary>Active pain / discomfort entries of the brief as domain limitations.</summary>
    public static IEnumerable<Limitation> ToLimitations(this CoachBrief brief) =>
        (brief.Limitations ?? []).OfType<BriefLimitation>()
            .Where(l => l.Kind is not null)
            .Select(l => new Limitation(
                l.Kind!, l.Region, l.Severity is { } s && double.IsFinite(s) ? (int)Math.Round(s) : null, l.ExerciseId, ParseDate(l.Since)));

    /// <summary>
    /// Equipment availability, occupied equipment, preferences (banned &gt; disliked &gt; liked), difficulty and limitations
    /// from the brief. <paramref name="extraLimitations"/> / <paramref name="extraUnavailable"/> add newly reported issues.
    /// </summary>
    public static SelectionContext ToSelectionContext(
        this CoachBrief brief,
        CatalogService catalog,
        DateOnly today,
        IEnumerable<string>? extraOccupied = null,
        IEnumerable<Limitation>? extraLimitations = null,
        IEnumerable<string>? extraUnavailable = null)
    {
        var availability = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var id in (brief.Equipment?.Unavailable ?? []).Concat(extraUnavailable ?? []))
        {
            if (id is not null) availability[id] = false;
        }

        var preferences = new Dictionary<string, string>(StringComparer.Ordinal);
        void Mark(IEnumerable<string?>? ids, string preference)
        {
            foreach (var id in ids ?? [])
                if (id is not null) preferences[id] = preference;
        }
        Mark(brief.Preferences?.Liked, Vocab.Preference.Liked);
        Mark(brief.Preferences?.Disliked, Vocab.Preference.Disliked);
        Mark(brief.Preferences?.Banned, Vocab.Preference.Banned);

        var occupied = (brief.Equipment?.Occupied ?? []).OfType<string>().Concat(extraOccupied ?? []);
        var limitations = new LimitationFilter(brief.ToLimitations().Concat(extraLimitations ?? []), today);
        return SelectionContext.Create(catalog, brief.Experience(), availability, occupied, preferences, limitations);
    }

    /// <summary>"Block 2 · Week 3 · Push B" (or null when the brief has no program state).</summary>
    public static string? ProgramLabel(this CoachBrief brief, string dayType)
    {
        if (brief.Program is not { } p || p.BlockNumber is null) return null;
        var day = dayType.Length > 0 ? char.ToUpperInvariant(dayType[0]) + dayType[1..] : dayType;
        var parts = new List<string> { $"Block {p.BlockNumber:0}" };
        if (p.BlockWeek is { } w) parts.Add($"Week {w:0}");
        parts.Add(string.IsNullOrWhiteSpace(p.Variant) ? day : $"{day} {p.Variant}");
        if (p.Deload == true) parts.Add("Deload");
        return string.Join(" · ", parts);
    }

    public static bool HasTrainingData(this CoachBrief brief) =>
        (brief.RecentSessions?.Count ?? 0) > 0
        || (brief.Weekly ?? []).Any(w => w?.Sessions > 0)
        || brief.Program?.CompletedSessions > 0;

    /// <summary>Tracked muscles in <c>balance.priorities</c>, minus muscles avoided because of severe pain.</summary>
    public static IReadOnlyList<string> PriorityMuscles(this CoachBrief brief, LimitationFilter limits) =>
        (brief.Balance?.Priorities ?? []).Select(p => p?.Muscle)
            .Where(m => Anatomy.IsTrackedMuscle(m) && !limits.AvoidedMuscles.Contains(m!))
            .Select(m => m!)
            .Distinct(StringComparer.Ordinal)
            .ToList();

    private static string? Short(string? value, int max)
    {
        if (value is null) return null;
        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max];
    }

    private static List<string?>? Ids(List<string?>? ids, int max = MaxIdList) =>
        ids?.OfType<string>().Select(i => i.Trim()).Where(i => i.Length is > 0 and <= 64).Distinct(StringComparer.Ordinal).Take(max)
            .Select(i => (string?)i).ToList();
}
