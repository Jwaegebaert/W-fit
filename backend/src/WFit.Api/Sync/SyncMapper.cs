using System.Text.Json;
using WFit.Api.Data;
using WFit.Api.Infrastructure;

namespace WFit.Api.Sync;

/// <summary>Entity ⇄ DTO conversions for synced records.</summary>
public static class SyncMapper
{
    public static string Trunc(string? value, int max) =>
        string.IsNullOrEmpty(value) ? "" : value.Length <= max ? value : value[..max];

    /// <summary>Returns the canonical lower-case GUID string, or null when the value isn't a GUID.</summary>
    public static string? NormalizeGuid(string? value) =>
        Guid.TryParse(value, out var g) ? g.ToString("D") : null;

    public static string SerializeBlocks(IEnumerable<WorkoutBlockDto> blocks) =>
        JsonSerializer.Serialize(blocks, JsonDefaults.Options);

    public static List<WorkoutBlockDto> DeserializeBlocks(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<WorkoutBlockDto>>(json, JsonDefaults.Options) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static ProfileDto ToDto(this Profile e) => new()
    {
        Id = e.Id, Name = e.Name, Experience = e.Experience, Goals = e.Goals, TrainingDays = [.. e.TrainingDays],
        SessionMinutes = e.SessionMinutes, IncludeCore = e.IncludeCore, HeightCm = e.HeightCm, BirthYear = e.BirthYear,
        Injuries = e.Injuries, Notes = e.Notes, RestMode = e.RestMode, CooldownStretches = e.CooldownStretches,
        BarWeights = ParseBarWeights(e.BarWeightsJson), MuscleFocus = ParseMuscleFocus(e.MuscleFocusJson),
        UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static EquipmentStatusDto ToDto(this EquipmentStatus e) => new()
    {
        EquipmentId = e.EquipmentId, Available = e.Available, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static ExercisePreferenceDto ToDto(this ExercisePreference e) => new()
    {
        ExerciseId = e.ExerciseId, Preference = e.Preference, Note = e.Note, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static PlannedWorkoutDto ToDto(this PlannedWorkout e) => new()
    {
        Id = e.Id, Date = e.Date, DayType = e.DayType, Title = e.Title, Source = e.Source, Status = e.Status,
        EstimatedMinutes = e.EstimatedMinutes, CoachNote = e.CoachNote, Blocks = DeserializeBlocks(e.BlocksJson),
        MetaJson = string.IsNullOrWhiteSpace(e.MetaJson) ? EmptyMeta : e.MetaJson, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static FeedbackEntryDto ToDto(this FeedbackEntry e) => new()
    {
        Id = e.Id, CreatedAt = e.CreatedAt, Kind = e.Kind, Region = e.Region, Severity = e.Severity, ExerciseId = e.ExerciseId,
        SessionId = e.SessionId, Note = e.Note, Status = e.Status, ReviewOn = e.ReviewOn, ResolvedAt = e.ResolvedAt,
        Source = e.Source, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static WorkoutSessionDto ToDto(this WorkoutSession e) => new()
    {
        Id = e.Id, PlannedWorkoutId = e.PlannedWorkoutId, DayType = e.DayType, Title = e.Title, StartedAt = e.StartedAt,
        EndedAt = e.EndedAt, DurationSeconds = e.DurationSeconds, Rating = e.Rating, PerceivedEffort = e.PerceivedEffort,
        Notes = e.Notes, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static SetLogDto ToDto(this SetLog e) => new()
    {
        Id = e.Id, SessionId = e.SessionId, ExerciseId = e.ExerciseId, Section = e.Section, ExerciseOrder = e.ExerciseOrder,
        SetNumber = e.SetNumber, WeightKg = e.WeightKg, Reps = e.Reps, DurationSeconds = e.DurationSeconds, Rir = e.Rir,
        Completed = e.Completed, CompletedAt = e.CompletedAt, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static BodyMetricDto ToDto(this BodyMetric e) => new()
    {
        Id = e.Id, Date = e.Date, WeightKg = e.WeightKg, BodyFatPct = e.BodyFatPct, WaistCm = e.WaistCm, ChestCm = e.ChestCm,
        ArmCm = e.ArmCm, ThighCm = e.ThighCm, HipsCm = e.HipsCm, Notes = e.Notes, UpdatedAt = e.UpdatedAt, Deleted = e.Deleted,
    };

    public static void Apply(this Profile e, ProfileDto d)
    {
        e.Name = Trunc(d.Name, Len.Name);
        e.Experience = d.Experience;
        e.Goals = Trunc(d.Goals, Len.Goals);
        e.TrainingDays = (d.TrainingDays ?? []).Where(x => x is >= 1 and <= 7).Distinct().Order().ToList();
        e.SessionMinutes = Math.Clamp(d.SessionMinutes, 10, 240);
        e.IncludeCore = d.IncludeCore;
        e.HeightCm = d.HeightCm;
        e.BirthYear = d.BirthYear;
        e.Injuries = Trunc(d.Injuries, Len.Text);
        e.Notes = Trunc(d.Notes, Len.Text);
        e.RestMode = d.RestMode is "short" or "long" ? d.RestMode : "normal";
        e.CooldownStretches = Math.Clamp(d.CooldownStretches, 0, 3);
        e.BarWeightsJson = JsonSerializer.Serialize(CleanBarWeights(d.BarWeights), JsonDefaults.Options);
        e.MuscleFocusJson = JsonSerializer.Serialize(CleanMuscleFocus(d.MuscleFocus), JsonDefaults.Options);
    }

    /// <summary>Tracked muscles only; a muscle is either less or more (more wins), light is independent.</summary>
    public static MuscleFocusDto CleanMuscleFocus(MuscleFocusDto? f)
    {
        List<string> clean(List<string>? ids) => (ids ?? []).Where(Domain.Anatomy.TrackedMuscleIds.Contains).Distinct().Order().ToList();
        var more = clean(f?.More);
        return new MuscleFocusDto { Less = clean(f?.Less).Except(more).ToList(), More = more, Light = clean(f?.Light) };
    }

    public static MuscleFocusDto ParseMuscleFocus(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new MuscleFocusDto();
        try
        {
            return CleanMuscleFocus(JsonSerializer.Deserialize<MuscleFocusDto>(json, JsonDefaults.Options));
        }
        catch (JsonException)
        {
            return new MuscleFocusDto();
        }
    }

    /// <summary>Bar weights keyed by equipment id (max 10 entries, 0-60 kg).</summary>
    public static Dictionary<string, double> CleanBarWeights(Dictionary<string, double>? weights) =>
        (weights ?? []).Where(kv => kv.Key.Length is > 0 and <= 40 && kv.Value is >= 0 and <= 60)
            .Take(10).ToDictionary(kv => kv.Key, kv => kv.Value);

    public static Dictionary<string, double> ParseBarWeights(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            return CleanBarWeights(JsonSerializer.Deserialize<Dictionary<string, double>>(json, JsonDefaults.Options));
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static void Apply(this EquipmentStatus e, EquipmentStatusDto d) => e.Available = d.Available;

    public static void Apply(this ExercisePreference e, ExercisePreferenceDto d)
    {
        e.Preference = d.Preference;
        e.Note = Trunc(d.Note, Len.Text);
    }

    public static void Apply(this PlannedWorkout e, PlannedWorkoutDto d)
    {
        e.Date = d.Date;
        e.DayType = d.DayType;
        e.Title = Trunc(d.Title, Len.Title);
        e.Source = d.Source;
        e.Status = d.Status;
        e.EstimatedMinutes = Math.Clamp(d.EstimatedMinutes, 0, 600);
        e.CoachNote = Trunc(d.CoachNote, Len.Text);
        e.BlocksJson = SerializeBlocks((d.Blocks ?? []).Select(b => b with
        {
            Items = (b.Items ?? []).Select(i => i with { Notes = i.Notes ?? "" }).ToList(),
        }));
        e.MetaJson = NormalizeMetaJson(d.MetaJson);
    }

    public const string EmptyMeta = "{}";

    /// <summary>A JSON object of at most <see cref="Len.Meta"/> chars; anything else (null, invalid, too long) becomes <c>{}</c>.</summary>
    public static string NormalizeMetaJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json) || json.Length > Len.Meta) return EmptyMeta;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == JsonValueKind.Object ? json : EmptyMeta;
        }
        catch (JsonException)
        {
            return EmptyMeta;
        }
    }

    public static void Apply(this FeedbackEntry e, FeedbackEntryDto d, string? sessionId)
    {
        e.CreatedAt = d.CreatedAt ?? d.UpdatedAt;
        e.Kind = d.Kind;
        e.Region = d.Region;
        e.Severity = d.Severity;
        e.ExerciseId = d.ExerciseId;
        e.SessionId = sessionId;
        e.Note = Trunc(d.Note, Len.Text);
        e.Status = d.Status;
        e.ReviewOn = d.ReviewOn;
        e.ResolvedAt = d.ResolvedAt;
        e.Source = d.Source;
    }

    public static void Apply(this WorkoutSession e, WorkoutSessionDto d, string? plannedWorkoutId)
    {
        e.PlannedWorkoutId = plannedWorkoutId;
        e.DayType = d.DayType;
        e.Title = Trunc(d.Title, Len.Title);
        e.StartedAt = d.StartedAt;
        e.EndedAt = d.EndedAt;
        e.DurationSeconds = d.DurationSeconds;
        e.Rating = d.Rating;
        e.PerceivedEffort = d.PerceivedEffort;
        e.Notes = Trunc(d.Notes, Len.Text);
    }

    public static void Apply(this SetLog e, SetLogDto d, string sessionId)
    {
        e.SessionId = sessionId;
        e.ExerciseId = d.ExerciseId;
        e.Section = d.Section;
        e.ExerciseOrder = d.ExerciseOrder;
        e.SetNumber = d.SetNumber;
        e.WeightKg = d.WeightKg;
        e.Reps = d.Reps;
        e.DurationSeconds = d.DurationSeconds;
        e.Rir = d.Rir;
        e.Completed = d.Completed;
        e.CompletedAt = d.CompletedAt;
    }

    public static void Apply(this BodyMetric e, BodyMetricDto d)
    {
        e.Date = d.Date;
        e.WeightKg = d.WeightKg;
        e.BodyFatPct = d.BodyFatPct;
        e.WaistCm = d.WaistCm;
        e.ChestCm = d.ChestCm;
        e.ArmCm = d.ArmCm;
        e.ThighCm = d.ThighCm;
        e.HipsCm = d.HipsCm;
        e.Notes = Trunc(d.Notes, Len.Text);
    }
}
