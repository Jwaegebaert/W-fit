using System.Text.Json.Nodes;
using WFit.Api.Domain;

namespace WFit.Api.Ai;

/// <summary>Strict JSON schemas for structured outputs (all properties required, no additional properties).</summary>
public static class AiSchemas
{
    public static string Workout(IEnumerable<string> candidateIds) => WorkoutObject(candidateIds).ToJsonString();

    public static string Adjust(IEnumerable<string>? planCandidateIds)
    {
        var ids = planCandidateIds?.Distinct().ToList() ?? [];
        var feedback = Obj(new()
        {
            ["kind"] = Enum([.. Vocab.FeedbackKinds.Order(StringComparer.Ordinal)]),
            ["region"] = NullableEnum([.. Anatomy.Regions]),
            ["severity"] = Nullable("integer"),
            ["exerciseId"] = Nullable("string"),
            ["equipmentId"] = Nullable("string"),
            ["note"] = Type("string"),
            ["reviewInDays"] = Nullable("integer"),
        });
        // Without a plan in the request the model can't return one.
        JsonNode plan = ids.Count == 0
            ? Type("null")
            : new JsonObject { ["anyOf"] = new JsonArray(WorkoutObject(ids), Type("null")) };
        return Obj(new()
        {
            ["reply"] = Type("string"),
            ["feedback"] = ArrayOf(feedback),
            ["plan"] = plan,
        }).ToJsonString();
    }

    public static string Swap(IEnumerable<string> candidateIds)
    {
        var suggestion = Obj(new()
        {
            ["exerciseId"] = Enum([.. candidateIds.Distinct()]),
            ["why"] = Type("string"),
            ["sets"] = Type("integer"),
            ["repMin"] = Nullable("integer"),
            ["repMax"] = Nullable("integer"),
            ["restSeconds"] = Type("integer"),
        });
        return Obj(new() { ["suggestions"] = ArrayOf(suggestion) }).ToJsonString();
    }

    public static string Insights() => Obj(new()
    {
        ["summary"] = Type("string"),
        ["highlights"] = ArrayOf(Type("string")),
        ["recommendations"] = ArrayOf(Type("string")),
        ["nextFocus"] = Type("string"),
        ["focusMuscles"] = ArrayOf(Enum([.. Anatomy.TrackedMuscles.Select(m => m.Id)])),
    }).ToJsonString();

    private static JsonObject WorkoutObject(IEnumerable<string> candidateIds)
    {
        var item = Obj(new()
        {
            ["exerciseId"] = Enum([.. candidateIds.Distinct()]),
            ["sets"] = Type("integer"),
            ["repMin"] = Nullable("integer"),
            ["repMax"] = Nullable("integer"),
            ["durationSeconds"] = Nullable("integer"),
            ["restSeconds"] = Type("integer"),
            ["targetWeightKg"] = Nullable("number"),
            ["notes"] = Type("string"),
        });
        var block = Obj(new()
        {
            ["section"] = Enum("warmup", "main", "core", "cooldown"),
            ["items"] = ArrayOf(item),
        });
        var change = Obj(new()
        {
            ["from"] = Type("string"),
            ["to"] = Type("string"),
            ["reason"] = Type("string"),
        });
        return Obj(new()
        {
            ["title"] = Type("string"),
            ["coachNote"] = Type("string"),
            ["estimatedMinutes"] = Type("integer"),
            ["blocks"] = ArrayOf(block),
            ["focus"] = ArrayOf(Enum([.. Anatomy.TrackedMuscles.Select(m => m.Id)])),
            ["rationale"] = ArrayOf(Type("string")),
            ["changes"] = ArrayOf(change),
        });
    }

    private static JsonObject Obj(Dictionary<string, JsonNode> properties)
    {
        var props = new JsonObject();
        var required = new JsonArray();
        foreach (var (name, schema) in properties)
        {
            props[name] = schema;
            required.Add(name);
        }
        return new JsonObject
        {
            ["type"] = "object",
            ["properties"] = props,
            ["required"] = required,
            ["additionalProperties"] = false,
        };
    }

    private static JsonObject Type(string type) => new() { ["type"] = type };

    private static JsonObject Nullable(string type) => new() { ["type"] = Array(type, "null") };

    private static JsonObject ArrayOf(JsonNode items) => new() { ["type"] = "array", ["items"] = items };

    private static JsonObject Enum(params string[] values) => new() { ["type"] = "string", ["enum"] = Array(values) };

    private static JsonObject NullableEnum(params string[] values) =>
        new() { ["anyOf"] = new JsonArray(Enum(values), Type("null")) };

    private static JsonArray Array(params string[] values) => new([.. values.Select(v => (JsonNode)JsonValue.Create(v))]);
}
