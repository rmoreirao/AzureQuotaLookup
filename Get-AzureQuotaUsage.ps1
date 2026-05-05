<#
.SYNOPSIS
    Lists quota usage for all supported Azure Resource Providers across all regions
    for one or more subscriptions, using the unified Microsoft.Quota REST API.

.DESCRIPTION
    The Azure portal's "Usage + quotas" blade is backed by the Microsoft.Quota
    resource provider (https://learn.microsoft.com/rest/api/quota/). That API
    exposes a consistent /usages endpoint per (provider, location) scope.

    This script:
      1. Authenticates with Az PowerShell (uses the current context if already
         signed in, otherwise prompts).
      2. Iterates every subscription you pass in (or all enabled subscriptions
         if none are provided).
      3. For each supported resource provider, enumerates the locations where
         that provider is available and queries Microsoft.Quota/usages.
      4. Emits a flat list of objects (SubscriptionId, Provider, Location,
         QuotaName, Unit, CurrentValue, Limit, UsagePercent) and optionally
         exports to CSV.

.PARAMETER SubscriptionId
    One or more subscription IDs to query. If omitted, all enabled
    subscriptions in the current tenant are used.

.PARAMETER Provider
    One or more resource provider namespaces to query. Defaults to the full
    set supported by Microsoft.Quota (matches the providers shown in the
    Azure portal "Usage + quotas" blade).

.PARAMETER Location
    Optional list of Azure regions to limit the query to. If omitted, every
    region where the provider is available is queried.

.PARAMETER OutputCsv
    Optional path to a CSV file. When provided, results are also written to
    this file (UTF-8, no BOM, comma-separated).

.PARAMETER IncludeZeroUsage
    By default, rows with both CurrentValue = 0 AND Limit = 0 are filtered
    out (they are noise). Use this switch to keep them.

.EXAMPLE
    .\Get-AzureQuotaUsage.ps1 -OutputCsv .\quota-usage.csv

.EXAMPLE
    .\Get-AzureQuotaUsage.ps1 -SubscriptionId 'xxxx-xxxx' `
        -Provider Microsoft.Compute,Microsoft.ContainerService `
        -Location eastus,westeurope

.NOTES
    Requires the Az.Accounts module (Install-Module Az.Accounts).
    REST reference: https://learn.microsoft.com/rest/api/quota/usages/list
#>
[CmdletBinding()]
param(
    [string[]] $SubscriptionId,

    # If omitted/empty, the script iterates the full curated list below
    # (see $DefaultProviders). This guarantees coverage even when a
    # provider hasn't been registered yet in the subscription.
    [string[]] $Provider,

    [string[]] $Location,

    [string] $OutputCsv,

    [switch] $IncludeZeroUsage,

    # Maximum concurrent HTTP requests per subscription. PowerShell 7+ only.
    # Set to 1 to disable parallelism.
    [ValidateRange(1, 64)]
    [int] $ThrottleLimit = 16
)

$ErrorActionPreference = 'Stop'

# --- Curated default provider list -----------------------------------------
# Full set of provider namespaces that the Azure portal "Usage + quotas"
# blade aggregates. Used when -Provider is not supplied. We iterate this
# static list (instead of only Registered providers) so that a missing
# registration in the target subscription doesn't silently hide quotas.
$DefaultProviders = @(
    'Microsoft.Compute',                 # Compute (vCPU families)
    'Microsoft.ClassicCompute',          # Compute (classic)
    'Microsoft.Network',                 # Networking
    'Microsoft.Storage',                 # Storage
    'Microsoft.ClassicStorage',          # Storage (classic)
    'Microsoft.MachineLearningServices', # Machine Learning
    'Microsoft.ContainerService',        # Azure Kubernetes Service (AKS)
    'Microsoft.ContainerInstance',       # Azure Container Instances
    'Microsoft.App',                     # Azure Container Apps
    'Microsoft.Search',                  # Azure Cognitive Search
    'Microsoft.HDInsight',               # HDInsight
    'Microsoft.LabServices',             # Azure Lab Services
    'Microsoft.StorageCache',            # HPC Cache
    'Microsoft.DBforPostgreSQL',         # Azure PostgreSQL
    'Microsoft.DevCenter',               # Dev Box / Managed DevOps Pools
    'Microsoft.AVS',                     # Azure VMware Solution
    'Microsoft.Automation',              # Automation Accounts
    'Microsoft.Fabric',                  # Microsoft Fabric
    'Microsoft.CognitiveServices',       # Cognitive Services / Azure OpenAI
    'Microsoft.SignalRService',          # SignalR / Web PubSub
    'Microsoft.Batch',                   # Azure Batch
    'Microsoft.Sql',                     # Azure SQL
    'Microsoft.DBforMySQL',              # Azure MySQL
    'Microsoft.Cache',                   # Azure Cache for Redis
    'Microsoft.Web',                     # App Service
    'Microsoft.KeyVault',                # Key Vault
    'Microsoft.EventHub',                # Event Hubs
    'Microsoft.ServiceBus',              # Service Bus
    'Microsoft.NetApp',                  # Azure NetApp Files
    'Microsoft.RecoveryServices',        # Recovery Services / Backup
    'Microsoft.Quantum'                  # Azure Quantum
)

# --- Module / sign-in -------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az.Accounts module not found. Install with: Install-Module Az.Accounts -Scope CurrentUser"
}
Import-Module Az.Accounts -ErrorAction Stop | Out-Null

