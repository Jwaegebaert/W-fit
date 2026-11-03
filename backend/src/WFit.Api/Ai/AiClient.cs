using System.ClientModel;
using Azure.AI.OpenAI;
using Azure.Identity;
using Microsoft.Extensions.Configuration;
using OpenAI.Chat;

namespace WFit.Api.Ai;

public sealed record AiSettings(
    bool Enabled,
    int DailyCallLimit,
    long MonthlyTokenLimit,
    int MaxOutputTokens,
    string? Endpoint,
    string Deployment)
{
    public static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(45);

    public static AiSettings FromConfiguration(IConfiguration c) => new(
        Enabled: !bool.TryParse(c["AI_ENABLED"], out var enabled) || enabled,
        DailyCallLimit: int.TryParse(c["AI_DAILY_CALL_LIMIT"], out var daily) ? daily : 25,
        MonthlyTokenLimit: long.TryParse(c["AI_MONTHLY_TOKEN_LIMIT"], out var monthly) ? monthly : 2_000_000,
        MaxOutputTokens: int.TryParse(c["AI_MAX_OUTPUT_TOKENS"], out var max) && max > 0 ? max : 1800,
        Endpoint: c["AZURE_OPENAI_ENDPOINT"],
        Deployment: string.IsNullOrWhiteSpace(c["AZURE_OPENAI_DEPLOYMENT"]) ? "gpt-4.1-mini" : c["AZURE_OPENAI_DEPLOYMENT"]!);
}

/// <summary>A single structured-output chat request.</summary>
public sealed record AiPrompt(string SchemaName, string SystemPrompt, string UserPrompt, string JsonSchema);

public sealed record AiCompletion(string Content, int InputTokens, int OutputTokens);

/// <summary>Seam over Azure OpenAI so the endpoints can be tested with canned responses.</summary>
public interface IAiClient
{
    Task<AiCompletion> CompleteAsync(AiPrompt prompt, CancellationToken ct);
}

/// <summary>Thrown when the model answered but the answer is unusable; carries the tokens that were spent.</summary>
public sealed class AiResponseException(string message, int inputTokens, int outputTokens) : Exception(message)
{
    public int InputTokens { get; } = inputTokens;
    public int OutputTokens { get; } = outputTokens;
}

/// <summary>Azure OpenAI chat completions with strict JSON-schema structured outputs, authenticated via Entra ID.</summary>
public sealed class AzureOpenAiClient(AiSettings settings) : IAiClient
{
    private readonly Lazy<ChatClient> _chat = new(() =>
    {
        if (string.IsNullOrWhiteSpace(settings.Endpoint))
            throw new InvalidOperationException("AZURE_OPENAI_ENDPOINT is not configured.");
        var options = new AzureOpenAIClientOptions { NetworkTimeout = AiSettings.CallTimeout };
        var client = new AzureOpenAIClient(new Uri(settings.Endpoint), new DefaultAzureCredential(), options);
        return client.GetChatClient(settings.Deployment);
    });

    public async Task<AiCompletion> CompleteAsync(AiPrompt prompt, CancellationToken ct)
    {
        var options = new ChatCompletionOptions
        {
            Temperature = 0.4f,
            MaxOutputTokenCount = settings.MaxOutputTokens,
            ResponseFormat = ChatResponseFormat.CreateJsonSchemaFormat(
                prompt.SchemaName, BinaryData.FromString(prompt.JsonSchema), jsonSchemaIsStrict: true),
        };
        ChatMessage[] messages = [new SystemChatMessage(prompt.SystemPrompt), new UserChatMessage(prompt.UserPrompt)];

        ClientResult<ChatCompletion> result = await _chat.Value.CompleteChatAsync(messages, options, ct);
        var completion = result.Value;
        var input = completion.Usage?.InputTokenCount ?? 0;
        var output = completion.Usage?.OutputTokenCount ?? 0;

        if (completion.FinishReason != ChatFinishReason.Stop)
            throw new AiResponseException($"Model finished with '{completion.FinishReason}'.", input, output);
        var text = completion.Content.Count > 0 ? completion.Content[0].Text : null;
        if (string.IsNullOrWhiteSpace(text))
            throw new AiResponseException("Model returned no content.", input, output);

        return new AiCompletion(text, input, output);
    }
}
