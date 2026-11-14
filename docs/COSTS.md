# W-fit Azure cost estimate

Hard ceiling: **$50/month**. Design target: $20–35/month. **Estimated actual: ≈ $1.50–4/month** (worst case with every
AI limit maxed out: ≈ $15/month).

Everything W-fit uses lives in one dedicated resource group, so a single resource-group budget covers all of it,
including AI consumption. W-fit has its own pay-per-token Azure OpenAI account (no fixed cost) instead of sharing one
with other projects, so its spend stays isolated and visible.

## Resources

| Resource | Region | SKU / configuration | Free allowance | Expected usage (1 user, ~12 workouts/mo) | Est. $/month | Worst case |
|---|---|---|---|---|---|---|
| Azure SQL Database | SQL region¹ | Serverless GP Gen5 (0.5–2 vCore, 32 GB), **free offer**, `freeLimitExhaustionBehavior = AutoPause`, auto-pause 60 min | 100k vCore-s + 32 GB data + 32 GB backup / month | ~30–60 short wake-ups ≈ 30–60k vCore-s | **$0.00** | $0.00 (pauses instead of billing) |
| Functions | Main region | **Flex Consumption** FC1, 512 MB instances, max 2 instances, no always-ready | 100k GB-s + 250k executions / month | < 1k executions, < 1k GB-s | **$0.00** | < $0.50 |
| Storage account | Main region | StorageV2 Standard_LRS, shared-key disabled (managed identity only); blob (deploy package) + table `aiusage` | — | < 1 GB, < 100k transactions | **$0.05–0.30** | $1.00 |
| Azure OpenAI | Main region (EU data zone) | S0, **DataZoneStandard**, 50K TPM each, keys disabled | — | ~40 calls ≈ 250k input + 50k output tokens | **$1.20–3.50** | ≈ $14 (3M-token monthly app cap) |
| Key Vault | Main region | Standard, RBAC, 1 secret | — | < 5k operations | **$0.01** | $0.05 |
| Log Analytics + App Insights | Main region | PerGB2018, **daily cap 0.1 GB**, 30-day retention, 50 % sampling | 5 GB ingestion / month | < 0.3 GB | **$0.00** | ≈ $0.50 |
| Budget | — | $50/month on the resource group, alerts at 20/50/80 % actual + 100 % forecast | free | — | **$0.00** | $0.00 |
| Inter-region traffic | Main ⇄ SQL region | Intra-Europe bandwidth | — | < 100 MB | **< $0.01** | $0.05 |
| **Total** | | | | | **≈ $1.50–4** | **≈ $15** |

¹ Some subscriptions can't create new SQL servers in every region (`RegionDoesNotAllowProvisioning`), so the template
lets SQL live in its own region (`sqlLocation`) while everything else uses the resource group's region. Crossing
regions adds ~20 ms per query, which is irrelevant for a single user.

Measured (live evaluation, Nov 2026, gpt-6-sol, reasoning effort low): one workout plan ≈ 5.7k input + 1.1k output
tokens (incl. ~200 reasoning) ≈ $0.03, 10–14 s. v2 used gpt-4.1-mini at ≈ $0.003 per plan but with clearly weaker
plans (see [IMPROVEMENT-PLAN.md](IMPROVEMENT-PLAN.md) §3).

## Safeguards (budget alerts do not stop spending — these do)
1. **SQL** cannot bill: it's on the free offer with AutoPause when the monthly allowance runs out. The app keeps working
   offline and syncs again next month.
2. **AI** is limited in the API: `AI_DAILY_CALL_LIMIT` (40/day), `AI_MONTHLY_TOKEN_LIMIT` (3M tokens ≈ $10–14),
   `AI_MAX_OUTPUT_TOKENS` (8,000/call incl. reasoning), insights cached per day on the phone, and the kill switch
   `AI_ENABLED`. Counters live in Table Storage. The deployments' 50K TPM capacity is a second, platform-level throttle.
3. **Functions** are protected by the API key. Unauthenticated calls are rejected before any SQL or AI work, and
   `maximumInstanceCount = 2` bounds runaway scale-out (the lowest allowed value is 1).
4. **Telemetry** has a hard daily ingestion cap (0.1 GB/day) and sampling.
5. **No tier upgrades** are automated anywhere: no premium SKUs, no dedicated plans, no always-ready instances, no VNet,
   and model deployments only move to a new default version of the same model.

## Pricing references (pay-as-you-go list prices, USD)
- gpt-6-sol (Data Zone): $2.40 / 1M input, $0.24 / 1M cached input, $12 / 1M output tokens.
- gpt-6-luna (Data Zone): $0.12 / 1M input, $0.60 / 1M output tokens.
- Flex Consumption on-demand: $0.000026 / GB-s and $0.40 / 1M executions beyond the free grant.
- Log Analytics Analytics Logs: ~$2.30–2.76 / GB beyond 5 GB/month free.
- Azure SQL free offer: https://learn.microsoft.com/azure/azure-sql/database/free-offer
