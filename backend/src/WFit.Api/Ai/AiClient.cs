using System.ClientModel;
using System.ClientModel.Primitives;
using System.Collections.Concurrent;
using System.Diagnostics;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using OpenAI;
using OpenAI.Chat;

namespace WFit.Api.Ai;

public sealed record AiSettings
{
    public const string DefaultDeployment = "gpt-6-sol";
    public const string DefaultFallbackDeployment = "gpt-6-luna";

    public bool Enabled { get; init; } = true;
    public int DailyCallLimit { get; init; } = 40;
    public long MonthlyTokenLimit { get; init; } = 3_000_000;

    /// <summary><c>max_completion_tokens</c>; includes the reasoning tokens of reasoning models.</summary>
    public int MaxOutputTokens { get; init; } = 8000;

    public string? Endpoint { get; init; }
    public string Deployment { get; init; } = DefaultDeployment;

    /// <summary>Used once when the primary deployment is throttled (429), fails (5xx) or times out. Null = no fallback.</summary>
    public string? FallbackDeployment { get; init; } = DefaultFallbackDeployment;

    /// <summary>Per-attempt timeout (the fallback attempt gets its own).</summary>
    public TimeSpan CallTimeout { get; init; } = TimeSpan.FromSeconds(60);

    public static AiSettings FromConfiguration(IConfiguration c)
    {
        var deployment = string.IsNullOrWhiteSpace(c["AZURE_OPENAI_DEPLOYMENT"]) ? DefaultDeployment : c["AZURE_OPENAI_DEPLOYMENT"]!.Trim();
        // Missing setting ⇒ default fallback; empty or "none" ⇒ fallback disabled.
        var fallbackRaw = c["AZURE_OPENAI_FALLBACK_DEPLOYMENT"];
        string? fallback = fallbackRaw is null ? DefaultFallbackDeployment : fallbackRaw.Trim();
        if (fallback.Length == 0 || fallback.Equals("none", StringComparison.OrdinalIgnoreCase) || fallback == deployment)
            fallback = null;

        return new AiSettings
        {
            Enabled = !bool.TryParse(c["AI_ENABLED"], out var enabled) || enabled,
            DailyCallLimit = int.TryParse(c["AI_DAILY_CALL_LIMIT"], out var daily) && daily >= 0 ? daily : 40,
            MonthlyTokenLimit = long.TryParse(c["AI_MONTHLY_TOKEN_LIMIT"], out var monthly) && monthly >= 0 ? monthly : 3_000_000,
            MaxOutputTokens = int.TryParse(c["AI_MAX_OUTPUT_TOKENS"], out var max) && max > 0 ? max : 8000,
            Endpoint = string.IsNullOrWhiteSpace(c["AZURE_OPENAI_ENDPOINT"]) ? null : c["AZURE_OPENAI_ENDPOINT"]!.Trim(),
            Deployment = deployment,
            FallbackDeployment = fallback,
            CallTimeout = TimeSpan.FromSeconds(
                int.TryParse(c["AI_CALL_TIMEOUT_SECONDS"], out var seconds) && seconds is >= 5 and <= 300 ? seconds : 60),
        };
    }
}

/// <summary>Reasoning effort of reasoning models (gpt-6-*): low for interactive calls, medium for background analysis.</summary>
public enum AiEffort { Low, Medium }

/// <summary>A single structured-output chat request.</summary>
public sealed record AiPrompt(string SchemaName, string SystemPrompt, string UserPrompt, string JsonSchema, AiEffort Effort = AiEffort.Low);

public sealed record AiCompletion(
    string Content,
    int InputTokens,
    int OutputTokens,
    int ReasoningTokens = 0,
    string Model = "",
    long LatencyMs = 0);

/// <summary>Seam over Azure OpenAI so the endpoints can be tested with canned responses.</summary>
public interface IAiClient
{
    Task<AiCompletion> CompleteAsync(AiPrompt prompt, string deployment, CancellationToken ct);
}

/// <summary>Thrown when the model answered but the answer is unusable; carries the tokens that were spent.</summary>
public sealed class AiResponseException(string message, int inputTokens, int outputTokens, int reasoningTokens = 0)
    : Exception(message)
{
    public int InputTokens { get; } = inputTokens;
    public int OutputTokens { get; } = outputTokens;
    public int ReasoningTokens { get; } = reasoningTokens;
}

/// <summary>The model endpoint failed. <see cref="Transient"/> (throttling, 5xx, network) allows the fallback deployment.</summary>
public sealed class AiUpstreamException(string message, int status, bool transient, Exception? inner = null)
    : Exception(message, inner)
{
    public int Status { get; } = status;
    public bool Transient { get; } = transient;

    public static bool IsTransientStatus(int status) => status is 0 or 408 or 429 or >= 500;
}

