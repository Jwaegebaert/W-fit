using System.Globalization;

namespace WFit.Api.Domain;

/// <summary>An active pain / discomfort report (from the coach brief's <c>limitations</c> or new AI feedback).</summary>
public sealed record Limitation(string Kind, string? Region, int? Severity, string? ExerciseId, DateOnly? Since = null);

public enum LimitationEffect { None, Penalised, Excluded }

public sealed record LimitationVerdict(LimitationEffect Effect, int Penalty, string? Reason, IReadOnlyList<string> CautionRegions)
{
    public static readonly LimitationVerdict Clear = new(LimitationEffect.None, 0, null, []);
}

/// <summary>
/// Server-side mirror of the app's <c>LimitationPolicy</c> (IMPROVEMENT-PLAN §4.3), applied to every AI candidate list:
/// region severity 1 ⇒ exercises stressing the region are penalised (allowed only if nothing else fits);
/// severity 2 ⇒ excluded; severity 3 ⇒ excluded plus direct work (primary muscles) for the region's related muscles.
/// Exercise-specific pain ⇒ excluded; exercise-specific discomfort ⇒ excluded for 4 weeks, then penalised.
/// </summary>
public sealed class LimitationFilter
{
    /// <summary>Same values as the app's <c>LimitationPolicy</c> (larger than any other swap score component).</summary>
    public const int MildRegionPenalty = 20;
    public const int OldDiscomfortPenalty = 6;
    public const int ExerciseDiscomfortExclusionDays = 28;

    public static readonly LimitationFilter None = new([], default);

    private readonly Dictionary<string, (int Severity, string Kind)> _regions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<Limitation>> _byExercise = new(StringComparer.Ordinal);
    private readonly DateOnly _today;

    public LimitationFilter(IEnumerable<Limitation> limitations, DateOnly today)
    {
        _today = today;
        var active = new List<Limitation>();
        foreach (var raw in limitations)
        {
            if (Normalize(raw) is not { } l) continue;
            active.Add(l);
            if (l.Region is { } region)
            {
                if (!_regions.TryGetValue(region, out var current) || l.Severity > current.Severity
                    || (l.Severity == current.Severity && l.Kind == Vocab.FeedbackKind.Pain))
                    _regions[region] = (l.Severity!.Value, l.Kind);
            }
            if (l.ExerciseId is { } id)
            {
                if (!_byExercise.TryGetValue(id, out var list)) _byExercise[id] = list = [];
                list.Add(l);
            }
        }
        Active = active;
        AvoidedMuscles = new HashSet<string>(
            _regions.Where(r => r.Value.Severity >= 3).SelectMany(r => Anatomy.RelatedMusclesOf(r.Key)),
            StringComparer.Ordinal);
    }

    /// <summary>Valid, normalised pain / discomfort entries.</summary>
    public IReadOnlyList<Limitation> Active { get; }

    public bool IsEmpty => Active.Count == 0;

    /// <summary>Highest reported severity per region.</summary>
    public IReadOnlyDictionary<string, int> RegionSeverity => _regions.ToDictionary(r => r.Key, r => r.Value.Severity, StringComparer.Ordinal);

    /// <summary>Muscles whose direct training is avoided (related muscles of severely painful regions).</summary>
    public IReadOnlySet<string> AvoidedMuscles { get; }

    /// <summary>Pain / discomfort only; default severity pain → 2 (moderate), discomfort → 1 (mild).</summary>
    public static Limitation? Normalize(Limitation l)
    {
        var kind = l.Kind?.Trim().ToLowerInvariant();
        if (!Vocab.FeedbackKind.IsPainLike(kind)) return null;
        var region = Anatomy.IsRegion(l.Region) ? l.Region : null;
        var exerciseId = string.IsNullOrWhiteSpace(l.ExerciseId) ? null : l.ExerciseId.Trim();
        if (region is null && exerciseId is null) return null;
        var severity = Math.Clamp(l.Severity ?? (kind == Vocab.FeedbackKind.Pain ? 2 : 1), 1, 3);
        return new Limitation(kind!, region, severity, exerciseId, l.Since);
    }

    public LimitationVerdict Evaluate(CatalogExerciseItem exercise)
    {
        if (IsEmpty) return LimitationVerdict.Clear;

        if (_byExercise.TryGetValue(exercise.Id, out var entries))
        {
            if (entries.Any(e => e.Kind == Vocab.FeedbackKind.Pain))
                return Excluded("pain reported on this exercise");
            if (entries.Any(e => e.Since is not { } since || _today.DayNumber - since.DayNumber < ExerciseDiscomfortExclusionDays))
                return Excluded("discomfort reported on this exercise");
        }

        var stress = exercise.Stress ?? [];
        var penalty = 0;
        var caution = new List<string>();
        foreach (var (region, (severity, kind)) in _regions)
        {
            if (severity >= 2 && stress.Contains(region))
                return Excluded($"{Describe(region, kind, severity)}: loads the {Pretty(region)}");
            if (severity >= 3 && exercise.Primary.FirstOrDefault(Anatomy.RelatedMusclesOf(region).Contains) is { } muscle)
                return Excluded($"{Describe(region, kind, severity)}: direct {Pretty(muscle)} work");
            if (severity == 1 && stress.Contains(region))
            {
                penalty += MildRegionPenalty;
                caution.Add(region);
            }
        }

        if (entries is not null) penalty += OldDiscomfortPenalty;

        if (penalty == 0) return LimitationVerdict.Clear;
        var reason = caution.Count > 0
            ? string.Join("; ", caution.Select(r => $"{Describe(r, _regions[r].Kind, 1)}: loads the {Pretty(r)}"))
            : "earlier discomfort on this exercise";
        return new LimitationVerdict(LimitationEffect.Penalised, penalty, reason, caution);
    }

    public bool Excludes(CatalogExerciseItem exercise) => Evaluate(exercise).Effect == LimitationEffect.Excluded;

    public int Penalty(CatalogExerciseItem exercise) => Evaluate(exercise).Penalty;

    public static string SeverityLabel(int severity) => severity switch
    {
        <= 1 => "mild",
        2 => "moderate",
        _ => "severe",
    };

    private static string Describe(string region, string kind, int severity) =>
        $"{SeverityLabel(severity)} {Pretty(region)} {kind}";

    private static string Pretty(string id) => id.Replace('_', ' ');

    private static LimitationVerdict Excluded(string reason) => new(LimitationEffect.Excluded, 0, reason, []);

    public override string ToString() =>
        string.Join(", ", Active.Select(a => string.Create(CultureInfo.InvariantCulture,
            $"{a.Kind}:{a.Region ?? "-"}:{a.Severity}:{a.ExerciseId ?? "-"}")));
}