if (-not (Get-AzContext)) {
    Write-Host "No Azure context found. Launching interactive sign-in..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
}

# --- Resolve subscriptions --------------------------------------------------
if (-not $SubscriptionId -or $SubscriptionId.Count -eq 0) {
    $SubscriptionId = (Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }).Id
}
if (-not $Provider -or $Provider.Count -eq 0) {
    $Provider = $DefaultProviders
}
Write-Host "Querying $($SubscriptionId.Count) subscription(s) and $($Provider.Count) provider(s)..." -ForegroundColor Cyan

# --- Helper: invoke ARM with paging ----------------------------------------
function Invoke-ArmGet {
    param(
        [Parameter(Mandatory)] [string] $Path,    # e.g. /subscriptions/.../providers/Microsoft.Quota/usages
        [Parameter(Mandatory)] [string] $ApiVersion
    )
    $items = @()
    $uri = "https://management.azure.com$Path`?api-version=$ApiVersion"
    while ($uri) {
        $resp = Invoke-AzRestMethod -Method GET -Uri $uri
        if ($resp.StatusCode -ge 400) {
            # Throwing per-call would abort the whole sweep; surface and continue.
            Write-Verbose "GET $uri -> HTTP $($resp.StatusCode): $($resp.Content)"
            return ,@()
        }
        $body = $resp.Content | ConvertFrom-Json -Depth 20
        if ($body.value) { $items += $body.value }
        $uri = $body.nextLink
    }
    return ,$items
}

# --- Cache provider locations to avoid repeated lookups --------------------
$providerLocationCache = @{}
function Get-ProviderLocations {
    param([string] $SubId, [string] $ProviderNs)
    $key = "$SubId|$ProviderNs"
    if ($providerLocationCache.ContainsKey($key)) { return $providerLocationCache[$key] }

    $resp = Invoke-AzRestMethod -Method GET `
        -Uri "https://management.azure.com/subscriptions/$SubId/providers/$ProviderNs`?api-version=2022-12-01"
    $locs = @()
    if ($resp.StatusCode -lt 400) {
        $body = $resp.Content | ConvertFrom-Json -Depth 20
        # Pick a resource type that has locations. Prefer 'locations' if exposed.
        $primary = $body.resourceTypes | Where-Object { $_.locations -and $_.locations.Count -gt 0 } |
                   Sort-Object { $_.locations.Count } -Descending | Select-Object -First 1
        if ($primary) {
            $locs = $primary.locations | ForEach-Object { ($_ -replace '\s','').ToLower() } | Sort-Object -Unique
        }
    }
    $providerLocationCache[$key] = $locs
    return $locs
}

# --- Main sweep -------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

# Detect parallel support (PowerShell 7+).
$canParallel = $PSVersionTable.PSVersion.Major -ge 7 -and $ThrottleLimit -gt 1
if (-not $canParallel -and $ThrottleLimit -gt 1) {
    Write-Warning "ForEach-Object -Parallel requires PowerShell 7+. Falling back to serial execution."
}

