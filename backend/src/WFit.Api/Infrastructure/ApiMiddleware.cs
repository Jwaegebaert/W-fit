using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using WFit.Api.Data;
using WFit.Api.Functions;

namespace WFit.Api.Infrastructure;

public static class ApiKeyValidator
{
    public const string HeaderName = "X-Api-Key";
    public const string SettingName = "WFIT_API_KEY";

    /// <summary>Constant-time comparison. Fails closed when no key is configured.</summary>
    public static bool IsValid(string? provided, string? expected)
    {
        if (string.IsNullOrEmpty(expected) || string.IsNullOrEmpty(provided)) return false;
        // Hash both sides so the comparison length does not depend on the input.
        var a = SHA256.HashData(Encoding.UTF8.GetBytes(provided));
        var b = SHA256.HashData(Encoding.UTF8.GetBytes(expected));
        return CryptographicOperations.FixedTimeEquals(a, b);
    }
}

/// <summary>
/// API-key enforcement (everything except <c>health</c>), lazy database initialization (only for functions that use
/// SQL, so the stateless AI endpoints never wait for a paused database) and mapping of exceptions to the contract
/// error shape.
/// </summary>
public sealed class ApiMiddleware(IConfiguration configuration, ILogger<ApiMiddleware> logger) : IFunctionsWorkerMiddleware
{
    /// <summary>Functions that need the database (migrations + catalog seed are applied before they run).</summary>
    public static readonly IReadOnlySet<string> DatabaseFunctions = new HashSet<string>(StringComparer.Ordinal) { SyncFunction.Name };

    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        var http = context.GetHttpContext();
        if (http is null)
        {
            await next(context);
            return;
        }

        try
        {
            if (context.FunctionDefinition.Name != HealthFunction.Name)
            {
                if (!ApiKeyValidator.IsValid(http.Request.Headers[ApiKeyValidator.HeaderName], configuration[ApiKeyValidator.SettingName]))
                {
                    await JsonResponse.WriteErrorAsync(http.Response, StatusCodes.Status401Unauthorized,
                        ErrorCodes.Unauthorized, "Missing or invalid API key.");
                    return;
                }
            }

            if (DatabaseFunctions.Contains(context.FunctionDefinition.Name))
            {
                var initializer = context.InstanceServices.GetRequiredService<DatabaseInitializer>();
                var db = context.InstanceServices.GetRequiredService<WFitDbContext>();
                await initializer.EnsureInitializedAsync(db, http.RequestAborted);
            }

            await next(context);
        }
        catch (ApiException ex)
        {
            if (ex.InnerException is not null)
                logger.LogWarning(ex.InnerException, "{Function} failed with {Error}.", context.FunctionDefinition.Name, ex.Error);
            await TryWriteErrorAsync(http, ex.StatusCode, ex.Error, ex.Message);
        }
        catch (OperationCanceledException) when (http.RequestAborted.IsCancellationRequested)
        {
            // Client went away; nothing to write.
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Unhandled error in {Function}.", context.FunctionDefinition.Name);
            await TryWriteErrorAsync(http, StatusCodes.Status500InternalServerError, ErrorCodes.ServerError, "An unexpected error occurred.");
        }
    }

    private static async Task TryWriteErrorAsync(HttpContext http, int status, string error, string message)
    {
        if (http.Response.HasStarted) return;
        http.Response.Clear();
        await JsonResponse.WriteErrorAsync(http.Response, status, error, message);
    }
}
