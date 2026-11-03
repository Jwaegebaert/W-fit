using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using WFit.Api.Ai;
using WFit.Api.Infrastructure;

namespace WFit.Api.Functions;

public sealed class AiFunctions(
    WorkoutAiService workouts,
    SwapAiService swaps,
    InsightsService insights,
    AiUsageService usage)
{
    [Function("AiWorkout")]
    public async Task<IActionResult> Workout(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/workout")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<AiWorkoutRequest>(req, required: true, ct);
        return new JsonResponse(await workouts.GenerateAsync(request!, ct));
    }

    [Function("AiSwap")]
    public async Task<IActionResult> Swap(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/swap")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<SwapRequest>(req, required: true, ct);
        return new JsonResponse(await swaps.SuggestAsync(request!, ct));
    }

    [Function("AiInsights")]
    public async Task<IActionResult> Insights(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/insights")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<InsightsRequest>(req, required: false, ct) ?? new InsightsRequest();
        return new JsonResponse(await insights.GetAsync(request, ct));
    }

    [Function("AiUsage")]
    public async Task<IActionResult> Usage(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "ai/usage")] HttpRequest req) =>
        new JsonResponse(await usage.GetUsageAsync(req.HttpContext.RequestAborted));
}
