using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using WFit.Api.Infrastructure;

namespace WFit.Api.Functions;

public sealed record HealthResponse(string Status, string Version);

/// <summary>Anonymous liveness probe. Deliberately has no DB dependency so it never wakes serverless SQL.</summary>
public sealed class HealthFunction
{
    public const string Name = "Health";
    public const string ApiVersion = "3.0.0";

    [Function(Name)]
    public IActionResult Run([HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequest req) =>
        new JsonResponse(new HealthResponse("ok", ApiVersion));
}