foreach ($subId in $SubscriptionId) {
    Write-Host "`n=== Subscription $subId ===" -ForegroundColor Green
    Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue | Out-Null

    # Acquire a bearer token once per subscription so parallel runspaces can
    # call ARM directly via Invoke-RestMethod (much faster than re-invoking
    # Invoke-AzRestMethod, which re-resolves context on every call and is
    # not safe to use across runspaces without re-importing Az.Accounts).
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    $bearer   = if ($tokenObj.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    } else { $tokenObj.Token }

    # Build the (provider, location) work list for this subscription.
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($ns in $Provider) {
        $locs = Get-ProviderLocations -SubId $subId -ProviderNs $ns
        if ($Location) {
            $wanted = $Location | ForEach-Object { ($_ -replace '\s','').ToLower() }
            $locs   = $locs | Where-Object { $wanted -contains $_ }
        }
        if (-not $locs -or $locs.Count -eq 0) {
            Write-Verbose "  $ns : no locations found / not registered."
            continue
        }
        Write-Host ("  {0,-40} {1} location(s)" -f $ns, $locs.Count)
        foreach ($loc in $locs) {
            $jobs.Add([pscustomobject]@{ Provider = $ns; Location = $loc }) | Out-Null
        }
    }
    if ($jobs.Count -eq 0) { continue }

    Write-Host "  -> dispatching $($jobs.Count) quota lookups (throttle=$ThrottleLimit)..." -ForegroundColor DarkCyan

    # Per-job work (used by both parallel and serial paths). Inlined into
    # ForEach-Object -Parallel below because $using: cannot transport a
    # scriptblock variable into parallel runspaces.
    $includeZero = $IncludeZeroUsage.IsPresent

    if ($canParallel) {
        $rows = $jobs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $subId       = $using:subId
            $bearer      = $using:bearer
            $includeZero = $using:includeZero
            $ns  = $_.Provider
            $loc = $_.Location

            $headers = @{ Authorization = "Bearer $bearer" }
            $base    = 'https://management.azure.com'
            $api     = '2023-02-01'
            $scope   = "/subscriptions/$subId/providers/$ns/locations/$loc"

            $fetch = {
                param($url, $hdrs)
                $items = @()
                while ($url) {
                    try { $body = Invoke-RestMethod -Method GET -Uri $url -Headers $hdrs -ErrorAction Stop }
                    catch { return ,@() }
                    if ($body.value) { $items += $body.value }
                    $url = $body.nextLink
                }
                ,$items
            }

            $usages = & $fetch "$base$scope/providers/Microsoft.Quota/usages?api-version=$api" $headers
            $quotas = & $fetch "$base$scope/providers/Microsoft.Quota/quotas?api-version=$api" $headers

            $limitByCode = @{}
            foreach ($q in $quotas) {
                $c = $q.properties.name.value
                if ($null -ne $c) { $limitByCode[$c] = $q.properties.limit.value }
            }

            $out = New-Object System.Collections.Generic.List[object]
            foreach ($u in $usages) {
                $code     = $u.properties.name.value
                $current  = [int64]($u.properties.usages.value)
                $limitRaw = if ($limitByCode.ContainsKey($code)) { $limitByCode[$code] } else { $null }
                $limit    = if ($null -ne $limitRaw) { [int64]$limitRaw } else { $null }

                if (-not $includeZero -and $current -le 0 -and ($null -eq $limit -or $limit -le 0)) { continue }
                $pct = if ($limit -and $limit -gt 0) { [math]::Round(($current / $limit) * 100, 2) } else { $null }

                $out.Add([pscustomobject]@{
                    SubscriptionId = $subId
                    Provider       = $ns
                    Location       = $loc
                    QuotaName      = $u.properties.name.localizedValue ?? $code
                    QuotaCode      = $code
                    Unit           = $u.properties.unit
                    CurrentValue   = $current
                    Limit          = $limit
                    UsagePercent   = $pct
                }) | Out-Null
            }
            ,$out
        }
    } else {
        $headers = @{ Authorization = "Bearer $bearer" }
        $base    = 'https://management.azure.com'
        $api     = '2023-02-01'

        $fetch = {
            param($url, $hdrs)
            $items = @()
            while ($url) {
                try { $body = Invoke-RestMethod -Method GET -Uri $url -Headers $hdrs -ErrorAction Stop }
                catch { return ,@() }
                if ($body.value) { $items += $body.value }
                $url = $body.nextLink
            }
            ,$items
        }

        $rows = foreach ($j in $jobs) {
            $ns = $j.Provider; $loc = $j.Location
            $scope = "/subscriptions/$subId/providers/$ns/locations/$loc"

            $usages = & $fetch "$base$scope/providers/Microsoft.Quota/usages?api-version=$api" $headers
            $quotas = & $fetch "$base$scope/providers/Microsoft.Quota/quotas?api-version=$api" $headers

            $limitByCode = @{}
            foreach ($q in $quotas) {
                $c = $q.properties.name.value
                if ($null -ne $c) { $limitByCode[$c] = $q.properties.limit.value }
            }

            $out = New-Object System.Collections.Generic.List[object]
            foreach ($u in $usages) {
                $code     = $u.properties.name.value
                $current  = [int64]($u.properties.usages.value)
                $limitRaw = if ($limitByCode.ContainsKey($code)) { $limitByCode[$code] } else { $null }
                $limit    = if ($null -ne $limitRaw) { [int64]$limitRaw } else { $null }

                if (-not $includeZero -and $current -le 0 -and ($null -eq $limit -or $limit -le 0)) { continue }
                $pct = if ($limit -and $limit -gt 0) { [math]::Round(($current / $limit) * 100, 2) } else { $null }

                $out.Add([pscustomobject]@{
                    SubscriptionId = $subId
                    Provider       = $ns
                    Location       = $loc
                    QuotaName      = $u.properties.name.localizedValue ?? $code
                    QuotaCode      = $code
                    Unit           = $u.properties.unit
                    CurrentValue   = $current
                    Limit          = $limit
                    UsagePercent   = $pct
                }) | Out-Null
            }
            ,$out
        }
    }

    foreach ($batch in $rows) {
        if ($null -eq $batch) { continue }
        foreach ($row in $batch) { $results.Add($row) | Out-Null }
    }
}

# --- Output ----------------------------------------------------------------
Write-Host "`nCollected $($results.Count) quota row(s)." -ForegroundColor Cyan

if ($OutputCsv) {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding utf8
    Write-Host "Wrote: $OutputCsv" -ForegroundColor Green
}

# Always emit objects to the pipeline so callers can pipe further.
$results
