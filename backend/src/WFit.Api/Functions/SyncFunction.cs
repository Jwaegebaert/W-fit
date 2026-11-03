using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

namespace WFit.Api.Functions;

public sealed class SyncFunction(SyncService sync)
{
    [Function("Sync")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "sync")] HttpRequest req)
    {
        var request = await RequestReader.ReadAsync<SyncRequest>(req, required: true, req.HttpContext.RequestAborted);
        return new JsonResponse(await sync.SyncAsync(request!, req.HttpContext.RequestAborted));
    }
}
