# AzureQuotaLookup

PowerShell script that enumerates Azure quota usage across **all supported resource providers** and **all regions** for one or more subscriptions, using the unified [`Microsoft.Quota`](https://learn.microsoft.com/rest/api/quota/) REST API that powers the Azure portal's **Usage + quotas** blade.

Output is a flat list of objects (and optional CSV) with current usage, limit, and percent used per quota.

## Requirements

- PowerShell 7+ recommended (enables parallel queries via `ForEach-Object -Parallel`). PowerShell 5.1 works but runs serially.
- [`Az.Accounts`](https://www.powershellgallery.com/packages/Az.Accounts) module:
  ```powershell
  Install-Module Az.Accounts -Scope CurrentUser
  ```
- An authenticated Azure context. If none exists, the script prompts via `Connect-AzAccount`.
- `Microsoft.Quota` reader permission on the target subscription(s) (the built-in **Reader** role is sufficient for most providers).

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `-SubscriptionId` | `string[]` | One or more subscription IDs. Defaults to **all enabled subscriptions** in the current tenant. |
| `-Provider` | `string[]` | Resource provider namespaces to query (e.g. `Microsoft.Compute`). Defaults to a curated list of ~30 providers matching the portal's Usage + quotas blade. |
| `-Location` | `string[]` | Azure regions to limit the query to (e.g. `eastus`, `westeurope`). Defaults to every region where the provider is available. |
| `-OutputCsv` | `string` | Optional path. When set, results are also exported to CSV (UTF-8, comma-separated). |
| `-IncludeZeroUsage` | `switch` | Keep rows where both `CurrentValue` and `Limit` are `0` (filtered out by default). |
| `-ThrottleLimit` | `int` (1–64) | Max concurrent HTTP requests per subscription. Default `16`. Set to `1` to disable parallelism. PowerShell 7+ only. |

## Output object

Each emitted object has the following properties:

- `SubscriptionId`
- `Provider`
- `Location`
- `QuotaName` (localized display name)
- `QuotaCode` (stable identifier)
- `Unit`
- `CurrentValue`
- `Limit`
- `UsagePercent`

## Usage

### Query all subscriptions, all providers, all regions and write a CSV

```powershell
.\Get-AzureQuotaUsage.ps1 -OutputCsv .\quota-usage.csv
```

### Query a single subscription, specific providers and regions

```powershell
.\Get-AzureQuotaUsage.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -Provider Microsoft.Compute, Microsoft.ContainerService `
    -Location eastus, westeurope
```

### Find quotas above 80% utilization

```powershell
.\Get-AzureQuotaUsage.ps1 |
    Where-Object { $_.UsagePercent -ge 80 } |
    Sort-Object UsagePercent -Descending |
    Format-Table SubscriptionId, Provider, Location, QuotaName, CurrentValue, Limit, UsagePercent
```

### Show only Compute vCPU usage in a region

```powershell
.\Get-AzureQuotaUsage.ps1 -Provider Microsoft.Compute -Location westeurope |
    Format-Table QuotaName, CurrentValue, Limit, UsagePercent
```

### Run serially (e.g. for debugging or on PowerShell 5.1)

```powershell
.\Get-AzureQuotaUsage.ps1 -ThrottleLimit 1 -Verbose
```

## How it works

1. Authenticates with `Az.Accounts` (uses the existing context if available).
2. Resolves the target subscriptions and providers.
3. For each provider, discovers the regions where it's available (cached per run).
4. For each `(provider, region)` scope, calls:
   - `GET /providers/Microsoft.Quota/usages` — current values
   - `GET /providers/Microsoft.Quota/quotas` — limits
5. Joins usages with limits by quota code, computes `UsagePercent`, and emits objects to the pipeline (and optionally CSV).

A bearer token is acquired once per subscription and reused across parallel runspaces for performance.

## Notes

- Rows where both `CurrentValue` and `Limit` are `0` are dropped by default as noise — use `-IncludeZeroUsage` to keep them.
- A provider that isn't registered in the target subscription, or that doesn't expose `Microsoft.Quota` for a given region, is skipped silently. Use `-Verbose` to see per-call diagnostics.
- The default provider list mirrors the Azure portal's Usage + quotas blade and includes Compute, Network, Storage, AKS, Container Apps, Cognitive Services / Azure OpenAI, SQL, App Service, Key Vault, NetApp, AVS, and more.

## References

- [Microsoft.Quota REST API](https://learn.microsoft.com/rest/api/quota/)
- [Usages – List](https://learn.microsoft.com/rest/api/quota/usages/list)

