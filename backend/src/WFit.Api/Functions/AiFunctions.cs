using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using WFit.Api.Ai;
using WFit.Api.Infrastructure;

namespace WFit.Api.Functions;

/// <summary>Stateless AI endpoints: the coach brief travels in the request; nothing here touches SQL.</summary>
public sealed class AiFunctions(
    WorkoutAiService workouts,
    AdjustAiService adjustments,
    SwapAiService swaps,
    InsightsService insights,
    AiGateway gateway)
{
    public const int MaxRequestBytes = CoachBriefRules.MaxRequestBytes;

    [Function("AiWorkout")]
    public async Task<IActionResult> Workout(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/workout")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<AiWorkoutRequest>(req, required: true, ct, MaxRequestBytes);
        return new JsonResponse(await workouts.GenerateAsync(request!, ct));
    }

    [Function("AiAdjust")]
    public async Task<IActionResult> Adjust(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/adjust")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<AdjustRequest>(req, required: true, ct, MaxRequestBytes);
        return new JsonResponse(await adjustments.AdjustAsync(request!, ct));
    }

    [Function("AiSwap")]
    public async Task<IActionResult> Swap(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/swap")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<SwapRequest>(req, required: true, ct, MaxRequestBytes);
        return new JsonResponse(await swaps.SuggestAsync(request!, ct));
    }

    [Function("AiInsights")]
    public async Task<IActionResult> Insights(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "ai/insights")] HttpRequest req)
    {
        var ct = req.HttpContext.RequestAborted;
        var request = await RequestReader.ReadAsync<InsightsRequest>(req, required: false, ct, MaxRequestBytes) ?? new InsightsRequest();
        return new JsonResponse(await insights.GetAsync(request, ct));
    }

    [Function("AiUsage")]
    public async Task<IActionResult> Usage(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "ai/usage")] HttpRequest req) =>
        new JsonResponse(await gateway.GetUsageAsync(req.HttpContext.RequestAborted));
}
