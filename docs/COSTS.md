# W-fit Azure cost estimate

Hard ceiling: **$50/month**. Design target: $20–35/month. **Estimated actual: ≈ $0.20–1.20/month** (worst case with every
AI limit maxed out: ≈ $6/month).

Everything W-fit uses lives in the dedicated resource group `<resource-group>`, so a single resource-group budget covers
all of it, including AI consumption. W-fit has its own pay-per-token Azure OpenAI account (no fixed cost) instead of
sharing another shared account, so its spend stays isolated and visible.

## Deployed resources

| Resource | Name | Region | SKU / configuration | Free allowance | Expected usage (1 user, ~12 workouts/mo) | Est. $/month | Worst case |
|---|---|---|---|---|---|---|---|
| Azure SQL Database | `<sql-server>/wfit` | Sweden Central¹ | Serverless GP Gen5 (0.5–2 vCore, 32 GB), **free offer**, `freeLimitExhaustionBehavior = AutoPause`, auto-pause 60 min | 100k vCore-s + 32 GB data + 32 GB backup / month | ~30–60 short wake-ups ≈ 30–60k vCore-s | **$0.00** | $0.00 (pauses instead of billing) |
| Functions | `<function-app>` + `<plan>` | West Europe | **Flex Consumption** FC1, 512 MB instances, max 2 instances, no always-ready | 100k GB-s + 250k executions / month | < 1k executions, < 1k GB-s | **$0.00** | < $0.50 |
| Storage account | `<storage-account>` | West Europe | StorageV2 Standard_LRS, shared-key disabled (managed identity only) | — | < 1 GB, < 100k transactions | **$0.05–0.30** | $1.00 |
| Azure OpenAI | `<openai-account>` / deployment `gpt-4.1-mini` | West Europe (EU data zone) | S0, **DataZoneStandard**, 20K TPM capacity, keys disabled | — | ~150k input + 40k output tokens | **$0.10–0.50** | ≈ $3.50 (2M-token monthly app cap) |
| Key Vault | `<key-vault>` | West Europe | Standard, RBAC, 1 secret | — | < 5k operations | **$0.01** | $0.05 |
| Log Analytics + App Insights | `<log-workspace>`, `<app-insights>` | West Europe | PerGB2018, **daily cap 0.1 GB**, 30-day retention, 50 % sampling | 5 GB ingestion / month | < 0.3 GB | **$0.00** | ≈ $0.50 |
| Budget | `budget-wfit-monthly` | — | $50/month on `<resource-group>`, alerts at 20/50/80 % actual + 100 % forecast | free | — | **$0.00** | $0.00 |
| Inter-region traffic | Functions ⇄ SQL | WE ⇄ SE | Intra-Europe bandwidth | — | < 100 MB | **< $0.01** | $0.05 |
| **Total** | | | | | | **≈ $0.20–1.20** | **≈ $6** |

¹ West Europe and North Europe currently reject new SQL servers for this subscription
(`RegionDoesNotAllowProvisioning`), so SQL runs in Sweden Central. The rest stays in West Europe. That adds ~20 ms per
query, which is irrelevant for a single user.

Measured during deployment: one AI workout generation used ~5,000 tokens (≈ $0.003).

## Safeguards (budget alerts do not stop spending — these do)
1. **SQL** cannot bill: it's on the free offer with AutoPause when the monthly allowance runs out. The app keeps working
   offline and syncs again next month.
2. **AI** is limited in the API: `AI_DAILY_CALL_LIMIT` (25/day), `AI_MONTHLY_TOKEN_LIMIT` (2M tokens ≈ $2–3.5),
   `AI_MAX_OUTPUT_TOKENS` (1,800/call), insights cached per day, and the kill switch `AI_ENABLED`. The deployment's
   20K TPM capacity is a second, platform-level throttle.
3. **Functions** are protected by the API key. Unauthenticated calls are rejected before any SQL or AI work, and
   `maximumInstanceCount = 2` bounds runaway scale-out (the lowest allowed value is 1).
4. **Telemetry** has a hard daily ingestion cap (0.1 GB/day) and sampling.
5. **No tier upgrades** are automated anywhere: no premium SKUs, no dedicated plans, no always-ready instances, no VNet,
   and `versionUpgradeOption: NoAutoUpgrade` on the model deployment.

## Pricing references (pay-as-you-go list prices, USD)
- gpt-4.1-mini: ~$0.40 / 1M input tokens, ~$1.60 / 1M output tokens (Global); Data Zone is ~10 % higher.
- Flex Consumption on-demand: $0.000026 / GB-s and $0.40 / 1M executions beyond the free grant.
- Log Analytics Analytics Logs: ~$2.30–2.76 / GB beyond 5 GB/month free.
- Azure SQL free offer: https://learn.microsoft.com/azure/azure-sql/database/free-offer
