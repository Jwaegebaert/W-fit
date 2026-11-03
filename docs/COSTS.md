# W-fit Azure cost estimate

Hard ceiling: **$50/month**. Design target: $20–35/month. **Estimated actual: ≈ $1–3/month** (worst case with every
AI limit maxed out: ≈ $6/month).

All W-fit resources live in a dedicated resource group `<resource-group>` so a single resource-group budget covers everything,
including AI consumption (W-fit gets its own pay-per-token Azure OpenAI account — no fixed cost — instead of sharing
another shared account, so its spend is isolated and visible).

| Resource | SKU / configuration | Free allowance | Expected usage (1 user, 12 workouts/mo) | Est. $/month | Worst case |
|---|---|---|---|---|---|
| Azure SQL Database | Serverless GP Gen5, **free offer**, `freeLimitExhaustionBehavior = AutoPause`, 0.5–2 vCore, 32 GB | 100k vCore-s + 32 GB data + 32 GB backup / month | ~30–60 short wake-ups ≈ 20–50k vCore-s | **$0.00** | $0.00 (pauses instead of billing) |
| Azure Functions | **Flex Consumption**, 512 MB instances, no always-ready | 100k GB-s + 250k executions / month | < 1k executions, < 1k GB-s | **$0.00** | < $0.50 |
| Storage account | StorageV2 Standard_LRS (Functions host + deployment package) | — | < 1 GB, < 100k transactions | **$0.05–0.30** | $1.00 |
| Azure OpenAI | Dedicated S0 account, `gpt-4.1-mini` GlobalStandard, 20K TPM cap | — | ~150k input + 40k output tokens | **$0.10–0.50** | ≈ $3.50 (2M-token monthly app cap) |
| Key Vault | Standard, 1 secret | — | < 5k operations | **$0.01** | $0.05 |
| Log Analytics + App Insights | Workspace-based, PerGB2018, **daily cap 0.1 GB**, 30-day retention, sampling on | 5 GB ingestion / month | < 0.3 GB | **$0.00** | ≈ $0.50 |
| Cost Management budget | $50 RG budget, alerts at 50/80/100 % actual + 100 % forecast | free | — | **$0.00** | $0.00 |
| **Total** | | | | **≈ $0.20–1.20** | **≈ $6** |

## Safeguards (budget alerts do not stop spending — these do)
1. **SQL** cannot bill: free offer with AutoPause when the monthly free allowance runs out. The app keeps working offline
   and syncs again next month.
2. **AI** is limited in the API: `AI_DAILY_CALL_LIMIT` (25/day), `AI_MONTHLY_TOKEN_LIMIT` (2M tokens ≈ $2–3.5),
   `AI_MAX_OUTPUT_TOKENS` (1,800/call), insights cached per day, kill switch `AI_ENABLED`. The deployment's 20K TPM
   capacity is a second, platform-level throttle.
3. **Functions** are protected by the API key; unauthenticated calls are rejected before any SQL or AI work, and the
   Flex Consumption `maximumInstanceCount` is set to 2 (smallest allowed range) to bound runaway scale.
4. **Telemetry** has a hard daily ingestion cap (0.1 GB/day) and adaptive sampling.
5. **No tier upgrades** are automated anywhere; no premium SKUs, no dedicated plans, no always-ready instances, no VNet.

## Pricing references (pay-as-you-go list prices, USD, at time of writing)
- gpt-4.1-mini Global: $0.40 / 1M input tokens, $1.60 / 1M output tokens.
- Flex Consumption on-demand: $0.000026 / GB-s, $0.40 / 1M executions beyond the free grant.
- Log Analytics Analytics Logs: ~$2.30–2.76 / GB beyond 5 GB/month free.
- Azure SQL free offer: https://learn.microsoft.com/azure/azure-sql/database/free-offer
