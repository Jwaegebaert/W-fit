using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace WFit.Api.Infrastructure;

public sealed record ApiError(string Error, string Message);

public static class ErrorCodes
{
    public const string Unauthorized = "unauthorized";
    public const string BadRequest = "bad_request";
    public const string AiDisabled = "ai_disabled";
    public const string AiLimitReached = "ai_limit_reached";
    public const string AiUnavailable = "ai_unavailable";
    public const string PayloadTooLarge = "payload_too_large";
    public const string NotFound = "not_found";
    public const string ServerError = "server_error";
}

/// <summary>Expected failure mapped to the contract error shape by <see cref="ApiMiddleware"/>.</summary>
public sealed class ApiException(int statusCode, string error, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public int StatusCode { get; } = statusCode;
    public string Error { get; } = error;

    public static ApiException BadRequest(string message) => new(StatusCodes.Status400BadRequest, ErrorCodes.BadRequest, message);
    public static ApiException AiDisabled() => new(StatusCodes.Status503ServiceUnavailable, ErrorCodes.AiDisabled, "AI features are disabled.");
    public static ApiException AiLimitReached(string message) => new(StatusCodes.Status429TooManyRequests, ErrorCodes.AiLimitReached, message);
    public static ApiException AiUnavailable(string message = "The AI service is unavailable right now.", Exception? inner = null) =>
        new(StatusCodes.Status503ServiceUnavailable, ErrorCodes.AiUnavailable, message, inner);
    public static ApiException PayloadTooLarge(int maxBytes) =>
        new(StatusCodes.Status413PayloadTooLarge, ErrorCodes.PayloadTooLarge, $"Request body exceeds {maxBytes / 1024} KB.");
}

/// <summary>Writes a JSON body with the app-wide serializer options (no MVC formatters involved).</summary>
public sealed class JsonResponse(object? value, int statusCode = StatusCodes.Status200OK) : IActionResult
{
    public object? Value { get; } = value;
    public int StatusCode { get; } = statusCode;

    public Task ExecuteResultAsync(ActionContext context) => WriteAsync(context.HttpContext.Response, StatusCode, Value);

    public static async Task WriteAsync(HttpResponse response, int statusCode, object? value)
    {
        response.StatusCode = statusCode;
        response.ContentType = "application/json; charset=utf-8";
        await JsonSerializer.SerializeAsync(response.Body, value, value?.GetType() ?? typeof(object), JsonDefaults.Options);
    }

    public static Task WriteErrorAsync(HttpResponse response, int statusCode, string error, string message) =>
        WriteAsync(response, statusCode, new ApiError(error, message));
}

public static class RequestReader
{
    /// <summary>Default cap (sync payloads); AI endpoints pass a much smaller one.</summary>
    public const int MaxBodyBytes = 16 * 1024 * 1024;

    /// <summary>
    /// Deserializes the body; malformed JSON or an empty body (when required) becomes 400 <c>bad_request</c>,
    /// a body larger than <paramref name="maxBytes"/> 413 <c>payload_too_large</c>.
    /// </summary>
    public static async Task<T?> ReadAsync<T>(HttpRequest request, bool required, CancellationToken ct, int maxBytes = MaxBodyBytes) where T : class
    {
        if (request.ContentLength > maxBytes) throw ApiException.PayloadTooLarge(maxBytes);

        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = await request.Body.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > maxBytes) throw ApiException.PayloadTooLarge(maxBytes);
            buffer.Write(chunk, 0, read);
        }

        var bytes = buffer.GetBuffer().AsMemory(0, (int)buffer.Length);
        if (bytes.Span.Trim(" \t\r\n"u8).IsEmpty)
            return required ? throw ApiException.BadRequest("Request body is required.") : null;

        T? value;
        try
        {
            value = JsonSerializer.Deserialize<T>(bytes.Span, JsonDefaults.Options);
        }
        catch (JsonException ex)
        {
            throw ApiException.BadRequest("Malformed JSON body" + (ex.Path is { Length: > 0 } p ? $" at {p}." : "."));
        }

        if (value is null && required) throw ApiException.BadRequest("Request body is required.");
        return value;
    }
}