/// <summary>
/// Azure OpenAI v1 chat completions (<c>{endpoint}/openai/v1</c>) via the OpenAI .NET SDK with strict JSON-schema
/// structured outputs, <c>reasoning_effort</c> and <c>max_completion_tokens</c>, authenticated with Entra ID.
/// SDK retries are disabled: <see cref="AiGateway"/> owns timeouts and the single fallback attempt.
/// </summary>
public sealed class AzureOpenAiClient(AiSettings settings, TokenCredential credential) : IAiClient
{
    public const string TokenScope = "https://cognitiveservices.azure.com/.default";

    private readonly ConcurrentDictionary<string, ChatClient> _clients = new(StringComparer.Ordinal);

    /// <summary>Normalises the resource endpoint to the v1 API base (<c>https://x.openai.azure.com/openai/v1/</c>).</summary>
    public static Uri V1Endpoint(string endpoint)
    {
        var baseUri = endpoint.Trim().TrimEnd('/');
        if (!baseUri.EndsWith("/openai/v1", StringComparison.OrdinalIgnoreCase)) baseUri += "/openai/v1";
        return new Uri(baseUri + "/");
    }

    private ChatClient ClientFor(string deployment) => _clients.GetOrAdd(deployment, d =>
    {
        if (string.IsNullOrWhiteSpace(settings.Endpoint))
            throw new AiUpstreamException("AZURE_OPENAI_ENDPOINT is not configured.", 0, transient: false);
        var options = new OpenAIClientOptions
        {
            Endpoint = V1Endpoint(settings.Endpoint),
            // The gateway's per-attempt timeout fires first; this only guards against a hung socket.
            NetworkTimeout = settings.CallTimeout + TimeSpan.FromSeconds(15),
            RetryPolicy = new ClientRetryPolicy(maxRetries: 0),
        };
#pragma warning disable OPENAI001 // Token authentication (ChatClient + BearerTokenPolicy) is marked experimental.
        return new ChatClient(d, new BearerTokenPolicy(credential, TokenScope), options);
#pragma warning restore OPENAI001
    });

    public async Task<AiCompletion> CompleteAsync(AiPrompt prompt, string deployment, CancellationToken ct)
    {
#pragma warning disable OPENAI001 // ReasoningEffortLevel (reasoning_effort) is marked experimental.
        var options = new ChatCompletionOptions
        {
            MaxOutputTokenCount = settings.MaxOutputTokens,
            ReasoningEffortLevel = prompt.Effort == AiEffort.Medium ? ChatReasoningEffortLevel.Medium : ChatReasoningEffortLevel.Low,
            ResponseFormat = ChatResponseFormat.CreateJsonSchemaFormat(
                prompt.SchemaName, BinaryData.FromString(prompt.JsonSchema), jsonSchemaIsStrict: true),
        };
#pragma warning restore OPENAI001
        // Reasoning models treat the system message as the developer message.
        ChatMessage[] messages = [new SystemChatMessage(prompt.SystemPrompt), new UserChatMessage(prompt.UserPrompt)];

        var stopwatch = Stopwatch.StartNew();
        ChatCompletion completion;
        try
        {
            ClientResult<ChatCompletion> result = await ClientFor(deployment).CompleteChatAsync(messages, options, ct);
            completion = result.Value;
        }
        catch (ClientResultException ex)
        {
            throw new AiUpstreamException($"Azure OpenAI returned {ex.Status}.", ex.Status, AiUpstreamException.IsTransientStatus(ex.Status), ex);
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException)
        {
            throw new AiUpstreamException("Azure OpenAI could not be reached.", 0, transient: true, ex);
        }
        stopwatch.Stop();

        var input = completion.Usage?.InputTokenCount ?? 0;
        var output = completion.Usage?.OutputTokenCount ?? 0;
        var reasoning = completion.Usage?.OutputTokenDetails?.ReasoningTokenCount ?? 0;

        if (completion.FinishReason != ChatFinishReason.Stop)
            throw new AiResponseException($"Model finished with '{completion.FinishReason}'.", input, output, reasoning);
        if (!string.IsNullOrWhiteSpace(completion.Refusal))
            throw new AiResponseException("Model refused the request.", input, output, reasoning);
        var text = completion.Content.Count > 0 ? completion.Content[0].Text : null;
        if (string.IsNullOrWhiteSpace(text))
            throw new AiResponseException("Model returned no content.", input, output, reasoning);

        return new AiCompletion(text, input, output, reasoning, deployment, stopwatch.ElapsedMilliseconds);
    }
}
