using System.Text.Json;

namespace WFit.Api.Domain;

public sealed record CatalogEquipmentItem(
    string Id, string Name, string Group, bool AlwaysAvailable, string? Description = null, double? BarWeightKg = null);

public sealed record CatalogExerciseItem(
    string Id,
    string Name,
    string Category,
    IReadOnlyList<string> Splits,
    IReadOnlyList<string> Primary,
    IReadOnlyList<string> Secondary,
    string Pattern,
    IReadOnlyList<string> Equipment,
    int Difficulty,
    bool Compound,
    bool Unilateral,
    string Measure,
    int Sets,
    int? RepMin,
    int? RepMax,
    int? DurationSeconds,
    int Rest,
    double IncrementKg,
    string? Badminton,
    IReadOnlyList<string> Instructions,
    string? Tip,
    IReadOnlyList<string>? Mistakes = null,
    IReadOnlyList<string>? Stress = null,
    string? Load = null,
    string? Bar = null)
{
    public const string FloorEquipmentId = "mat";

    /// <summary>weight | optional | assist | none (no kg is logged).</summary>
    public string LoadType => Load ?? (IncrementKg > 0 ? "weight" : "none");

    public bool IsAssisted => LoadType == "assist";

    public bool IsTimed => Measure == Vocab.Measure.Time;

    /// <summary>Lying, kneeling or sitting on the floor (equipment "mat").</summary>
    public bool IsFloor => Equipment.Contains(FloorEquipmentId);
}

/// <summary>Loads the exercise/equipment catalog embedded from app/assets/data/catalog.json.</summary>
public sealed class CatalogService
{
    public const string ResourceName = "catalog.json";
    public const string BodyweightId = "bodyweight";

    private static readonly JsonSerializerOptions ReadOptions = new() { PropertyNameCaseInsensitive = true };

    public CatalogService() : this(EmbeddedJson()) { }

    public CatalogService(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Version = root.GetProperty("version").ToString();
        Equipment = root.GetProperty("equipment").Deserialize<List<CatalogEquipmentItem>>(ReadOptions) ?? [];
        Exercises = root.GetProperty("exercises").Deserialize<List<CatalogExerciseItem>>(ReadOptions) ?? [];
        ExercisesById = Exercises.ToDictionary(e => e.Id, StringComparer.Ordinal);
        EquipmentById = Equipment.ToDictionary(e => e.Id, StringComparer.Ordinal);
    }

    public string Version { get; }
    public IReadOnlyList<CatalogEquipmentItem> Equipment { get; }
    public IReadOnlyList<CatalogExerciseItem> Exercises { get; }
    public IReadOnlyDictionary<string, CatalogExerciseItem> ExercisesById { get; }
    public IReadOnlyDictionary<string, CatalogEquipmentItem> EquipmentById { get; }

    public CatalogExerciseItem? FindExercise(string? id) =>
        id is not null && ExercisesById.TryGetValue(id, out var e) ? e : null;

    public bool IsAlwaysAvailable(string equipmentId) =>
        equipmentId == BodyweightId || (EquipmentById.TryGetValue(equipmentId, out var eq) && eq.AlwaysAvailable);

    internal static string EmbeddedJson()
    {
        using var stream = typeof(CatalogService).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{ResourceName}' not found.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
