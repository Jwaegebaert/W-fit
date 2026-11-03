using System.Text.Json.Nodes;

namespace WFit.Api.Ai;

/// <summary>Strict JSON schemas for structured outputs (all properties required, no additional properties).</summary>
public static class AiSchemas
{
    public static string Workout(IEnumerable<string> candidateIds)
    {
        var item = Obj(new()
        {
            ["exerciseId"] = IdEnum(candidateIds),
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
            ["section"] = new JsonObject { ["type"] = "string", ["enum"] = Array("warmup", "main", "core", "cooldown") },
            ["items"] = ArrayOf(item),
        });
        return Obj(new()
        {
            ["title"] = Type("string"),
            ["coachNote"] = Type("string"),
            ["estimatedMinutes"] = Type("integer"),
            ["blocks"] = ArrayOf(block),
        }).ToJsonString();
    }

    public static string Swap(IEnumerable<string> candidateIds)
    {
        var suggestion = Obj(new()
        {
            ["exerciseId"] = IdEnum(candidateIds),
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
    }).ToJsonString();

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

    private static JsonObject IdEnum(IEnumerable<string> ids) => new() { ["type"] = "string", ["enum"] = Array([.. ids.Distinct()]) };

    private static JsonArray Array(params string[] values) => new([.. values.Select(v => (JsonNode)JsonValue.Create(v))]);
}
