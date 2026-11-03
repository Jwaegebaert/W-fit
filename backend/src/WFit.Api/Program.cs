using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using WFit.Api.Ai;
using WFit.Api.Data;
using WFit.Api.Domain;
using WFit.Api.Infrastructure;
using WFit.Api.Sync;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();
builder.UseMiddleware<ApiMiddleware>();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

// Keep telemetry minimal: warnings and above, plus our own information logs.
builder.Logging.Services.Configure<LoggerFilterOptions>(options =>
{
    var aiDefault = options.Rules.FirstOrDefault(r =>
        r.ProviderName == "Microsoft.Extensions.Logging.ApplicationInsights.ApplicationInsightsLoggerProvider");
    if (aiDefault is not null) options.Rules.Remove(aiDefault);
});
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Logging.AddFilter("WFit", LogLevel.Information);

builder.Services.Configure<Microsoft.AspNetCore.Mvc.JsonOptions>(o => JsonDefaults.Configure(o.JsonSerializerOptions));
builder.Services.Configure<Microsoft.AspNetCore.Http.Json.JsonOptions>(o => JsonDefaults.Configure(o.SerializerOptions));

builder.Services.AddDbContext<WFitDbContext>((sp, options) =>
{
    var connectionString = sp.GetRequiredService<IConfiguration>()["SQL_CONNECTION_STRING"];
    if (string.IsNullOrWhiteSpace(connectionString))
        throw new InvalidOperationException("SQL_CONNECTION_STRING is not configured.");

    options.UseSqlServer(connectionString, sql =>
    {
        // Serverless SQL resumes from auto-pause in ~30-60 s; retry transient failures meanwhile.
        sql.EnableRetryOnFailure(maxRetryCount: 8, maxRetryDelay: TimeSpan.FromSeconds(15), errorNumbersToAdd: null);
        sql.CommandTimeout(90);
    });
});

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<CatalogService>();
builder.Services.AddSingleton<DatabaseInitializer>();
builder.Services.AddSingleton(sp => AiSettings.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<IAiClient, AzureOpenAiClient>();

builder.Services.AddScoped<SyncService>();
builder.Services.AddScoped<TrainingDataReader>();
builder.Services.AddScoped<AiUsageService>();
builder.Services.AddScoped<WorkoutAiService>();
builder.Services.AddScoped<SwapAiService>();
builder.Services.AddScoped<InsightsService>();

builder.Build().Run();
