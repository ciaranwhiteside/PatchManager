#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Patch Manager v1.5.0 - Personal/commercial app and Windows patching for Windows 10/11

.DESCRIPTION
    Evidence-led patching for Windows, Microsoft 365, browsers, WinGet
    packages, Microsoft Store apps, alternate package managers, native vendor
    updaters, and (opt-in) OEM firmware, with audit-ready reporting.

    Key features:
      - Ring-based staged rollout: Pilot -> Early -> Broad
      - CISA KEV emergency bypass, gated on a confirmed version match: KEV names
        affected products, NVD's CPE ranges decide whether this build is affected
      - Inventory-wide KEV visibility for software with no available update
      - SLA tracking against update availability date (not CVE dates)
      - Local + centralised logging and HTML/JSON/CSV compliance reporting
      - Fleet dashboard via the companion Get-FleetReport.ps1
      - System restore points before patching
      - Pre-flight checks: disk, battery, connectivity, pending reboot, winget
      - Optional webhook notifications and validated opt-in self-update
      - Extra sources: Chocolatey/Scoop, the Python Install Manager (`py`, which
        owns Store-installed Python that WinGet cannot see), native vendor
        updaters (Adobe, Zoom), opt-in OEM firmware (Dell/HP/Lenovo), and
        report-only staleness checks
      - End-of-life intelligence from endoflife.date: flags out-of-support
        Windows, dev runtimes, and inventory software, plus patch-level drift
        inside a still-supported release line (report-only, cached)
      - Commercial profile extras: run-scoped BITS throttling and
        hostname-seeded jitter to stagger estate-wide concurrent runs

    Scope is profile-driven:
      Personal (default)  - full coverage for a single machine.
      Commercial          - full coverage plus fleet behaviours (BITS
                            throttling, jitter staggering). The safe default
                            for organisations.
      CommercialManaged   - for estates where Intune/SCCM/RMM already owns
                            OS, Office, and browser patching; PatchManager
                            descopes those (audit-visible) and covers the
                            third-party app gap. Fine-grained exclusions go
                            in the Descope configuration.

.PARAMETER ConfigPath
    Path to JSON config override file. Defaults to .\PatchManager.config.json

.PARAMETER DryRun
    Simulate all actions without making changes.

.PARAMETER ForceRing
    Override automatic ring detection. Values: Pilot, Early, Broad

.PARAMETER ReportOnly
    Generate compliance report without patching.

.PARAMETER Force
    Bypass maintenance window check.

.PARAMETER InstallStartupTask
    Register a scheduled task that runs PatchManager at startup and logon.

.PARAMETER UninstallStartupTask
    Remove the scheduled task previously registered with -InstallStartupTask.

.EXAMPLE
    .\Invoke-PatchManager.ps1 -DryRun -Force

.EXAMPLE
    .\Invoke-PatchManager.ps1 -Force

.NOTES
    Exit Codes:
        0    Success
        1    Completed with errors
        2    Pre-flight failure - no changes made
        3010 Success - reboot required
        99   Fatal unhandled exception

    Windows Event Log IDs (source: PatchManager, log: Application) - for SIEM correlation:
        1000  Run started
        1001  Error (general)
        1002  Warning (general)
        1010  Run completed successfully
        1011  Run completed with errors
        1020  SLA breach detected
        1030  PatchManager self-updated
        3010  Reboot required
        9001  CISA KEV EMERGENCY - actively exploited vuln matched on this host
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\PatchManager.config.json",
    [switch]$DryRun,
    [ValidateSet('Pilot', 'Early', 'Broad')]
    [string]$ForceRing,
    [switch]$ReportOnly,
    [switch]$Force,
    [switch]$InstallStartupTask,
    [switch]$UninstallStartupTask,
    [string]$TaskName = 'PatchManager Personal',
    [int]$TaskDelayMinutes = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# PS 5.1 on older Windows 10 builds can default to TLS 1.0, which the CISA KEV
# feed and most HTTPS endpoints now reject. Enforce TLS 1.2+ for this session.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

#region -- Script State ---------------------------------------------------------------

$script:VERSION       = '1.5.0'
$script:STARTTIME     = Get-Date
$script:HOSTNAME      = $env:COMPUTERNAME
$script:WINGET        = $null
$script:RING          = 'Unknown'
$script:CFG           = $null
$script:LOGFILE       = $null
$script:EmergencyPatch = $false
$script:Mutex         = $null
$script:SkippedUpgradeResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:SourceCheckResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:LastUpdateStatus = $null
$script:LastUpdateReason = ''
$script:BITSPolicyBackup = $null
$script:BITSPolicyApplied = $false
$script:WinGetSupportsCustom = $false
$script:InventoryKEVMatches = @()
$script:NVDMemo = @{}                              # CVE id -> cpeMatch array (or $null)
$script:NVDLookupCount = 0
$script:NVDLastRequest = [datetime]::MinValue
$script:StalenessFindings = @()
$script:EndOfLifeFindings = @()
$script:Inventory = @()
$script:SelfUpdateStatus = 'Not checked'

$script:Stats = [ordered]@{
    UpdatesPlanned  = 0
    UpdatesApplied  = 0
    UpdatesFailed   = 0
    UpdatesSkipped  = 0
    KEVMatches      = 0   # confirmed-affected actionable matches (drives emergency)
    KEVCandidates   = 0   # name-only KEV catalogue hits, before version resolution
    SLABreaches     = 0
    InventoryCount  = 0
    Errors          = [System.Collections.Generic.List[string]]::new()
}

$script:ExitCode = 0

#endregion

#region -- Default Configuration -----------------------------------------------------

$script:DefaultCfg = [ordered]@{

    ScopeProfile = 'Personal'

    Descope = [ordered]@{
        PackageIds          = @()
        PackageNamePatterns = @()
        Providers           = @()
        Sources             = @()
        Reasons             = [ordered]@{}
    }

    Ring = [ordered]@{
        RegistryPath = 'HKLM:\SOFTWARE\Company\PatchManager'
        RegistryKey  = 'DeploymentRing'
        Default      = 'Pilot'
        Delays       = [ordered]@{ Pilot = 0; Early = 3; Broad = 7 }
    }

    MaintenanceWindow = [ordered]@{
        Enabled          = $true
        StartHour        = 22
        EndHour          = 6
        AllowedDays      = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        # Jitter staggers estate-wide runs so a fleet doesn't hit the network at
        # once. $null = decide by profile (Personal: 0 - a single device gains
        # nothing from delaying itself; Commercial: 120).
        JitterMaxMinutes = $null
    }

    Network = [ordered]@{
        # BITS throttling is a machine-wide policy. It is applied for the run and
        # reverted afterwards. $null = decide by profile (Personal: off, so a home
        # device never throttles itself; Commercial: on, to protect shared links).
        BITSThrottleEnabled    = $null
        BITSMaxBandwidthKbps   = 4096
        TestConnectivityUrl    = 'https://www.cloudflare.com'
        ConnectivityTimeoutSec = 10
    }

    WinGet = [ordered]@{
        ExcludePackagePrefixes = @(
            'Microsoft.AppInstaller'
            'Microsoft.WindowsAppRuntime'
            'Microsoft.VCLibs'
            'Microsoft.UI.Xaml'
        )
        ApprovedPackages      = @()
        PublisherManagedPackageIds = @(
            'Google.AndroidStudio'
        )
        IncludeMSStore        = $true
        Scope                 = 'machine'
        AcceptAgreements      = $true
        PackageTimeoutSeconds = 300
        MaxUpdatesPerRun      = 0
        SuppressReboot        = $true    # Add /norestart - PatchManager flags reboots, never forces them
        MaxRetries            = 2        # Attempts per package (1 = no retry) for transient failures
    }

    PackageManagers = [ordered]@{
        # Chocolatey: the CLI is free, but Chocolatey for Business is a paid
        # product. $null = decide by profile - Personal on (free use), Commercial
        # /CommercialManaged off pending an explicit opt-in, so enabling it in a
        # commercial context is a conscious licence decision that is yours to make.
        ChocolateyEnabled = $null
        ScoopEnabled      = $true        # Scoop is per-user; only runs in a user-context session
        # Python Install Manager (`py`). Store/pymanager-installed runtimes are
        # invisible to WinGet - the msstore source reports the channel tag
        # ('3.14-64') as the version, so a 3.14.5 -> 3.14.6 patch is never seen.
        # Only PythonCore runtimes that pymanager itself manages are touched;
        # unmanaged runtimes (uv/Astral, python.org MSI) are reported, never updated.
        PythonManagerEnabled = $true
        TimeoutSeconds    = 300
        MaxUpdatesPerRun  = 0            # 0 = unlimited
    }

    WindowsUpdate = [ordered]@{
        Enabled                = $true
        IncludeDrivers         = $false
        IncludeOptionalUpdates = $false
        IncludeFeatureUpdates  = $false
        SearchCriteria         = "IsInstalled=0 and IsHidden=0 and Type='Software'"
        TimeoutSeconds         = 3600
    }

    Microsoft365 = [ordered]@{
        Enabled               = $true
        ForceAppShutdown      = $false
        TimeoutSeconds        = 1800
    }

    Browsers = [ordered]@{
        Enabled               = $true
        ChromeEnabled         = $true
        EdgeEnabled           = $true
        NativeTimeoutSeconds  = 900
    }

    VendorUpdaters = [ordered]@{
        # Drives the silent updaters shipped by specific vendors (Adobe, Zoom...)
        # for apps not covered by an actionable WinGet candidate. Off under
        # CommercialManaged. Add your own entries via ExtraCatalogue (same shape
        # as the built-in entries: Name, PackageId, Provider, WinGetOverlapId,
        # VersionRegistryPaths, VersionValueName, UpdaterPathCandidates, UpdaterArgs).
        Enabled              = $true
        NativeTimeoutSeconds = 900
        ExtraCatalogue       = @()
    }

    UserExperience = [ordered]@{
        Enabled              = $true
        PromptOnAppInUse     = $true
        CompletionPopup      = $true
        OpenReportPrompt     = $true
        PromptTimeoutSeconds = 900
        ShowOnDryRun         = $true
    }

    MicrosoftStore = [ordered]@{
        Enabled          = $true
        Provider         = 'Auto'      # Prefer Store CLI bulk updates, then MDM bridge fallback
        TimeoutSeconds   = 180
        UseCimFallback   = $true
        CaptureAppxDiff  = $true
        PostUpdateSettleSeconds = 20
    }

    StalenessReport = [ordered]@{
        # Report-only exposure checks. Never patches anything - findings appear
        # in their own report section so they never affect applied/failed counts.
        # On for all profiles (evidence and safety net, like the inventory KEV scan).
        Enabled                 = $true
        DefenderSignatures      = $true
        DefenderMaxAgeDays      = 7
        FeatureUpdateLag        = $true
        FeatureUpdateMaxAgeDays = 365
        DevRuntimes             = $true
    }

    EndOfLife = [ordered]@{
        # Report-only end-of-life/end-of-support intelligence from endoflife.date.
        # Flags software whose whole release line is no longer supported (an app
        # can be fully patched yet sit on an abandoned major version). Never
        # patches - EOL means "plan a major-version upgrade" - so findings appear
        # in their own report section and never affect applied/failed counts.
        # On for all profiles. Data is cached and the run stays offline-safe.
        Enabled             = $true
        ApiBaseUrl          = 'https://endoflife.date/api/v1'
        CacheHours          = 168     # 7 days; lifecycle data changes slowly
        CachePath           = 'C:\ProgramData\PatchManager\Cache'
        WarnWithinDays      = 90      # near-EOL warning window before the EOL date
        CheckWindows        = $true   # authoritative Windows OS end-of-support
        CheckRuntimes       = $true   # .NET / Python / Node.js cycles
        InventoryScan       = $true   # best-effort match of the full software inventory
        InventoryMaxLookups = 40      # cap network lookups per run (noise/perf guard)
        Offline             = $false  # $true = use cache only, never fetch
    }

    Firmware = [ordered]@{
        # OEM firmware/BIOS/driver updates via the vendor's CLI (Dell Command
        # Update, HP Image Assistant, Lenovo System Update). OFF by default for
        # EVERY profile: firmware can require AC power and reboots and carries
        # real risk. Enable deliberately. Never reboots on its own; PatchManager
        # flags reboot-required as usual. Skipped when the device is on battery.
        Enabled        = $false
        TimeoutSeconds = 1800
    }

    SLA = [ordered]@{
        # Days from update becoming available to it being applied
        # Same window for all severities - if an update exists, apply it promptly
        Critical = 14
        High     = 14
        Medium   = 14
        Low      = 14
    }

    Logging = [ordered]@{
        LocalLogPath   = 'C:\ProgramData\PatchManager\Logs'
        CentralLogPath = ''
        EventLogName   = 'Application'
        EventLogSource = 'PatchManager'
        RetentionDays  = 90
        LogLevel       = 'Info'
    }

    Reporting = [ordered]@{
        LocalReportPath   = 'C:\ProgramData\PatchManager\Reports'
        CentralReportPath = ''
        GenerateHTML      = $true
        GenerateJSON      = $true
        GenerateCSV       = $true
    }

    Notifications = [ordered]@{
        Enabled        = $false
        WebhookUrl     = ''
        OnlyOnProblems = $true
        TimeoutSec     = 15
    }

    SelfUpdate = [ordered]@{
        # Keep PatchManager itself current from GitHub - a stale patch tool is a
        # liability. $null = decide by profile: Personal and Commercial on,
        # CommercialManaged off (a managed estate's platform should own how
        # PatchManager is deployed, not self-update from the internet).
        # Ref 'latest' tracks the latest PUBLISHED release tag (never a moving
        # branch and never a pre-release), so only cut releases ship. Set Ref to
        # a specific tag to pin, or to 'main' to track the branch. Downloads are
        # version-gated and parse-validated; pin ExpectedSha256 to lock an exact
        # build. A new script is never executed in the run that fetched it.
        Enabled        = $null
        Repository     = 'ciaranwhiteside/PatchManager'
        Ref            = 'latest'
        AutoApply      = $true    # $false = only report that an update exists
        ExpectedSha256 = ''       # Pin the expected file hash for locked-down estates
        TimeoutSec     = 30
    }

    State = [ordered]@{
        StatePath = 'C:\ProgramData\PatchManager\State'
        StateFile = 'patch_state.json'
    }

    PreFlight = [ordered]@{
        MinFreeSpaceGB       = 5
        CheckBattery         = $true
        MinBatteryPercent    = 20
        RequireACPower       = $false
        AbortOnPendingReboot = $true
        # Idle check - useful for laptops / shift workers on a scheduled task
        # Set true so the task only proceeds when user has stepped away
        RequireUserIdle      = $false
        MinIdleMinutes       = 5
    }

    SystemRestore = [ordered]@{
        Enabled     = $true
        Description = 'PatchManager pre-patch checkpoint'
    }

    CISAKEV = [ordered]@{
        Enabled    = $true
        FeedUrl    = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json'
        CacheHours = 24
        CachePath  = 'C:\ProgramData\PatchManager\Cache'
    }

    # The KEV catalogue carries no affected-version data, so a KEV hit alone only
    # proves the PRODUCT has known-exploited history - never that the INSTALLED
    # version is vulnerable. NVD supplies the CPE version ranges that settle it.
    # Disabling this leaves every candidate 'Unknown': reported, never an emergency.
    NVD = [ordered]@{
        Enabled          = $true
        ApiBaseUrl       = 'https://services.nvd.nist.gov/rest/json/cves/2.0'
        ApiKey           = ''      # optional; raises the rate limit from 5 to 50 req/30s
        CacheHours       = 720     # CPE ranges for a published CVE rarely change
        CachePath        = 'C:\ProgramData\PatchManager\Cache'
        Offline          = $false
        MaxLookupsPerRun = 25
        RequestDelayMs   = 6500    # unkeyed NVD allows ~5 requests / 30s
    }
}

#endregion

#region -- Configuration --------------------------------------------------------------

function Import-Configuration {
    param([string]$Path)
    $cfg = $script:DefaultCfg
    if (Test-Path $Path) {
        try {
            $overrides = Get-Content $Path -Raw -EA Stop | ConvertFrom-Json
            foreach ($section in $overrides.PSObject.Properties) {
                if ($section.Name -like '_*') { continue }  # Skip comment keys
                if ($cfg.Contains($section.Name)) {
                    $sectionIsObject = $null -ne $section.Value -and
                                       -not ($section.Value -is [string]) -and
                                       -not ($section.Value -is [System.Array]) -and
                                       @($section.Value.PSObject.Properties).Count -gt 0
                    if ($cfg[$section.Name] -is [System.Collections.IDictionary] -and $sectionIsObject) {
                        foreach ($key in $section.Value.PSObject.Properties) {
                            if ($key.Name -like '_*') { continue }  # Skip comment keys
                            $cfg[$section.Name][$key.Name] = $key.Value
                        }
                    } else {
                        $cfg[$section.Name] = $section.Value
                    }
                }
            }
            Write-Host "[CONFIG] Overrides loaded from: $Path" -ForegroundColor Cyan
        }
        catch { Write-Warning "[CONFIG] Failed to parse '$Path': $_. Defaults used." }
    }
    Set-ScopeProfileDefaults -Config $cfg
    return $cfg
}

function Test-IsFleetProfile {
    # Commercial and CommercialManaged share the fleet behaviours (BITS
    # throttling, jitter staggering, Descoped-vs-Skipped report language).
    param([string]$ScopeProfile)
    return $ScopeProfile -ieq 'Commercial' -or $ScopeProfile -ieq 'CommercialManaged'
}

function Set-ScopeProfileDefaults {
    param([Parameter(Mandatory)] [object]$Config)

    $scopeProfile = [string]$Config.ScopeProfile
    if ([string]::IsNullOrWhiteSpace($scopeProfile)) { $scopeProfile = 'Personal' }
    if ($scopeProfile -notin @('Personal', 'Commercial', 'CommercialManaged')) {
        Write-Warning "[CONFIG] Unknown ScopeProfile '$scopeProfile'. Falling back to 'Personal' (full coverage)."
        $scopeProfile = 'Personal'
    }
    $Config.ScopeProfile = $scopeProfile

    # Profile intent:
    #   Personal          - full coverage, single machine, no fleet behaviours.
    #   Commercial        - full coverage PLUS fleet behaviours. The safe default
    #                       for organisations: an unpatched browser is a
    #                       vulnerability whether or not an RMM exists, so
    #                       nothing is descoped unless the org says so.
    #   CommercialManaged - for estates where Intune/SCCM/RMM already owns OS,
    #                       Office, and browser patching: those providers are
    #                       descoped (with audit-visible reasons) and PatchManager
    #                       covers the third-party gap. The inventory-wide CISA
    #                       KEV scan still reports exposure in managed software.
    if ($scopeProfile -ieq 'CommercialManaged') {
        $managedPackageIds = @(
            'Google.Chrome'
            'Microsoft.Edge'
            'Microsoft.EdgeWebView2Runtime'
            'Microsoft.Office'
            'Microsoft.Microsoft365'
            'Microsoft.Teams'
            'Microsoft.OneDrive'
        )
        $managedPatterns = @(
            '^Google\s+Chrome\b'
            '^Microsoft\s+Edge\b'
            '^Microsoft\s+Edge\s+WebView2\b'
            '^Microsoft\s+365\b'
            '^Microsoft\s+Office\b'
            '^Microsoft\s+Teams\b'
            '^Teams\s+Machine-Wide\s+Installer$'
            '^Microsoft\s+OneDrive\b'
        )

        $Config.Descope.PackageIds = @($Config.Descope.PackageIds + $managedPackageIds | Select-Object -Unique)
        $Config.Descope.PackageNamePatterns = @($Config.Descope.PackageNamePatterns + $managedPatterns | Select-Object -Unique)
        $Config.WindowsUpdate.Enabled = $false
        $Config.Microsoft365.Enabled = $false
        $Config.Browsers.ChromeEnabled = $false
        $Config.Browsers.EdgeEnabled = $false
        # Patching providers added in 1.2.0 follow the same managed-estate rule:
        # a management platform is assumed to own them. Report-only checks stay on.
        if ($null -ne (Get-ObjectPropertyValue $Config 'PackageManagers' $null)) {
            $Config.PackageManagers.ScoopEnabled = $false
        }
        if ($null -ne (Get-ObjectPropertyValue $Config 'VendorUpdaters' $null)) {
            $Config.VendorUpdaters.Enabled = $false
        }
    }

    # Resolve profile-dependent defaults left as $null in the base config.
    $isFleet = Test-IsFleetProfile -ScopeProfile $scopeProfile
    if ($null -eq (Get-ObjectPropertyValue $Config.Network 'BITSThrottleEnabled' $null)) {
        $Config.Network.BITSThrottleEnabled = $isFleet
    }
    if ($null -eq (Get-ObjectPropertyValue $Config.MaintenanceWindow 'JitterMaxMinutes' $null)) {
        $Config.MaintenanceWindow.JitterMaxMinutes = if ($isFleet) { 120 } else { 0 }
    }
    # Chocolatey: Personal on (free), any commercial profile off pending an
    # explicit licence opt-in. An explicit true/false in config always wins.
    $pkgMgr = Get-ObjectPropertyValue $Config 'PackageManagers' $null
    if ($null -ne $pkgMgr -and $null -eq (Get-ObjectPropertyValue $pkgMgr 'ChocolateyEnabled' $null)) {
        $Config.PackageManagers.ChocolateyEnabled = (-not $isFleet)
    }
    # Self-update: on for Personal and Commercial, off for CommercialManaged
    # (a managed estate's platform should own PatchManager's deployment).
    $su = Get-ObjectPropertyValue $Config 'SelfUpdate' $null
    if ($null -ne $su -and $null -eq (Get-ObjectPropertyValue $su 'Enabled' $null)) {
        $Config.SelfUpdate.Enabled = ($scopeProfile -ine 'CommercialManaged')
    }
}

#endregion

#region -- Logging --------------------------------------------------------------------

function Initialize-Logging {
    $logDir = $script:CFG.Logging.LocalLogPath
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LOGFILE = Join-Path $logDir ("PatchManager_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    $src = $script:CFG.Logging.EventLogSource
    if (-not [Diagnostics.EventLog]::SourceExists($src)) {
        try { New-EventLog -LogName $script:CFG.Logging.EventLogName -Source $src -EA SilentlyContinue }
        catch { }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    $levelMap = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3; SUCCESS = 1 }
    $threshold = switch ($script:CFG.Logging.LogLevel) {
        'Debug'   { 0 } 'Warning' { 2 } 'Error' { 3 } default { 1 }
    }
    if ($levelMap[$Level] -lt $threshold) { return }

    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][$Level][$($script:HOSTNAME)] $Message"

    try { Add-Content -Path $script:LOGFILE -Value $entry -EA SilentlyContinue } catch { }

    $colour = switch ($Level) {
        'DEBUG'   { 'Gray'   }
        'INFO'    { 'Cyan'   }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        'SUCCESS' { 'Green'  }
    }
    Write-Host $entry -ForegroundColor $colour

    if ($Level -in 'ERROR','WARN') {
        $type = if ($Level -eq 'ERROR') { 'Error' } else { 'Warning' }
        $id   = if ($Level -eq 'ERROR') { 1001 } else { 1002 }
        try {
            Write-EventLog -LogName $script:CFG.Logging.EventLogName `
                           -Source $script:CFG.Logging.EventLogSource `
                           -EventId $id -EntryType $type -Message $Message -EA SilentlyContinue
        } catch { }
    }

    if ($Level -eq 'ERROR') {
        $script:Stats.Errors.Add($Message)
        $script:ExitCode = 1
    }
}

function Copy-LogsToCentral {
    $central = $script:CFG.Logging.CentralLogPath
    if ([string]::IsNullOrWhiteSpace($central)) { return }
    $dest = Join-Path $central $script:HOSTNAME

    # Retry - transient SMB/network hiccups are common on large estates.
    # Never let a failed central copy fail the whole run; local copy always exists.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force -EA Stop | Out-Null }
            Copy-Item $script:LOGFILE -Destination $dest -Force -EA Stop
            Write-Log "Log copied to central store: $dest" -Level INFO
            return
        }
        catch {
            if ($attempt -eq 3) {
                Write-Log "Central log copy failed after 3 attempts: $_. Local log retained." -Level WARN
            } else {
                Start-Sleep -Seconds ($attempt * 2)
            }
        }
    }
}

function Remove-OldFiles {
    param([string]$Path, [string]$Filter, [int]$Days)
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem -Path $Path -Filter $Filter -EA SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } |
        Remove-Item -Force -EA SilentlyContinue
}

function Write-RunEvent {
    # Writes a structured event to the Windows Event Log for SIEM correlation.
    # Separate from Write-Log's inline ERROR/WARN events - these are lifecycle markers.
    param(
        [int]$EventId,
        [ValidateSet('Information','Warning','Error')]
        [string]$Type = 'Information',
        [string]$Message
    )
    try {
        Write-EventLog -LogName $script:CFG.Logging.EventLogName `
                       -Source  $script:CFG.Logging.EventLogSource `
                       -EventId $EventId -EntryType $Type -Message $Message -EA SilentlyContinue
    } catch { }
}

#endregion

#region -- Single-Instance Guard ------------------------------------------------------

function Enter-SingleInstance {
    # Prevents two overlapping runs (e.g. scheduled task fires while a manual run
    # is in progress) from corrupting the state file. Global mutex = machine-wide.
    $mutexName = 'Global\PatchManager_SingleInstance'
    try {
        $created = $false
        $script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
        if (-not $created) {
            # Someone else holds it - try to acquire for up to 5 seconds
            if (-not $script:Mutex.WaitOne(5000)) {
                Write-Log 'Another PatchManager instance is already running. Exiting.' -Level WARN
                return $false
            }
        }
        return $true
    } catch {
        # AbandonedMutexException means a previous run crashed holding the mutex - safe to proceed
        if ($_.Exception -is [System.Threading.AbandonedMutexException]) {
            Write-Log 'Recovered abandoned lock from a previous crashed run. Proceeding.' -Level WARN
            return $true
        }
        Write-Log "Mutex acquisition failed: $_. Proceeding without lock." -Level WARN
        return $true
    }
}

function Exit-SingleInstance {
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        try { $script:Mutex.Dispose() } catch { }
        $script:Mutex = $null
    }
}

#endregion

#region -- Atomic File Write -----------------------------------------------------------

function Set-ContentAtomic {
    # Writes to a temp file then moves it into place, so a crash mid-write can't
    # corrupt the target (e.g. the state file). Move is atomic on NTFS.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Content
    )
    $tmp = "$Path.tmp"
    try {
        Set-Content -Path $tmp -Value $Content -Encoding UTF8 -EA Stop
        Move-Item -Path $tmp -Destination $Path -Force -EA Stop
        return $true
    } catch {
        Write-Log "Atomic write failed for '$Path': $_" -Level WARN
        Remove-Item $tmp -Force -EA SilentlyContinue
        return $false
    }
}

#endregion

#region --- User Experience / Scheduling ------------------------------------

function Test-InteractiveSession {
    # Decides whether dialogs may be shown. Deliberately does NOT rely on the
    # session-name environment variable: Task Scheduler processes never receive
    # it, even in a fully interactive user session, which would wrongly suppress
    # the completion popup on every scheduled run. Session 0 (services/SYSTEM)
    # is where dialogs must stay off; interactive users are session 1+.
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ((Get-Process -Id $PID).SessionId -le 0) { return $false }
        return $true
    } catch { return $false }
}

function Show-PatchManagerDialog {
    param(
        [string]$Title,
        [string]$Heading,
        [string]$Message,
        [string]$PrimaryText = 'OK',
        [string]$SecondaryText = '',
        [int]$TimeoutSeconds = 0
    )

    if (-not $script:CFG.UserExperience.Enabled -or -not (Test-InteractiveSession)) { return 'Unavailable' }

    try {
        Add-Type -AssemblyName System.Windows.Forms -EA Stop
        Add-Type -AssemblyName System.Drawing -EA Stop

        $brandInk = [System.Drawing.Color]::FromArgb(17, 21, 19)
        $brandPaper = [System.Drawing.Color]::FromArgb(246, 242, 232)
        $brandPaperSoft = [System.Drawing.Color]::FromArgb(236, 230, 216)
        $brandBlue = [System.Drawing.Color]::FromArgb(24, 50, 74)
        $brandGreen = [System.Drawing.Color]::FromArgb(36, 116, 79)
        $brandMuted = [System.Drawing.Color]::FromArgb(91, 100, 94)
        $brandLine = [System.Drawing.Color]::FromArgb(199, 190, 171)

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size(580, 330)
        $form.MinimumSize = New-Object System.Drawing.Size(580, 330)
        $form.TopMost = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.BackColor = $brandPaper

        $header = New-Object System.Windows.Forms.Panel
        $header.Dock = 'Top'
        $header.Height = 96
        $header.BackColor = $brandInk
        [void]$form.Controls.Add($header)

        $brandIcon = New-Object System.Windows.Forms.Panel
        $brandIcon.Location = New-Object System.Drawing.Point(24, 22)
        $brandIcon.Size = New-Object System.Drawing.Size(52, 52)
        $brandIcon.BackColor = $brandPaper
        $brandIcon.Add_Paint({
            param($sender, $paintEvent)
            $graphics = $paintEvent.Graphics
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

            $ink = [System.Drawing.Color]::FromArgb(17, 21, 19)
            $paper = [System.Drawing.Color]::FromArgb(246, 242, 232)
            $blue = [System.Drawing.Color]::FromArgb(24, 50, 74)
            $green = [System.Drawing.Color]::FromArgb(36, 116, 79)
            $amber = [System.Drawing.Color]::FromArgb(196, 154, 61)

            $backgroundBrush = New-Object System.Drawing.SolidBrush($paper)
            $graphics.FillRectangle($backgroundBrush, 0, 0, 52, 52)

            $shield = New-Object System.Drawing.Drawing2D.GraphicsPath
            $shield.AddPolygon([System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point(26, 4)),
                (New-Object System.Drawing.Point(43, 11)),
                (New-Object System.Drawing.Point(43, 24)),
                (New-Object System.Drawing.Point(39, 36)),
                (New-Object System.Drawing.Point(26, 48)),
                (New-Object System.Drawing.Point(13, 36)),
                (New-Object System.Drawing.Point(9, 24)),
                (New-Object System.Drawing.Point(9, 11))
            ))
            $shieldBrush = New-Object System.Drawing.SolidBrush($ink)
            $graphics.FillPath($shieldBrush, $shield)

            $inner = New-Object System.Drawing.Drawing2D.GraphicsPath
            $inner.AddPolygon([System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point(26, 10)),
                (New-Object System.Drawing.Point(37, 15)),
                (New-Object System.Drawing.Point(37, 25)),
                (New-Object System.Drawing.Point(34, 33)),
                (New-Object System.Drawing.Point(26, 41)),
                (New-Object System.Drawing.Point(18, 33)),
                (New-Object System.Drawing.Point(15, 25)),
                (New-Object System.Drawing.Point(15, 15))
            ))
            $innerBrush = New-Object System.Drawing.SolidBrush($paper)
            $graphics.FillPath($innerBrush, $inner)

            $docBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
            $docPen = New-Object System.Drawing.Pen($blue, 2)
            $doc = New-Object System.Drawing.Drawing2D.GraphicsPath
            $doc.AddPolygon([System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point(20, 15)),
                (New-Object System.Drawing.Point(29, 15)),
                (New-Object System.Drawing.Point(34, 20)),
                (New-Object System.Drawing.Point(34, 34)),
                (New-Object System.Drawing.Point(20, 34))
            ))
            $graphics.FillPath($docBrush, $doc)
            $graphics.DrawPath($docPen, $doc)
            $graphics.DrawLine($docPen, 29, 15, 29, 20)
            $graphics.DrawLine($docPen, 29, 20, 34, 20)

            $checkPen = New-Object System.Drawing.Pen($green, 3)
            $checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawLines($checkPen, [System.Drawing.Point[]]@(
                (New-Object System.Drawing.Point(20, 28)),
                (New-Object System.Drawing.Point(24, 32)),
                (New-Object System.Drawing.Point(33, 22))
            ))

            $ledgerPen = New-Object System.Drawing.Pen($amber, 2)
            $ledgerPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ledgerPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ledgerPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawBeziers($ledgerPen, [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF(15.5, 37.8)),
                (New-Object System.Drawing.PointF(18.3, 41.0)),
                (New-Object System.Drawing.PointF(21.9, 43.5)),
                (New-Object System.Drawing.PointF(26.0, 45.5)),
                (New-Object System.Drawing.PointF(30.1, 43.5)),
                (New-Object System.Drawing.PointF(33.7, 41.0)),
                (New-Object System.Drawing.PointF(36.5, 37.8))
            ))

            $backgroundBrush.Dispose()
            $shieldBrush.Dispose()
            $innerBrush.Dispose()
            $docBrush.Dispose()
            $docPen.Dispose()
            $doc.Dispose()
            $checkPen.Dispose()
            $ledgerPen.Dispose()
            $shield.Dispose()
            $inner.Dispose()
        })
        [void]$header.Controls.Add($brandIcon)

        $brandTitle = New-Object System.Windows.Forms.Label
        $brandTitle.Text = 'PatchManager'
        $brandTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $brandTitle.ForeColor = $brandPaper
        $brandTitle.Location = New-Object System.Drawing.Point(92, 22)
        $brandTitle.Size = New-Object System.Drawing.Size(440, 25)
        [void]$header.Controls.Add($brandTitle)

        $taglineLabel = New-Object System.Windows.Forms.Label
        $taglineLabel.Text = 'Patch. Verify. Prove it.'
        $taglineLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $taglineLabel.ForeColor = $brandPaperSoft
        $taglineLabel.Location = New-Object System.Drawing.Point(94, 52)
        $taglineLabel.Size = New-Object System.Drawing.Size(420, 22)
        [void]$header.Controls.Add($taglineLabel)

        $accent = New-Object System.Windows.Forms.Panel
        $accent.Location = New-Object System.Drawing.Point(0, 92)
        $accent.Size = New-Object System.Drawing.Size(580, 4)
        $accent.BackColor = $brandBlue
        [void]$header.Controls.Add($accent)

        $headingLabel = New-Object System.Windows.Forms.Label
        $headingLabel.Text = $Heading
        $headingLabel.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $headingLabel.ForeColor = $brandInk
        $headingLabel.Location = New-Object System.Drawing.Point(24, 116)
        $headingLabel.Size = New-Object System.Drawing.Size(528, 34)
        [void]$form.Controls.Add($headingLabel)

        $messageLabel = New-Object System.Windows.Forms.Label
        $messageLabel.Text = $Message
        $messageLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $messageLabel.ForeColor = $brandMuted
        $messageLabel.Location = New-Object System.Drawing.Point(26, 154)
        $messageLabel.Size = New-Object System.Drawing.Size(526, 84)
        $messageLabel.AutoEllipsis = $true
        [void]$form.Controls.Add($messageLabel)

        $evidenceLabel = New-Object System.Windows.Forms.Label
        $evidenceLabel.Text = 'Evidence-led Windows patching'
        $evidenceLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
        $evidenceLabel.ForeColor = $brandMuted
        $evidenceLabel.Location = New-Object System.Drawing.Point(26, 260)
        $evidenceLabel.Size = New-Object System.Drawing.Size(200, 22)
        [void]$form.Controls.Add($evidenceLabel)

        $result = 'Secondary'
        $primary = New-Object System.Windows.Forms.Button
        $primary.Text = $PrimaryText
        $primary.Size = New-Object System.Drawing.Size(150, 38)
        $primary.Location = New-Object System.Drawing.Point(402, 252)
        $primary.BackColor = $brandGreen
        $primary.ForeColor = [System.Drawing.Color]::White
        $primary.FlatStyle = 'Flat'
        $primary.FlatAppearance.BorderSize = 0
        $primary.Add_Click({ $script:DialogResultValue = 'Primary'; $form.Close() })
        [void]$form.Controls.Add($primary)
        $form.AcceptButton = $primary   # Enter activates the primary action

        if (-not [string]::IsNullOrWhiteSpace($SecondaryText)) {
            $secondary = New-Object System.Windows.Forms.Button
            $secondary.Text = $SecondaryText
            $secondary.Size = New-Object System.Drawing.Size(150, 38)
            $secondary.Location = New-Object System.Drawing.Point(236, 252)
            $secondary.BackColor = $brandPaper
            $secondary.ForeColor = $brandInk
            $secondary.FlatStyle = 'Flat'
            $secondary.FlatAppearance.BorderColor = $brandLine
            $secondary.Add_Click({ $script:DialogResultValue = 'Secondary'; $form.Close() })
            [void]$form.Controls.Add($secondary)
            $form.CancelButton = $secondary   # Esc defers instead of being ignored
        }

        $script:DialogResultValue = $result
        $timer = $null
        if ($TimeoutSeconds -gt 0) {
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = $TimeoutSeconds * 1000
            $timer.Add_Tick({ $script:DialogResultValue = 'Timeout'; $form.Close() })
            $timer.Start()
        }

        [void]$form.ShowDialog()
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        return $script:DialogResultValue
    } catch {
        Write-Log "User prompt unavailable: $_" -Level DEBUG
        return 'Unavailable'
    }
}

function Show-AppInUsePrompt {
    param([string]$AppName, [string]$Evidence)

    if (-not $script:CFG.UserExperience.PromptOnAppInUse) { return 'Unavailable' }
    $timeout = [int]$script:CFG.UserExperience.PromptTimeoutSeconds
    $message = "PatchManager could not verify the update for '$AppName' because the app appears to be open or locked.`r`n`r`nClose the app, then choose Retry update. Choose Defer to leave evidence in this run and try again next time."
    if (-not [string]::IsNullOrWhiteSpace($Evidence)) {
        $message += "`r`n`r`nDetails: $Evidence"
    }
    return Show-PatchManagerDialog -Title 'PatchManager needs your input' `
                                   -Heading 'Close the app to verify the update' `
                                   -Message $message `
                                   -PrimaryText 'Retry update' `
                                   -SecondaryText 'Defer' `
                                   -TimeoutSeconds $timeout
}

function Show-CompletionPopup {
    param([string]$HtmlReportPath)

    if (-not $script:CFG.UserExperience.CompletionPopup) { return }
    if ($DryRun -and -not $script:CFG.UserExperience.ShowOnDryRun) { return }

    # Keep to two short paragraphs: the message label has a fixed height and
    # ellipsizes anything longer, which reads as a broken dialog.
    $message = "PatchManager finished this run and wrote the report evidence.`r`n`r`nApplied: $($script:Stats.UpdatesApplied)   Failed: $($script:Stats.UpdatesFailed)   Skipped: $($script:Stats.UpdatesSkipped)"
    $primaryText = if ($script:CFG.UserExperience.OpenReportPrompt) { 'Open report' } else { 'OK' }
    $secondaryText = if ($script:CFG.UserExperience.OpenReportPrompt) { 'Close' } else { '' }
    $choice = Show-PatchManagerDialog -Title 'PatchManager complete' `
                                      -Heading 'Patch evidence is ready' `
                                      -Message $message `
                                      -PrimaryText $primaryText `
                                      -SecondaryText $secondaryText `
                                      -TimeoutSeconds 0
    if ($script:CFG.UserExperience.OpenReportPrompt -and $choice -eq 'Primary' -and $HtmlReportPath -and (Test-Path $HtmlReportPath)) {
        try { Start-Process -FilePath $HtmlReportPath | Out-Null } catch { Write-Log "Could not open report '$HtmlReportPath': $_" -Level WARN }
    }
}

function Install-PatchManagerStartupTask {
    param([string]$Name, [int]$DelayMinutes)

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
        throw 'Cannot resolve PatchManager script path for scheduled task registration.'
    }

    # The task runs elevated with -ExecutionPolicy Bypass. If the script lives in a
    # user-writable location, anything running as that user can swap the file and
    # gain admin at next logon. Warn so users move it somewhere admin-only-writable.
    $userProfileRoot = [System.IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users'))
    $resolvedScript = [System.IO.Path]::GetFullPath($scriptPath)
    if ($resolvedScript.StartsWith($userProfileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "WARNING: The script is under a user profile ($resolvedScript)." -ForegroundColor Yellow
        Write-Host 'The scheduled task will run it elevated. Move it to an admin-only-writable' -ForegroundColor Yellow
        Write-Host 'location such as C:\ProgramData\PatchManager\ and re-run -InstallStartupTask.' -ForegroundColor Yellow
    }

    # Trigger delays must be ISO 8601 duration strings (PT2M); assigning a
    # TimeSpan serialises as 00:02:00, which the Task Scheduler rejects.
    $delayIso = 'PT{0}M' -f [Math]::Max(0, $DelayMinutes)
    # -WindowStyle Hidden keeps scheduled runs in the background instead of
    # parking a console on the user's screen. (Windows may still flash the
    # window for a moment at launch - a PowerShell limitation.) Completion
    # popups still appear; they are separate WinForms windows.
    $actionArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Force"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $startupTrigger.Delay = $delayIso
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $logonTrigger.Delay = $delayIso
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    $task = New-ScheduledTask -Action $action -Trigger @($startupTrigger, $logonTrigger) -Principal $principal -Settings $settings -Description 'Runs PatchManager at startup/logon for personal device patching.'

    Register-ScheduledTask -TaskName $Name -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "Scheduled task installed: $Name" -ForegroundColor Green
    Write-Host "Triggers: startup + user logon, ${DelayMinutes} minute delay, highest privileges." -ForegroundColor Cyan
}

function Uninstall-PatchManagerStartupTask {
    param([string]$Name)

    $existing = Get-ScheduledTask -TaskName $Name -EA SilentlyContinue
    if (-not $existing) {
        Write-Host "Scheduled task not found: $Name" -ForegroundColor Yellow
        return
    }
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    Write-Host "Scheduled task removed: $Name" -ForegroundColor Green
}

#endregion

#region --- Result Normalisation / Scope ------------------------------------

function Get-ObjectPropertyValue {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function New-PatchResult {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$Provider,
        [string]$Source,
        [string]$InstalledVersion = '',
        [string]$AvailableVersion = '',
        [string]$ReportedVersion = '',
        [string]$ConfirmedVersion = '',
        [string]$Status = 'Skipped',
        [bool]$Success = $false,
        [bool]$RebootRequired = $false,
        [string]$Evidence = '',
        [string]$Remediation = '',
        [bool]$IsKEV = $false
    )

    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = $Provider }
    if ([string]::IsNullOrWhiteSpace($Provider)) { $Provider = $Source }
    if ([string]::IsNullOrWhiteSpace($ReportedVersion)) { $ReportedVersion = $AvailableVersion }
    if ([string]::IsNullOrWhiteSpace($ConfirmedVersion) -and $Status -in @('Succeeded','Updated','Detected')) {
        $ConfirmedVersion = $AvailableVersion
    }

    [PSCustomObject]@{
        Name             = $Name
        PackageId        = $PackageId
        Provider         = $Provider
        Source           = $Source
        InstalledVersion = $InstalledVersion
        AvailableVersion = $AvailableVersion
        ReportedVersion  = $ReportedVersion
        ConfirmedVersion = $ConfirmedVersion
        OldVer           = $InstalledVersion
        NewVer           = if ($ConfirmedVersion) { $ConfirmedVersion } else { $AvailableVersion }
        Success          = $Success
        Status           = $Status
        RebootRequired   = $RebootRequired
        Evidence         = $Evidence
        Remediation      = $Remediation
        Reason           = (($Evidence, $Remediation | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ')
        IsKEV            = $IsKEV
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
}

function ConvertTo-PatchResult {
    param([Parameter(Mandatory)] $InputObject)

    $status = [string](Get-ObjectPropertyValue $InputObject 'Status' '')
    $success = [bool](Get-ObjectPropertyValue $InputObject 'Success' $false)
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = if ($success) { 'Succeeded' } else { 'Failed' }
    }

    $installed = [string](Get-ObjectPropertyValue $InputObject 'InstalledVersion' (Get-ObjectPropertyValue $InputObject 'OldVer' ''))
    $available = [string](Get-ObjectPropertyValue $InputObject 'AvailableVersion' (Get-ObjectPropertyValue $InputObject 'NewVer' ''))
    $evidence = [string](Get-ObjectPropertyValue $InputObject 'Evidence' (Get-ObjectPropertyValue $InputObject 'Reason' ''))

    New-PatchResult -Name (Get-ObjectPropertyValue $InputObject 'Name' '') `
                    -PackageId (Get-ObjectPropertyValue $InputObject 'PackageId' '') `
                    -Provider (Get-ObjectPropertyValue $InputObject 'Provider' (Get-ObjectPropertyValue $InputObject 'Source' 'unknown')) `
                    -Source (Get-ObjectPropertyValue $InputObject 'Source' (Get-ObjectPropertyValue $InputObject 'Provider' 'unknown')) `
                    -InstalledVersion $installed `
                    -AvailableVersion $available `
                    -ReportedVersion (Get-ObjectPropertyValue $InputObject 'ReportedVersion' $available) `
                    -ConfirmedVersion (Get-ObjectPropertyValue $InputObject 'ConfirmedVersion' '') `
                    -Status $status `
                    -Success $success `
                    -RebootRequired ([bool](Get-ObjectPropertyValue $InputObject 'RebootRequired' $false)) `
                    -Evidence $evidence `
                    -Remediation (Get-ObjectPropertyValue $InputObject 'Remediation' '') `
                    -IsKEV ([bool](Get-ObjectPropertyValue $InputObject 'IsKEV' $false))
}

function Test-IsDescoped {
    param(
        [Parameter(Mandatory)] $Item,
        [ref]$Reason
    )

    $name = [string](Get-ObjectPropertyValue $Item 'Name' '')
    $packageId = [string](Get-ObjectPropertyValue $Item 'PackageId' '')
    $provider = [string](Get-ObjectPropertyValue $Item 'Provider' '')
    $source = [string](Get-ObjectPropertyValue $Item 'Source' '')

    foreach ($id in @($script:CFG.Descope.PackageIds)) {
        if ($packageId -like "$id*") {
            $Reason.Value = Get-DescopeReason -Key $id -Default "Descoped by package id '$id'."
            return $true
        }
    }
    foreach ($pattern in @($script:CFG.Descope.PackageNamePatterns)) {
        if ($name -imatch $pattern) {
            $Reason.Value = Get-DescopeReason -Key $pattern -Default "Descoped by name pattern '$pattern'."
            return $true
        }
    }
    foreach ($p in @($script:CFG.Descope.Providers)) {
        if ($provider -ieq $p) {
            $Reason.Value = Get-DescopeReason -Key $p -Default "Descoped by provider '$p'."
            return $true
        }
    }
    foreach ($s in @($script:CFG.Descope.Sources)) {
        if ($source -ieq $s) {
            $Reason.Value = Get-DescopeReason -Key $s -Default "Descoped by source '$s'."
            return $true
        }
    }

    return $false
}

function Get-DescopeReason {
    param([string]$Key, [string]$Default)

    $reasons = Get-ObjectPropertyValue $script:CFG.Descope 'Reasons' $null
    if ($null -eq $reasons) { return $Default }

    if ($reasons -is [System.Collections.IDictionary] -and $reasons.Contains($Key)) {
        return [string]$reasons[$Key]
    }

    $prop = $reasons.PSObject.Properties[$Key]
    if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return [string]$prop.Value
    }

    return $Default
}

function Update-StatsFromResults {
    param([array]$Results)

    $script:Stats.UpdatesPlanned = @($Results | Where-Object { $_.Status -eq 'Planned' }).Count
    $script:Stats.UpdatesApplied = @($Results | Where-Object { $_.Status -in @('Succeeded','Updated','Detected') -and $_.Success }).Count
    $script:Stats.UpdatesFailed  = @($Results | Where-Object { $_.Status -in @('Failed','Blocked','Verifying') -or ($_.PSObject.Properties['Success'] -and -not $_.Success -and $_.Status -notin @('Skipped','Descoped','Planned')) }).Count
    $script:Stats.UpdatesSkipped = @($Results | Where-Object { $_.Status -in @('Skipped','Descoped','AlreadyCurrent') }).Count
}

#endregion

#region -- WinGet Resolution ----------------------------------------------------------

function Resolve-WinGetPath {
    # Try PATH first (interactive sessions)
    $cmd = Get-Command 'winget' -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # WindowsApps lookup for SYSTEM context (Intune/SCCM)
    $appBase = 'C:\Program Files\WindowsApps'
    if (Test-Path $appBase) {
        $latest = Get-ChildItem -Path $appBase `
                                -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' `
                                -EA SilentlyContinue |
                  Sort-Object Name -Descending |
                  Select-Object -First 1
        if ($latest) {
            $exe = Join-Path $latest.FullName 'winget.exe'
            if (Test-Path $exe) { return $exe }
        }
    }

    # User-context fallback
    $userExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $userExe) { return $userExe }

    return $null
}

#endregion

#region -- Pre-flight Checks ----------------------------------------------------------

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    )
    foreach ($k in $keys) {
        if (Test-Path $k) {
            Write-Log "Pending reboot indicator: $k" -Level DEBUG
            return $true
        }
    }

    # PendingFileRenameOperations is the weakest reboot signal: many benign
    # components queue file renames/deletes here that never actually require a
    # reboot and, worse, re-add themselves so a reboot does not clear them.
    # The Xbox "Gaming Services" proxy DLLs are the classic example - they would
    # otherwise pin the machine at "pending reboot" forever and block patching.
    # Skip empty entries (delete destinations) and these known-benign patterns.
    $benignPfroPatterns = @(
        'gamingservices'          # Xbox Gaming Services proxy/host DLL cleanup
        'gamingservicesproxy'
    )
    $benignPfroRegex = ($benignPfroPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                              -Name PendingFileRenameOperations -EA SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) {
        $realEntries = @($pfro.PendingFileRenameOperations | Where-Object {
            $entry = [string]$_
            (-not [string]::IsNullOrWhiteSpace($entry)) -and ($entry -inotmatch $benignPfroRegex)
        })
        if ($realEntries.Count -gt 0) {
            Write-Log "Pending file operation(s) ($($realEntries.Count)): $($realEntries[0])" -Level DEBUG
            return $true
        }
        Write-Log 'PendingFileRenameOperations present but only benign/empty entries; not treating as pending reboot.' -Level DEBUG
    }

    # SCCM client check (non-fatal if SCCM not installed)
    try {
        $ccm = [wmiclass]'\\.\root\ccm\clientsdk:CCM_ClientUtilities'
        $s   = $ccm.DetermineIfRebootPending()
        if ($s.RebootPending -or $s.IsHardRebootPending) {
            Write-Log 'Pending reboot indicator: SCCM client' -Level DEBUG
            return $true
        }
    } catch { }

    return $false
}

function Get-UserIdleMinutes {
    # P/Invoke to Win32 GetLastInputInfo - works from SYSTEM context
    $typeDef = @"
using System;
using System.Runtime.InteropServices;
public class Win32Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();
    public static ulong GetIdleMilliseconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        GetLastInputInfo(ref lii);
        // dwTime is a 32-bit tick that wraps every ~49.7 days; compare in the
        // same 32-bit space, using GetTickCount64 for the current time source.
        uint now = (uint)(GetTickCount64() & 0xFFFFFFFF);
        return (ulong)unchecked(now - lii.dwTime);
    }
}
"@
    if (-not ([System.Management.Automation.PSTypeName]'Win32Idle').Type) {
        Add-Type -TypeDefinition $typeDef -Language CSharp -EA SilentlyContinue
    }
    try {
        return [Math]::Round([Win32Idle]::GetIdleMilliseconds() / 60000)
    } catch {
        return 999  # If we can't check, assume idle
    }
}

function Invoke-PreFlightChecks {
    Write-Log '--- Pre-flight checks starting ---' -Level INFO
    $pass = $true
    $pf   = $script:CFG.PreFlight

    # 1. Pending reboot
    if ($pf.AbortOnPendingReboot) {
        if (Test-PendingReboot) {
            Write-Log 'PREFLIGHT FAIL: Pending reboot detected. Deferring to avoid state corruption.' -Level WARN
            $pass = $false
        } else {
            Write-Log 'Pending reboot: None detected.' -Level INFO
        }
    }

    # 2. Free disk space
    $drive = ($env:SystemDrive).TrimEnd(':')
    $disk  = Get-PSDrive $drive -EA SilentlyContinue
    if ($disk) {
        $freeGB = [Math]::Round($disk.Free / 1GB, 2)
        if ($freeGB -lt $pf.MinFreeSpaceGB) {
            Write-Log "PREFLIGHT FAIL: Only ${freeGB}GB free on $($env:SystemDrive). Minimum: $($pf.MinFreeSpaceGB)GB." -Level ERROR
            $pass = $false
        } else {
            Write-Log "Disk space: ${freeGB}GB free - OK." -Level INFO
        }
    }

    # 3. Battery / power (laptops only)
    if ($pf.CheckBattery) {
        $battery = Get-WmiObject -Class Win32_Battery -EA SilentlyContinue
        if ($battery) {
            $pct  = $battery.EstimatedChargeRemaining
            $onAC = $battery.BatteryStatus -in @(2, 6, 7, 8, 9)
            if ($pf.RequireACPower -and -not $onAC) {
                Write-Log "PREFLIGHT FAIL: AC power required but device is on battery (${pct}%)." -Level WARN
                $pass = $false
            } elseif ($pct -lt $pf.MinBatteryPercent -and -not $onAC) {
                Write-Log "PREFLIGHT FAIL: Battery at ${pct}% and not charging. Min: $($pf.MinBatteryPercent)%." -Level WARN
                $pass = $false
            } else {
                Write-Log "Battery: ${pct}% (On AC: $onAC) - OK." -Level INFO
            }
        } else {
            Write-Log 'Battery: Not applicable (desktop/server).' -Level DEBUG
        }
    }

    # 4. User idle check (for laptop/shift worker estates on scheduled tasks)
    if ($pf.RequireUserIdle) {
        $minIdle  = $pf.MinIdleMinutes
        $idleMin  = Get-UserIdleMinutes
        if ($idleMin -lt $minIdle) {
            Write-Log "User active (idle: ${idleMin} min, required: ${minIdle} min). Deferring gracefully." -Level INFO
            # Graceful exit - user is at their desk, come back later
            exit 0
        } else {
            Write-Log "User idle: ${idleMin} min - OK." -Level INFO
        }
    }

    # 5. Network connectivity - HEAD first (cheap), GET fallback for servers
    # that reject HEAD requests
    $connectivityOk = $false
    try {
        $null = Invoke-WebRequest -Uri $script:CFG.Network.TestConnectivityUrl `
                                  -Method Head `
                                  -TimeoutSec $script:CFG.Network.ConnectivityTimeoutSec `
                                  -UseBasicParsing -EA Stop
        $connectivityOk = $true
    } catch {
        try {
            $null = Invoke-WebRequest -Uri $script:CFG.Network.TestConnectivityUrl `
                                      -TimeoutSec $script:CFG.Network.ConnectivityTimeoutSec `
                                      -UseBasicParsing -EA Stop
            $connectivityOk = $true
        } catch { }
    }
    if ($connectivityOk) {
        Write-Log 'Network connectivity: OK.' -Level INFO
    } else {
        Write-Log 'PREFLIGHT FAIL: No internet connectivity. Cannot reach update sources.' -Level ERROR
        $pass = $false
    }

    # 6. WinGet present
    $script:WINGET = Resolve-WinGetPath
    if (-not $script:WINGET) {
        Write-Log 'PREFLIGHT FAIL: winget.exe not found. Ensure App Installer 1.7+ is installed.' -Level ERROR
        $pass = $false
    } else {
        $ver = & $script:WINGET --version 2>&1
        Write-Log "WinGet found: $($script:WINGET) (version: $ver)" -Level INFO

        # '--custom' (append extra installer args) needs winget 1.4+. Older builds
        # only have '--override', which REPLACES the silent switches - never use it.
        $script:WinGetSupportsCustom = $false
        if ([string]$ver -match 'v?(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            $script:WinGetSupportsCustom = ($major -gt 1) -or ($major -eq 1 -and $minor -ge 4)
        }

        # 7. WinGet source health - a broken/missing source makes every update fail
        # with a confusing error. Catch it here with a clear message instead.
        try {
            $srcList = & $script:WINGET source list 2>&1
            $requiredSources = @('winget')
            if ($script:CFG.WinGet.IncludeMSStore) {
                $requiredSources += 'msstore'
            }

            foreach ($requiredSource in $requiredSources) {
                if ($srcList -match "(?im)^\s*$([regex]::Escape($requiredSource))\s") {
                    Write-Log "WinGet source '$requiredSource': healthy." -Level INFO
                } else {
                    Write-Log "PREFLIGHT WARN: WinGet source '$requiredSource' not found. Attempting source update..." -Level WARN
                    & $script:WINGET source update --name $requiredSource 2>&1 | Out-Null
                }
            }
        } catch {
            Write-Log "WinGet source check failed: $_. Updates may fail." -Level WARN
        }
    }

    Write-Log "--- Pre-flight result: $(if ($pass) {'PASS'} else {'FAIL'}) ---" `
              -Level $(if ($pass) { 'INFO' } else { 'WARN' })
    return $pass
}

#endregion

#region -- Ring and Maintenance Window -----------------------------------------------

function Get-DeploymentRing {
    if ($ForceRing) {
        Write-Log "Ring overridden via parameter: $ForceRing" -Level WARN
        return $ForceRing
    }
    try {
        $reg  = $script:CFG.Ring
        $ring = (Get-ItemProperty -Path $reg.RegistryPath -Name $reg.RegistryKey -EA Stop).($reg.RegistryKey)
        if ($ring -in @('Pilot','Early','Broad')) {
            Write-Log "Deployment ring: $ring (registry)" -Level INFO
            return $ring
        }
    } catch { }
    $default = $script:CFG.Ring.Default
    Write-Log "Ring not set in registry. Defaulting to: $default" -Level WARN
    return $default
}

function Test-MaintenanceWindow {
    # -Now is injectable for unit testing; production callers omit it.
    param([datetime]$Now = (Get-Date))

    if ($Force) {
        Write-Log 'Maintenance window bypassed (-Force flag).' -Level WARN
        return $true
    }
    if (-not $script:CFG.MaintenanceWindow.Enabled) {
        Write-Log 'Maintenance window: disabled by config.' -Level INFO
        return $true
    }

    $mw    = $script:CFG.MaintenanceWindow
    $now   = $Now
    $day   = $now.DayOfWeek.ToString()
    $hour  = $now.Hour
    $start = $mw.StartHour
    $end   = $mw.EndHour

    if ($day -notin $mw.AllowedDays) {
        Write-Log "Outside maintenance window: $day not in allowed days." -Level INFO
        return $false
    }

    $inWindow = if ($start -gt $end) {
        $hour -ge $start -or $hour -lt $end
    } else {
        $hour -ge $start -and $hour -lt $end
    }

    if ($inWindow) {
        Write-Log "Within maintenance window (${start}:00 - ${end}:00)." -Level INFO
    } else {
        Write-Log "Outside maintenance window. Current: ${hour}:xx. Window: ${start}:00 - ${end}:00." -Level INFO
    }
    return $inWindow
}

function Start-JitteredDelay {
    param(
        [string]$Ring,
        [int]$CapMinutes = 0    # 0 = use config value. Set to override (e.g. 5 for emergency)
    )

    $maxMinutes = if ($CapMinutes -gt 0) { $CapMinutes } else { $script:CFG.MaintenanceWindow.JitterMaxMinutes }
    if ($maxMinutes -le 0) { return }

    # Deterministic seed from hostname - same machine always gets the same slot
    $seed    = [Math]::Abs(([char[]]$script:HOSTNAME | ForEach-Object { [int]$_ } |
                Measure-Object -Sum).Sum % [int]::MaxValue)
    $rng     = New-Object System.Random($seed)
    $mult    = switch ($Ring) { 'Pilot' { 0.3 } 'Early' { 0.65 } default { 1.0 } }
    $minutes = [Math]::Round($rng.NextDouble() * $maxMinutes * $mult)

    if ($minutes -gt 0) {
        Write-Log "Jitter delay: ${minutes} min (ring: $Ring, cap: ${maxMinutes} min)." -Level INFO
        if (-not $DryRun) {
            Start-Sleep -Seconds ($minutes * 60)
        } else {
            Write-Log 'DRY RUN: Skipping jitter.' -Level DEBUG
        }
    }
}

#endregion

#region -- BITS Throttling ------------------------------------------------------------

$script:BITSPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS'
$script:BITSPolicyValueNames = @('EnableBandwidthLimits', 'MaxTransferRateOnSchedule', 'MaxTransferRateOffSchedule')

function Set-BITSThrottle {
    # Applies a machine-wide BITS bandwidth policy FOR THE DURATION OF THE RUN.
    # The previous state is snapshotted and restored by Restore-BITSThrottle so
    # Windows Update and other BITS consumers are not left throttled afterwards.
    if (-not $script:CFG.Network.BITSThrottleEnabled) {
        Write-Log 'BITS throttle: disabled by configuration.' -Level DEBUG
        return
    }
    if ($DryRun) {
        Write-Log 'DRY RUN: Would apply temporary BITS bandwidth throttle.' -Level INFO
        return
    }

    $kbps = $script:CFG.Network.BITSMaxBandwidthKbps
    try {
        # Snapshot existing policy values (or their absence) before changing anything
        $backup = [ordered]@{ KeyExisted = (Test-Path $script:BITSPolicyKey); Values = [ordered]@{} }
        if ($backup.KeyExisted) {
            foreach ($valueName in $script:BITSPolicyValueNames) {
                $existing = Get-ItemProperty -Path $script:BITSPolicyKey -Name $valueName -EA SilentlyContinue
                $backup.Values[$valueName] = if ($existing) { $existing.$valueName } else { $null }
            }
        }
        $script:BITSPolicyBackup = $backup

        if (-not $backup.KeyExisted) { New-Item -Path $script:BITSPolicyKey -Force | Out-Null }
        Set-ItemProperty -Path $script:BITSPolicyKey -Name 'EnableBandwidthLimits'      -Value 1     -Type DWord -EA Stop
        Set-ItemProperty -Path $script:BITSPolicyKey -Name 'MaxTransferRateOnSchedule'  -Value $kbps -Type DWord -EA Stop
        Set-ItemProperty -Path $script:BITSPolicyKey -Name 'MaxTransferRateOffSchedule' -Value $kbps -Type DWord -EA Stop
        $script:BITSPolicyApplied = $true
        Write-Log "BITS throttle: ${kbps} Kbps ($([Math]::Round($kbps/1024,1)) Mbps) per machine for this run." -Level INFO
    } catch {
        Write-Log "Could not configure BITS throttle: $_" -Level WARN
    }
}

function Restore-BITSThrottle {
    # Reverts the BITS policy to its pre-run state. Called from the entry point's
    # finally block so it also runs after crashes and early exits.
    if (-not $script:BITSPolicyApplied) { return }
    $backup = $script:BITSPolicyBackup
    try {
        if ($null -eq $backup -or -not $backup.KeyExisted) {
            # We created the key - remove it entirely to return to "no policy"
            Remove-Item -Path $script:BITSPolicyKey -Force -EA SilentlyContinue
        } else {
            foreach ($valueName in $script:BITSPolicyValueNames) {
                $previous = $backup.Values[$valueName]
                if ($null -eq $previous) {
                    Remove-ItemProperty -Path $script:BITSPolicyKey -Name $valueName -EA SilentlyContinue
                } else {
                    Set-ItemProperty -Path $script:BITSPolicyKey -Name $valueName -Value $previous -Type DWord -EA SilentlyContinue
                }
            }
        }
        $script:BITSPolicyApplied = $false
        Write-Log 'BITS throttle: pre-run policy state restored.' -Level INFO
    } catch {
        Write-Log "Could not restore BITS policy state: $_" -Level WARN
    }
}

#endregion

#region -- CISA KEV Integration ------------------------------------------------------

function Get-CISAKEVData {
    if (-not $script:CFG.CISAKEV.Enabled) {
        Write-Log 'CISA KEV: disabled.' -Level DEBUG
        return $null
    }

    $kev       = $script:CFG.CISAKEV
    $cacheDir  = $kev.CachePath
    $cacheFile = Join-Path $cacheDir 'cisa_kev.json'

    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

    if (Test-Path $cacheFile) {
        $age = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalHours
        if ($age -lt $kev.CacheHours) {
            Write-Log "CISA KEV: Using cache ($([Math]::Round($age,1))h old)." -Level DEBUG
            return Get-Content $cacheFile -Raw | ConvertFrom-Json
        }
    }

    try {
        Write-Log 'CISA KEV: Fetching latest catalogue...' -Level INFO
        $data = Invoke-RestMethod -Uri $kev.FeedUrl -TimeoutSec 30 -EA Stop
        $data | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -Encoding UTF8
        Write-Log "CISA KEV: $($data.vulnerabilities.Count) entries cached." -Level INFO
        return $data
    } catch {
        Write-Log "CISA KEV fetch failed: $_. $(if (Test-Path $cacheFile) {'Using stale cache.'} else {'No cache available.'})" -Level WARN
        if (Test-Path $cacheFile) { return Get-Content $cacheFile -Raw | ConvertFrom-Json }
        return $null
    }
}

function Test-WordMatch {
    # Whole-word, case-insensitive containment check. Stops "Apple" matching "Snapple"
    # or "Go" matching "Google". Escapes regex metacharacters in the needle.
    param([string]$Haystack, [string]$Needle)
    if ([string]::IsNullOrWhiteSpace($Haystack) -or [string]::IsNullOrWhiteSpace($Needle)) { return $false }
    $escaped = [regex]::Escape($Needle)
    return $Haystack -imatch "\b$escaped\b"
}

function ConvertTo-VersionParts {
    # Splits a plain dotted-numeric version into comparable parts. Returns $null for
    # anything that isn't purely numeric segments ('1.2.3-beta', '3.14-64', '' ...),
    # which callers must treat as "undecidable", never as "not affected".
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $v = $Version.Trim()
    if ($v -match '^[vV]\d') { $v = $v.Substring(1) }
    $segments = $v -split '\.'
    $out = [System.Collections.Generic.List[long]]::new()
    foreach ($s in $segments) {
        if ($s -notmatch '^\d+$') { return $null }
        try { [void]$out.Add([long]$s) } catch { return $null }
    }
    if ($out.Count -eq 0) { return $null }
    return $out.ToArray()
}

function Compare-SoftwareVersion {
    # -1 / 0 / 1 like a comparer, or $null when either side is not plain dotted-numeric.
    # Missing trailing segments compare as zero: 86 -eq 86.0.0. Pure - unit-testable.
    param([string]$Left, [string]$Right)
    $lp = ConvertTo-VersionParts $Left
    $rp = ConvertTo-VersionParts $Right
    if ($null -eq $lp -or $null -eq $rp) { return $null }
    $max = [Math]::Max($lp.Count, $rp.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $lp.Count) { $lp[$i] } else { 0L }
        $r = if ($i -lt $rp.Count) { $rp[$i] } else { 0L }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

function ConvertTo-CpeToken {
    # Normalises a vendor/product name to a CPE-style token: 'Google Chrome' -> 'google_chrome'.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_'))
}

function ConvertFrom-CpeCriteria {
    # Parses 'cpe:2.3:a:google:chrome:*:*:*:*:*:*:*:*' into its addressable fields.
    # Returns $null for anything that isn't a well-formed CPE 2.3 string.
    param([string]$Criteria)
    if ([string]::IsNullOrWhiteSpace($Criteria)) { return $null }
    $parts = $Criteria -split '(?<!\\):'
    if ($parts.Count -lt 6 -or $parts[0] -ne 'cpe' -or $parts[1] -ne '2.3') { return $null }
    return [PSCustomObject]@{
        Part    = $parts[2]
        Vendor  = $parts[3]
        Product = $parts[4]
        Version = $parts[5]
    }
}

function Test-CpeProductAlignment {
    # Does this CPE describe the same product the KEV entry names? Guards against
    # comparing a Chrome desktop version against, say, an Android CPE range.
    param($Cpe, [string]$Vendor, [string]$Product)
    if ($null -eq $Cpe) { return $false }
    if ($Cpe.Part -notin @('a', 'o')) { return $false }
    $cpeProd = [string]$Cpe.Product
    $kevProd = ConvertTo-CpeToken $Product
    if (-not $cpeProd -or -not $kevProd) { return $false }
    # Exact, or one is a qualified form of the other ('edge' vs 'edge_chromium').
    $prodOk = ($cpeProd -eq $kevProd) -or
              ($cpeProd.StartsWith("${kevProd}_")) -or
              ($kevProd.StartsWith("$($cpeProd)_"))
    if (-not $prodOk) { return $false }
    $cpeVend = [string]$Cpe.Vendor
    $kevVend = ConvertTo-CpeToken $Vendor
    if (-not $cpeVend -or -not $kevVend) { return $true }   # product alone is enough
    return ($cpeVend -eq $kevVend) -or $cpeVend.Contains($kevVend) -or $kevVend.Contains($cpeVend)
}

function Test-VersionInCpeRange {
    # $true = inside the vulnerable range, $false = outside, $null = undecidable.
    #
    # An unbounded wildcard CPE ('all versions of Chrome') is deliberately treated as
    # UNDECIDABLE rather than affected. NVD leaves ranges unbounded often enough that
    # honouring it literally would resurrect the false-positive emergencies this whole
    # gate exists to prevent. Undecidable surfaces for review; it never escalates.
    param([string]$Version, $CpeMatch)
    if ($null -eq $CpeMatch) { return $null }

    $cpe = ConvertFrom-CpeCriteria ([string](Get-ObjectPropertyValue $CpeMatch 'criteria' ''))
    if ($null -ne $cpe -and $cpe.Version -notin @('*', '-', '')) {
        # The CPE pins one exact version.
        $c = Compare-SoftwareVersion $Version $cpe.Version
        if ($null -eq $c) { return $null }
        return ($c -eq 0)
    }

    $startIncl = [string](Get-ObjectPropertyValue $CpeMatch 'versionStartIncluding' '')
    $startExcl = [string](Get-ObjectPropertyValue $CpeMatch 'versionStartExcluding' '')
    $endIncl   = [string](Get-ObjectPropertyValue $CpeMatch 'versionEndIncluding'   '')
    $endExcl   = [string](Get-ObjectPropertyValue $CpeMatch 'versionEndExcluding'   '')

    if (-not ($startIncl -or $startExcl -or $endIncl -or $endExcl)) { return $null }

    foreach ($bound in @(
        @{ Value = $startIncl; Outside = { param($c) $c -lt 0 } }
        @{ Value = $startExcl; Outside = { param($c) $c -le 0 } }
        @{ Value = $endIncl;   Outside = { param($c) $c -gt 0 } }
        @{ Value = $endExcl;   Outside = { param($c) $c -ge 0 } }
    )) {
        if (-not $bound.Value) { continue }
        $c = Compare-SoftwareVersion $Version $bound.Value
        if ($null -eq $c) { return $null }
        if (& $bound.Outside $c) { return $false }
    }
    return $true
}

function Resolve-KEVExposure {
    # Decides whether an installed version actually sits inside a KEV CVE's vulnerable
    # range, using NVD CPE data. Returns State = Affected | NotAffected | Unknown.
    # Pure - the caller supplies the CPE matches. Unit-testable with fixtures.
    param(
        [string]$InstalledVersion,
        [string]$Vendor,
        [string]$Product,
        [array]$CpeMatches
    )
    $unknown = { param($why) [PSCustomObject]@{ State = 'Unknown'; FixedVersion = ''; Detail = $why } }

    if (-not $CpeMatches -or $CpeMatches.Count -eq 0) {
        return (& $unknown 'No NVD CPE version data available; exposure not established.')
    }
    if ($null -eq (ConvertTo-VersionParts $InstalledVersion)) {
        return (& $unknown "Installed version '$InstalledVersion' is not a comparable dotted-numeric version.")
    }

    $relevant = @($CpeMatches | Where-Object {
        ([bool](Get-ObjectPropertyValue $_ 'vulnerable' $true)) -and
        (Test-CpeProductAlignment (ConvertFrom-CpeCriteria ([string](Get-ObjectPropertyValue $_ 'criteria' ''))) $Vendor $Product)
    })
    if ($relevant.Count -eq 0) {
        return (& $unknown "No NVD CPE range matched $Vendor $Product; exposure not established.")
    }

    $sawUndecidable = $false
    $fixedVersions  = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $relevant) {
        $endExcl = [string](Get-ObjectPropertyValue $m 'versionEndExcluding' '')
        if ($endExcl) { [void]$fixedVersions.Add($endExcl) }
        $inRange = Test-VersionInCpeRange -Version $InstalledVersion -CpeMatch $m
        if ($null -eq $inRange) { $sawUndecidable = $true; continue }
        if ($inRange) {
            return [PSCustomObject]@{
                State        = 'Affected'
                FixedVersion = $endExcl
                Detail       = "Installed $InstalledVersion falls inside the NVD vulnerable range$(if ($endExcl) { " (fixed in $endExcl)" })."
            }
        }
    }
    if ($sawUndecidable) {
        return (& $unknown 'NVD CPE ranges could not be compared against the installed version.')
    }

    # Report the highest fix boundary we cleared - that's the one the install is past.
    $highestFix = ''
    foreach ($fv in $fixedVersions) {
        if (-not $highestFix) { $highestFix = $fv; continue }
        $c = Compare-SoftwareVersion $fv $highestFix
        if ($null -ne $c -and $c -gt 0) { $highestFix = $fv }
    }
    return [PSCustomObject]@{
        State        = 'NotAffected'
        FixedVersion = $highestFix
        Detail       = "Installed $InstalledVersion is outside the NVD vulnerable range$(if ($highestFix) { " (fixed in $highestFix)" })."
    }
}

function Get-NVDCpeMatches {
    # Flattened, vulnerable-only cpeMatch nodes for one CVE, or $null when unavailable.
    # Memoised per run; cached on disk across runs; rate-limited to respect NVD limits.
    param([Parameter(Mandatory)] [string]$CveId)

    $cfg = Get-ObjectPropertyValue $script:CFG 'NVD' $null
    if ($null -eq $cfg -or -not [bool](Get-ObjectPropertyValue $cfg 'Enabled' $false)) { return $null }
    if ($script:NVDMemo.ContainsKey($CveId)) { return $script:NVDMemo[$CveId] }

    $maxLookups = [int](Get-ObjectPropertyValue $cfg 'MaxLookupsPerRun' 25)
    if ($script:NVDLookupCount -ge $maxLookups) {
        Write-Log "NVD: lookup budget ($maxLookups) exhausted; $CveId left unresolved." -Level WARN
        return $null
    }

    $base   = [string](Get-ObjectPropertyValue $cfg 'ApiBaseUrl' 'https://services.nvd.nist.gov/rest/json/cves/2.0')
    $apiKey = [string](Get-ObjectPropertyValue $cfg 'ApiKey' '')
    $hdrs   = @{ 'User-Agent' = 'PatchManager-NVD' }
    if ($apiKey) { $hdrs['apiKey'] = $apiKey }

    # Rate limit only real network calls - a cache hit inside Get-CachedApiJson costs nothing,
    # but we cannot see from here whether it hit, so pace on the pre-check instead.
    $cacheDir  = [string](Get-ObjectPropertyValue $cfg 'CachePath' 'C:\ProgramData\PatchManager\Cache')
    $cacheFile = Join-Path $cacheDir "nvd_$($CveId -replace '[^A-Za-z0-9._-]', '_').json"
    $cacheHours = [double](Get-ObjectPropertyValue $cfg 'CacheHours' 720)
    $willFetch = -not (Test-Path $cacheFile) -or
                 (((Get-Date) - (Get-Item $cacheFile -EA SilentlyContinue).LastWriteTime).TotalHours -ge $cacheHours)
    if ($willFetch -and $script:NVDLastRequest -ne [datetime]::MinValue) {
        $delayMs = [int](Get-ObjectPropertyValue $cfg 'RequestDelayMs' 6500)
        $waited  = ((Get-Date) - $script:NVDLastRequest).TotalMilliseconds
        if ($waited -lt $delayMs) { Start-Sleep -Milliseconds ([int]($delayMs - $waited)) }
    }

    $resp = Get-CachedApiJson -Uri "$base`?cveId=$CveId" -CacheKey "nvd_$CveId" -Cfg $cfg -Headers $hdrs -Label 'NVD'
    if ($willFetch) {
        $script:NVDLastRequest = Get-Date
        $script:NVDLookupCount++
    }

    $cpeMatches = $null
    if ($null -ne $resp) {
        $collected = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($vuln in @(Get-ObjectPropertyValue $resp 'vulnerabilities' @())) {
            $cve = Get-ObjectPropertyValue $vuln 'cve' $null
            foreach ($config in @(Get-ObjectPropertyValue $cve 'configurations' @())) {
                foreach ($node in @(Get-ObjectPropertyValue $config 'nodes' @())) {
                    if ([bool](Get-ObjectPropertyValue $node 'negate' $false)) { continue }
                    foreach ($cm in @(Get-ObjectPropertyValue $node 'cpeMatch' @())) { [void]$collected.Add($cm) }
                }
            }
        }
        $cpeMatches = @($collected)
    }
    $script:NVDMemo[$CveId] = $cpeMatches
    return $cpeMatches
}

function Add-KEVExposure {
    # Resolves every candidate's ExposureState against NVD. Candidates are name-only
    # KEV hits; only 'Affected' is evidence that this host is actually exposed.
    param([array]$Candidates)
    foreach ($c in $Candidates) {
        $cpe = Get-NVDCpeMatches -CveId $c.CVE
        $ex  = Resolve-KEVExposure -InstalledVersion $c.InstalledVer -Vendor $c.VendorProject `
                                   -Product $c.Product -CpeMatches $cpe
        $c.ExposureState  = $ex.State
        $c.FixedVersion   = $ex.FixedVersion
        $c.ExposureDetail = $ex.Detail
    }
    return $Candidates
}

function Find-KEVCandidates {
    # Name-only match against the KEV catalogue. A hit means "this PRODUCT has
    # known-exploited history", NOT that the installed version is vulnerable - the
    # catalogue carries no version data at all. Add-KEVExposure settles that.
    param(
        [array]$Packages,
        $KEVData,
        # Informational pass (e.g. full inventory) - affects logging only.
        [switch]$Informational
    )

    if (-not $KEVData) { return @() }

    $kevMatchList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $matchKeys    = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($entry in $KEVData.vulnerabilities) {
        $vendor  = [string]$entry.vendorProject
        $product = [string]$entry.product

        # Skip entries with very short vendor/product names - too generic, all noise
        # (e.g. product "ATS", "PAN" would match half the estate)
        if ($vendor.Length  -lt 3 -or $product.Length -lt 3) { continue }

        # Skip degenerate entries where the product is just the vendor name -
        # "Microsoft"/"Microsoft" would match every Microsoft package installed.
        if ($product -ieq $vendor) { continue }

        # Windows servicing is handled outside PatchManager. Do not let broad
        # Microsoft Windows KEV entries promote Store/shell packages to emergency.
        if ($vendor -ieq 'Microsoft' -and $product -ieq 'Windows') { continue }

        foreach ($app in $Packages) {
            $name      = [string]$app.Name
            $packageId = [string](Get-ObjectPropertyValue $app 'PackageId' '')
            $publisher = if ($app.PSObject.Properties['Publisher']) { [string]$app.Publisher } else { '' }

            # Require BOTH vendor and product to match on whole-word boundaries.
            # Vendor can match against app name, package id, or publisher; product must
            # match the actionable package name or id.
            $vendorMatch  = (Test-WordMatch $name $vendor) -or
                            (Test-WordMatch $packageId $vendor) -or
                            (Test-WordMatch $publisher $vendor)
            $productMatch = (Test-WordMatch $name $product) -or
                            (Test-WordMatch $packageId $product)

            if ($vendorMatch -and $productMatch) {
                # Dedupe: same CVE + same package shouldn't appear twice
                $source = [string](Get-ObjectPropertyValue $app 'Source' 'inventory')
                $key = "$($entry.cveID)|$source|$(if ($packageId) { $packageId } else { $name })"
                if ($matchKeys.Add($key)) {
                    $kevMatchList.Add([PSCustomObject]@{
                        CVE            = $entry.cveID
                        VendorProject  = $vendor
                        Product        = $product
                        Description    = $entry.vulnerabilityName
                        DateAdded      = $entry.dateAdded
                        CISADueDate    = $entry.dueDate
                        InstalledApp   = $name
                        InstalledVer   = $app.Version
                        PackageId      = $packageId
                        Source         = $source
                        # Settled later by Add-KEVExposure. Never assume affected.
                        ExposureState  = 'Unknown'
                        FixedVersion   = ''
                        ExposureDetail = 'Exposure not yet resolved.'
                    })
                }
            }
        }
    }

    $scope = if ($Informational) { 'inventory scan' } else { 'upgrade candidates' }
    Write-Log "CISA KEV ($scope): $($kevMatchList.Count) name match(es) before version resolution." -Level $(if ($kevMatchList.Count -gt 0) { 'INFO' } else { 'DEBUG' })

    return $kevMatchList
}

#endregion

#region -- Software Inventory ---------------------------------------------------------

function Get-SoftwareInventory {
    Write-Log 'Building software inventory...' -Level INFO
    $inventory = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen      = [System.Collections.Generic.HashSet[string]]::new()

    # Machine-wide (64-bit and 32-bit views)
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    # Per-user installs for all loaded profiles. Running as SYSTEM, HKCU is SYSTEM's own
    # hive, so we enumerate HKEY_USERS to catch software the logged-in user installed.
    try {
        $userHives = Get-ChildItem 'Registry::HKEY_USERS' -EA SilentlyContinue |
                     Where-Object { $_.Name -match 'S-1-5-21' }  # Real user SIDs only
        foreach ($hive in $userHives) {
            $regPaths += "Registry::$($hive.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            $regPaths += "Registry::$($hive.Name)\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        }
    } catch { }

    foreach ($path in $regPaths) {
        try {
            Get-ItemProperty -Path $path -EA SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayVersion -and -not $_.SystemComponent } |
                ForEach-Object {
                    # Dedupe on name+version - the same app can appear in multiple hives
                    $key = "$($_.DisplayName)|$($_.DisplayVersion)"
                    if ($seen.Add($key)) {
                        $inventory.Add([PSCustomObject]@{
                            Name      = $_.DisplayName
                            Version   = $_.DisplayVersion
                            Publisher = $_.Publisher
                        })
                    }
                }
        } catch { }
    }

    # AppX / MSIX packages (modern apps not in the classic uninstall registry)
    try {
        Get-AppxPackage -AllUsers -EA SilentlyContinue |
            Where-Object { $_.Name -and $_.Version -and -not $_.IsFramework } |
            ForEach-Object {
                $key = "$($_.Name)|$($_.Version)"
                if ($seen.Add($key)) {
                    $inventory.Add([PSCustomObject]@{
                        Name      = $_.Name
                        Version   = $_.Version
                        Publisher = $_.Publisher
                    })
                }
            }
    } catch { Write-Log "AppX enumeration skipped: $_" -Level DEBUG }

    Write-Log "Software inventory: $($inventory.Count) items (registry + AppX, deduped)." -Level INFO
    return $inventory
}

#endregion

#region -- Patch State Tracking (SLA by update availability) -------------------------

function Get-PatchState {
    $statePath = $script:CFG.State.StatePath
    $stateFile = Join-Path $statePath $script:CFG.State.StateFile

    if (-not (Test-Path $statePath)) { New-Item -ItemType Directory -Path $statePath -Force | Out-Null }

    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
    }

    # Clean schema - SLA tracked against update availability date, not CVE dates
    return [PSCustomObject]@{ TrackedUpdates = @() }
}

function Save-PatchState {
    param(
        [Parameter(Mandatory)] [object]$State,
        [array]$AvailableUpgrades,
        [array]$AppliedResults
    )

    if ($null -eq $AvailableUpgrades) { $AvailableUpgrades = @() }
    if ($null -eq $AppliedResults) { $AppliedResults = @() }

    $stateFile = Join-Path $script:CFG.State.StatePath $script:CFG.State.StateFile
    $today     = Get-Date -Format 'yyyy-MM-dd'
    $slaDays   = $script:CFG.SLA.Critical   # Single window for all updates

    # Index existing records for fast lookup
    $existingIndex = @{}
    foreach ($u in $State.TrackedUpdates) {
        $existingIndex["$($u.PackageId)|$($u.VersionAvailable)"] = $u
    }

    # Register newly available updates and start their SLA clock
    foreach ($upgrade in $AvailableUpgrades) {
        $key = "$($upgrade.PackageId)|$($upgrade.Available)"
        if (-not $existingIndex.ContainsKey($key)) {
            $State.TrackedUpdates += [PSCustomObject]@{
                PackageId          = $upgrade.PackageId
                PackageName        = $upgrade.Name
                VersionAvailable   = $upgrade.Available
                VersionPrior       = $upgrade.Version
                FirstSeenAvailable = $today
                SLADue             = (Get-Date).AddDays($slaDays).ToString('yyyy-MM-dd')
                Ring               = $script:RING
                Applied            = $false
                AppliedOn          = $null
                DaysToApply        = $null
            }
        }
    }

    # Mark successfully applied updates
    foreach ($result in ($AppliedResults | Where-Object {
        $successProp = $_.PSObject.Properties['Success']
        $statusProp = $_.PSObject.Properties['Status']
        $successProp -and [bool]$successProp.Value -and ((-not $statusProp) -or $statusProp.Value -in @('Succeeded','Updated','Detected'))
    })) {
        $version = if ($result.PSObject.Properties['ConfirmedVersion'] -and $result.ConfirmedVersion) {
            $result.ConfirmedVersion
        } elseif ($result.PSObject.Properties['AvailableVersion'] -and $result.AvailableVersion) {
            $result.AvailableVersion
        } else {
            $result.NewVer
        }
        $key   = "$($result.PackageId)|$version"
        $entry = $existingIndex[$key]
        if (-not $entry) {
            # Fallback match by PackageId if version key differs slightly
            $entry = $State.TrackedUpdates |
                     Where-Object { $_.PackageId -eq $result.PackageId -and -not $_.Applied } |
                     Select-Object -First 1
        }
        if ($entry -and -not $entry.Applied) {
            $entry.Applied     = $true
            $entry.AppliedOn   = $today
            $entry.DaysToApply = ([datetime]$today - [datetime]$entry.FirstSeenAvailable).Days
        }
    }

    # Prune old applied records beyond retention window
    $cutoff = (Get-Date).AddDays(-$script:CFG.Logging.RetentionDays).ToString('yyyy-MM-dd')
    $State.TrackedUpdates = @($State.TrackedUpdates | Where-Object {
        -not $_.Applied -or $_.AppliedOn -ge $cutoff
    })

    Set-ContentAtomic -Path $stateFile -Content ($State | ConvertTo-Json -Depth 10) | Out-Null
    return $State
}

function Get-SLABreaches {
    param([object]$State)
    $today = Get-Date -Format 'yyyy-MM-dd'
    return @($State.TrackedUpdates | Where-Object {
        -not $_.Applied -and $_.SLADue -and $_.SLADue -lt $today
    })
}

function Get-PatchMetrics {
    param([object]$State)
    $applied  = @($State.TrackedUpdates | Where-Object { $_.Applied })
    $pending  = @($State.TrackedUpdates | Where-Object { -not $_.Applied })
    $breaches = @(Get-SLABreaches -State $State)
    $avgDays  = if ($applied.Count -gt 0) {
        [Math]::Round(($applied | Measure-Object -Property DaysToApply -Average).Average, 1)
    } else { 'N/A' }

    return [ordered]@{
        TotalTracked   = $State.TrackedUpdates.Count
        Applied        = $applied.Count
        Pending        = $pending.Count
        SLABreaches    = $breaches.Count
        AvgDaysToApply = $avgDays
    }
}

#endregion

#region -- WinGet Update Engine -------------------------------------------------------

function Get-WinGetUpgradesViaModule {
    # Locale-proof discovery path: the Microsoft.WinGet.Client module returns
    # structured objects instead of a fixed-width localised text table. Used when
    # installed; returns $null (not @()) when unavailable so the caller can fall
    # back to text parsing.
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' -EA SilentlyContinue)) { return $null }

    try {
        Import-Module 'Microsoft.WinGet.Client' -EA Stop
        Write-Log 'WinGet: using Microsoft.WinGet.Client module for upgrade discovery.' -Level INFO

        $upgrades = [System.Collections.Generic.List[PSCustomObject]]::new()
        $packages = @(Get-WinGetPackage -EA Stop | Where-Object { $_.IsUpdateAvailable })
        foreach ($pkg in $packages) {
            $source = [string]$pkg.Source
            if ([string]::IsNullOrWhiteSpace($source)) { continue }   # Unmapped/sideloaded package
            if ($source -eq 'msstore' -and -not $script:CFG.WinGet.IncludeMSStore) { continue }
            if ($source -notin @('winget', 'msstore')) { continue }
            $available = [string](@($pkg.AvailableVersions) | Select-Object -First 1)
            if (-not $available) { continue }
            $upgrades.Add([PSCustomObject]@{
                Name      = [string]$pkg.Name
                PackageId = [string]$pkg.Id
                Version   = [string]$pkg.InstalledVersion
                Available = $available
                Source    = $source
                Provider  = if ($source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
                Publisher = ''
            })
        }

        $moduleSources = @('winget')
        if ($script:CFG.WinGet.IncludeMSStore) { $moduleSources += 'msstore' }
        foreach ($moduleSource in $moduleSources) {
            $rowCount = @($upgrades | Where-Object { $_.Source -eq $moduleSource }).Count
            $sourceProvider = if ($moduleSource -eq 'msstore') { 'winget-msstore-discovery' } else { 'winget-discovery' }
            $script:SourceCheckResults.Add((New-PatchResult -Name "WinGet source: $moduleSource" `
                -PackageId "WinGet.Source.$moduleSource" `
                -Source $moduleSource `
                -Provider $sourceProvider `
                -Status 'Completed' `
                -Success $true `
                -Evidence "WinGet source '$moduleSource' checked via Microsoft.WinGet.Client module; $rowCount upgrade row(s) discovered."))
        }

        Write-Log "WinGet (module): $($upgrades.Count) upgrade(s) available." -Level INFO
        return $upgrades
    } catch {
        Write-Log "Microsoft.WinGet.Client module discovery failed: $_. Falling back to winget.exe text parsing." -Level WARN
        return $null
    }
}

function ConvertFrom-WinGetUpgradeOutput {
    # Parses the fixed-width table 'winget upgrade' prints. Kept as a standalone,
    # side-effect-free function so it can be unit tested against captured output.
    param(
        [AllowEmptyCollection()] [string[]]$Lines,
        [Parameter(Mandatory)] [string]$QuerySource
    )

    $upgrades = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new()
    $parseErrors = [System.Collections.Generic.List[string]]::new()
    $colName = -1; $colId = -1; $colVersion = -1; $colAvail = -1; $colSource = -1
    $inTable = $false
    $sawHeader = $false

    foreach ($line in $Lines) {
        $line = [string]$line
        if ($line -match '^\s*Name\s+Id\s+Version\s+Available') {
            $line = $line.TrimStart()
            $sawHeader  = $true
            $inTable    = $true
            $colName    = $line.IndexOf('Name')
            $colId      = $line.IndexOf('Id')
            $colVersion = $line.IndexOf('Version')
            $colAvail   = $line.IndexOf('Available')
            $colSource  = $line.IndexOf('Source')
            continue
        }
        if (-not $inTable) { continue }
        if ($line -match '^-{5,}') { continue }
        if ($line -match '^\d+ upgrade' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $len      = $line.Length
            $availEnd = if ($colSource -gt 0 -and $colSource -le $len) { $colSource } else { $len }
            $verEnd   = if ($colAvail  -gt 0 -and $colAvail  -le $len) { $colAvail  } else { $len }
            $idEnd    = if ($colVersion -gt 0 -and $colVersion -le $len) { $colVersion } else { $len }

            $name   = if ($colId -gt 0 -and $colId -le $len)          { $line.Substring($colName,   [Math]::Max(0, $colId    - $colName)).Trim() } else { '' }
            $id     = if ($colVersion -gt 0 -and $colVersion -le $len) { $line.Substring($colId,     [Math]::Max(0, $idEnd    - $colId)).Trim() } else { '' }
            $ver    = if ($colAvail -gt 0 -and $colAvail -le $len)     { $line.Substring($colVersion,[Math]::Max(0, $verEnd   - $colVersion)).Trim() } else { '' }
            $avail  = if ($availEnd -le $len -and $colAvail -ge 0)     { $line.Substring($colAvail,  [Math]::Max(0, $availEnd - $colAvail)).Trim() } else { '' }
            $source = if ($colSource -ge 0 -and $colSource -lt $len)   { $line.Substring($colSource).Trim() } else { $QuerySource }

            if ($name -and $id -and $avail) {
                $key = "$source|$id|$avail"
                if ($seen.Add($key)) {
                    $upgrades.Add([PSCustomObject]@{
                        Name      = $name
                        PackageId = $id
                        Version   = $ver
                        Available = $avail
                        Source    = $source
                        Provider  = if ($source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
                        Publisher = ''
                    })
                }
            }
        } catch { $parseErrors.Add($line) }
    }

    return [PSCustomObject]@{
        Upgrades    = @($upgrades)
        SawHeader   = $sawHeader
        ParseErrors = @($parseErrors)
    }
}

function Get-WinGetUpgrades {
    Write-Log 'Querying WinGet for available upgrades...' -Level INFO

    $moduleUpgrades = Get-WinGetUpgradesViaModule
    if ($null -ne $moduleUpgrades) { return $moduleUpgrades }

    $upgrades   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen       = [System.Collections.Generic.HashSet[string]]::new()
    $sources    = [System.Collections.Generic.List[string]]::new()
    $sources.Add('winget')

    if ($script:CFG.WinGet.IncludeMSStore) {
        $sources.Add('msstore')
    }

    foreach ($querySource in $sources) {
        Write-Log "WinGet: checking source '$querySource'." -Level DEBUG

        # --include-unknown surfaces packages whose installed version WinGet can't determine.
        # --accept-source-agreements keeps msstore/winget source prompts non-interactive.
        $raw = & $script:WINGET upgrade --include-unknown --source $querySource --accept-source-agreements --disable-interactivity 2>&1
        $exitCode = $LASTEXITCODE
        $sourceOutput = ''
        if ($exitCode -ne 0) {
            $sourceOutput = (($raw | Select-Object -First 4) -join ' ').Trim()
            Write-Log "WinGet source '$querySource' upgrade query returned exit code $exitCode. Output: $sourceOutput" -Level WARN
        }

        $parsed = ConvertFrom-WinGetUpgradeOutput -Lines @($raw | ForEach-Object { [string]$_ }) -QuerySource $querySource
        $sawHeader = $parsed.SawHeader
        $parsedForSource = 0
        foreach ($upgrade in $parsed.Upgrades) {
            $key = "$($upgrade.Source)|$($upgrade.PackageId)|$($upgrade.Available)"
            if ($seen.Add($key)) {
                $upgrades.Add($upgrade)
                $parsedForSource++
            }
        }
        foreach ($badLine in $parsed.ParseErrors) {
            Write-Log "WinGet parse error on [$querySource]: '$badLine'" -Level DEBUG
        }

        if (-not $sawHeader) {
            $sourceOutput = (($raw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 4) -join ' ').Trim()
            if ($sourceOutput) {
                Write-Log "WinGet source '$querySource': no upgrade table found. Output: $sourceOutput" -Level DEBUG
            } else {
                Write-Log "WinGet source '$querySource': no output returned." -Level DEBUG
            }
        }

        Write-Log "WinGet source '$querySource': $parsedForSource upgrade row(s) parsed." -Level DEBUG
        $sourceProvider = if ($querySource -eq 'msstore') { 'winget-msstore-discovery' } else { 'winget-discovery' }
        $sourceStatus = if ($exitCode -eq 0) { 'Completed' } else { 'Failed' }
        $sourceEvidence = "WinGet source '$querySource' checked with exit code $exitCode; parsed $parsedForSource upgrade row(s)."
        if ($sourceOutput) {
            $sourceEvidence = "$sourceEvidence Output: $sourceOutput"
        }
        $script:SourceCheckResults.Add((New-PatchResult -Name "WinGet source: $querySource" `
            -PackageId "WinGet.Source.$querySource" `
            -Source $querySource `
            -Provider $sourceProvider `
            -Status $sourceStatus `
            -Success ($exitCode -eq 0) `
            -Evidence $sourceEvidence))
    }

    Write-Log "WinGet: $($upgrades.Count) upgrade(s) available." -Level INFO
    return $upgrades
}

function Add-SkippedUpgradeResult {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Package,
        [Parameter(Mandatory)] [string]$Reason
    )

    $provider = if ($Package.PSObject.Properties['Provider']) { $Package.Provider } elseif ($Package.Source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
    $script:SkippedUpgradeResults.Add((New-PatchResult -Name $Package.Name `
        -PackageId $Package.PackageId `
        -Source $Package.Source `
        -Provider $provider `
        -InstalledVersion $Package.Version `
        -AvailableVersion $Package.Available `
        -Status 'Skipped' `
        -Evidence $Reason))
}

function Get-FilteredUpgrades {
    param([array]$Upgrades)

    $approved = $script:CFG.WinGet.ApprovedPackages
    $publisherManaged = @($script:CFG.WinGet.PublisherManagedPackageIds)
    $excluded = 0
    $filtered = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($pkg in $Upgrades) {
        if ($pkg.PackageId -in $publisherManaged) {
            Add-SkippedUpgradeResult -Package $pkg -Reason 'Publisher-managed; update with the vendor app or IDE update flow.'
            $excluded++
            continue
        }

        $descopeReason = ''
        if (Test-IsDescoped -Item $pkg -Reason ([ref]$descopeReason)) {
            $provider = if ($pkg.PSObject.Properties['Provider']) { $pkg.Provider } elseif ($pkg.Source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
            $script:SkippedUpgradeResults.Add((New-PatchResult -Name $pkg.Name `
                -PackageId $pkg.PackageId `
                -Source $pkg.Source `
                -Provider $provider `
                -InstalledVersion $pkg.Version `
                -AvailableVersion $pkg.Available `
                -Status 'Descoped' `
                -Evidence $descopeReason))
            $excluded++
            continue
        }

        $isExcluded = @($script:CFG.WinGet.ExcludePackagePrefixes) | Where-Object { $pkg.PackageId -like "$_*" }
        if ($isExcluded) {
            $provider = if ($pkg.PSObject.Properties['Provider']) { $pkg.Provider } elseif ($pkg.Source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
            $script:SkippedUpgradeResults.Add((New-PatchResult -Name $pkg.Name `
                -PackageId $pkg.PackageId `
                -Source $pkg.Source `
                -Provider $provider `
                -InstalledVersion $pkg.Version `
                -AvailableVersion $pkg.Available `
                -Status 'Descoped' `
                -Evidence 'Descoped by WinGet component/package prefix safety list.'))
            $excluded++
            continue
        }

        if ($approved -and $approved.Count -gt 0 -and $pkg.PackageId -notin $approved) {
            $excluded++; continue
        }

        $filtered.Add($pkg)
    }

    Write-Log "Filtered upgrades: $($filtered.Count) eligible, $excluded excluded." -Level INFO
    return $filtered
}

function Invoke-PackageUpdate {
    param([PSCustomObject]$Package, [int]$PromptRetryCount = 0)

    $name = $Package.Name
    $id   = $Package.PackageId
    $source = if ($Package.Source) { $Package.Source } else { 'winget' }

    if ($DryRun) {
        Write-Log "DRY RUN: Would update [$source][$id] $name ($($Package.Version) -> $($Package.Available))" -Level INFO
        $script:LastUpdateStatus = 'Planned'
        $script:LastUpdateReason = ''
        return $true
    }

    Write-Log "Updating: $name [$source][$id] $($Package.Version) -> $($Package.Available)" -Level INFO

    $argList = @(
        'upgrade', '--id', $id,
        '--source', $source,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'          # No prompts - safe for unattended/SYSTEM runs
    )

    if ($source -ne 'msstore') {
        $argList += @('--silent', '--scope', $script:CFG.WinGet.Scope)
    }

    # Suppress installer-forced reboots where the installer honours it (mainly MSI).
    # PatchManager flags reboot-required at the end; it never reboots mid-run.
    # '--custom' APPENDS to the installer's silent switches. '--override' would
    # REPLACE them, breaking silent installs, so it is deliberately not used.
    if ($source -ne 'msstore' -and $script:CFG.WinGet.SuppressReboot -and $script:WinGetSupportsCustom) {
        $argList += @('--custom', '/norestart')
    }

    try {
        # Invoke-CapturedProcess returns the REAL exit code. The previous
        # Start-Process implementation left .ExitCode $null with redirected
        # streams on PS 5.1 and defaulted it to 0 - so a failed installer whose
        # output matched none of the text patterns was recorded as a success.
        $timeout = $script:CFG.WinGet.PackageTimeoutSeconds
        $run = Invoke-CapturedProcess -FilePath $script:WINGET -Arguments $argList -TimeoutSeconds $timeout

        if ($run.TimedOut) {
            Write-Log "TIMEOUT: $name exceeded ${timeout}s." -Level WARN
            $script:LastUpdateStatus = 'Failed'
            $script:LastUpdateReason = "Timed out after ${timeout}s."
            return $false
        }
        if ($null -eq $run.ExitCode) {
            Write-Log "FAILED: $name - winget did not launch or returned no exit code. $($run.Output)" -Level WARN
            $script:LastUpdateStatus = 'Failed'
            $script:LastUpdateReason = "winget failed to run: $($run.Output)"
            return $false
        }
        $exitCode   = [int]$run.ExitCode
        $outputText = [string]$run.Output

        $noUpdateCodes = @(-1978335189, -1978335212, -1978335220, -1978335192)

        # Check for publisher-managed packages before exit code - WinGet explicitly
        # blocks upgrades for some packages (e.g. JetBrains IDEs) that use their
        # own update mechanism. This is not a failure - log and skip.
        if ($outputText -match 'cannot be upgraded using WinGet|use the method provided by the publisher') {
            Write-Log "Skipped (publisher-managed): $name must be updated via the publisher's own tool." -Level WARN
            $script:LastUpdateStatus = 'Skipped'
            $script:LastUpdateReason = 'Publisher-managed; update with the vendor app or built-in updater.'
            return $true
        }

        if ($exitCode -eq 0) {
            if ($outputText -match 'No applicable|already installed|No available upgrade') {
                Write-Log "Already current: $name" -Level DEBUG
                $script:LastUpdateStatus = 'Skipped'
                $script:LastUpdateReason = 'Already current or no applicable update.'
            } else {
                Write-Log "SUCCESS: $name updated to $($Package.Available)" -Level SUCCESS
                $script:LastUpdateStatus = 'Succeeded'
                $script:LastUpdateReason = ''
            }
            return $true
        } elseif ($exitCode -in $noUpdateCodes) {
            Write-Log "No applicable update: $name" -Level DEBUG
            $script:LastUpdateStatus = 'Skipped'
            $script:LastUpdateReason = 'WinGet reported no applicable update.'
            return $true
        } else {
            if ((Test-IsAppInUseUpdateFailure -Output $outputText) -and $PromptRetryCount -lt 1) {
                $choice = Show-AppInUsePrompt -AppName $name -Evidence $outputText
                if ($choice -eq 'Primary') {
                    Write-Log "Retrying $name after user prompt to close the app." -Level INFO
                    return Invoke-PackageUpdate -Package $Package -PromptRetryCount ($PromptRetryCount + 1)
                }
                Write-Log "Blocked: $name update deferred because the app appears to be in use." -Level WARN
                $script:LastUpdateStatus = 'Blocked'
                $script:LastUpdateReason = 'Update blocked because the app appears to be open or files are in use. Close the app and rerun PatchManager.'
                return $false
            }
            Write-Log "FAILED: $name - Exit code: $exitCode. Output: $outputText" -Level WARN
            $script:LastUpdateStatus = 'Failed'
            $script:LastUpdateReason = "WinGet exit code: $exitCode."
            return $false
        }
    } catch {
        Write-Log "EXCEPTION updating $name : $_" -Level ERROR
        $script:LastUpdateStatus = 'Failed'
        $script:LastUpdateReason = "Exception: $_"
        return $false
    }
}

function Invoke-AllUpdates {
    param([array]$Upgrades, [array]$KEVMatches)

    if ($Upgrades.Count -eq 0) {
        Write-Log 'No eligible packages to update.' -Level INFO
        return @()
    }

    # Confirmed-affected packages first, then unresolved KEV candidates, then the rest.
    # A name-only KEV hit still earns a queue bump - it just no longer implies exposure.
    $confirmedNames = @($KEVMatches | Where-Object { $_.ExposureState -eq 'Affected' } | ForEach-Object { $_.InstalledApp })
    $candidateNames = @($KEVMatches | Where-Object { $_.ExposureState -ne 'NotAffected' } | ForEach-Object { $_.InstalledApp })

    $prioritised = @(
        $Upgrades | Where-Object { $_.Name -in $confirmedNames }
        $Upgrades | Where-Object { $_.Name -notin $confirmedNames -and $_.Name -in $candidateNames }
        $Upgrades | Where-Object { $_.Name -notin $candidateNames }
    )

    $max = $script:CFG.WinGet.MaxUpdatesPerRun
    if ($max -gt 0) { $prioritised = $prioritised | Select-Object -First $max }

    Write-Log "Applying $($prioritised.Count) update(s). $($confirmedNames.Count) confirmed KEV exposure(s) prioritised." -Level INFO

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # MaxRetries = total attempts per package. 1 = try once, no retry. 2 = one retry, etc.
    $maxAttempts = [Math]::Max(1, [int]$script:CFG.WinGet.MaxRetries)

    foreach ($pkg in $prioritised) {
        $success = $false
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $script:LastUpdateStatus = $null
            $script:LastUpdateReason = ''
            $success = Invoke-PackageUpdate -Package $pkg
            if ($success) { break }
            if ($script:LastUpdateStatus -in @('Blocked','Skipped','Descoped','AlreadyCurrent')) { break }
            if ($attempt -lt $maxAttempts) {
                Write-Log "Attempt $attempt of $maxAttempts failed for $($pkg.Name). Retrying..." -Level DEBUG
                Start-Sleep -Seconds (5 * $attempt)   # Simple linear backoff
            }
        }
        $results.Add([PSCustomObject]@{
            Name      = $pkg.Name
            PackageId = $pkg.PackageId
            Source    = $pkg.Source
            Provider  = if ($pkg.PSObject.Properties['Provider']) { $pkg.Provider } elseif ($pkg.Source -eq 'msstore') { 'winget-msstore' } else { 'winget' }
            OldVer    = $pkg.Version
            NewVer    = $pkg.Available
            Success   = $success
            Status    = if ($script:LastUpdateStatus) { $script:LastUpdateStatus } elseif ($DryRun) { 'Planned' } elseif ($success) { 'Succeeded' } else { 'Failed' }
            Reason    = $script:LastUpdateReason
            IsKEV     = ($pkg.Name -in $confirmedNames)
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
    }

    return $results
}

function Invoke-WindowsUpdateProvider {
    $provider = 'windows-update'
    if (-not $script:CFG.WindowsUpdate.Enabled) {
        $status = if (Test-IsFleetProfile -ScopeProfile $script:CFG.ScopeProfile) { 'Descoped' } else { 'Skipped' }
        return @((New-PatchResult -Name 'Windows Update' -PackageId 'Windows.Update' -Provider $provider -Source $provider -Status $status -Evidence 'Windows Update provider disabled by configuration.'))
    }

    $reason = ''
    if (Test-IsDescoped -Item ([PSCustomObject]@{ Name='Windows Update'; PackageId='Windows.Update'; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
        return @((New-PatchResult -Name 'Windows Update' -PackageId 'Windows.Update' -Provider $provider -Source $provider -Status 'Descoped' -Evidence $reason))
    }

    # The Windows Update Agent COM calls (Search/Download/Install) are synchronous
    # and can hang indefinitely. Run the whole flow on a background runspace and
    # enforce WindowsUpdate.TimeoutSeconds from this thread. A hung runspace thread
    # is a background thread, so it cannot keep the process alive after exit.
    $wuScript = {
        param([string]$Criteria, [bool]$IncludeDrivers, [bool]$IncludeFeatureUpdates, [bool]$IncludeOptionalUpdates, [bool]$IsDryRun)

        function Get-CategoryNames {
            param($Update)
            $names = @()
            try { foreach ($category in $Update.Categories) { $names += [string]$category.Name } } catch { }
            return $names
        }
        function Get-KbText {
            param($Update)
            try {
                $ids = @($Update.KBArticleIDs | Where-Object { $_ })
                if ($ids.Count -gt 0) { return (($ids | ForEach-Object { "KB$_" }) -join ', ') }
            } catch { }
            return ''
        }
        function ConvertTo-ResultCodeText {
            param($Code)
            switch ([int]$Code) {
                0 { 'NotStarted' } 1 { 'InProgress' } 2 { 'Succeeded' }
                3 { 'SucceededWithErrors' } 4 { 'Failed' } 5 { 'Aborted' }
                default { "Unknown($Code)" }
            }
        }

        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $searchResult = $searcher.Search($Criteria)
            $candidates = @()

            foreach ($update in $searchResult.Updates) {
                $title = [string]$update.Title
                $categories = (Get-CategoryNames -Update $update) -join ';'
                $isDriver = ($title -imatch '\bdriver\b' -or $categories -imatch 'Driver')
                $isFeature = ($title -imatch 'Feature update to Windows|Windows 1[01].*version|Upgrade to Windows' -or $categories -imatch 'Upgrades')
                $isOptional = $false
                try { $isOptional = -not [bool]$update.AutoSelectOnWebSites } catch { }
                if (-not $IncludeDrivers -and $isDriver) { continue }
                if (-not $IncludeFeatureUpdates -and $isFeature) { continue }
                if (-not $IncludeOptionalUpdates -and $isOptional) { continue }
                $candidates += $update
            }

            if ($candidates.Count -eq 0) {
                return @([PSCustomObject]@{ Kind = 'summary'; Status = 'AlreadyCurrent'; Success = $true; Evidence = 'No in-scope Windows software updates were offered.' })
            }

            if ($IsDryRun) {
                return @($candidates | ForEach-Object {
                    $kb = Get-KbText -Update $_
                    [PSCustomObject]@{
                        Kind = 'row'; Name = [string]$_.Title
                        PackageId = $(if ($kb) { $kb } else { [string]$_.Identity.UpdateID })
                        Kb = $kb; ConfirmedKb = ''
                        Status = 'Planned'; Success = $false; RebootRequired = $false
                        Evidence = "Windows Update candidate. Categories=$((Get-CategoryNames -Update $_) -join '; '); Severity=$($_.MsrcSeverity)"
                    }
                })
            }

            $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($update in $candidates) {
                try { if (-not $update.EulaAccepted) { $update.AcceptEula() } } catch { }
                [void]$updatesToInstall.Add($update)
            }

            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $updatesToInstall
            $downloadResult = $downloader.Download()

            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $updatesToInstall
            $installResult = $installer.Install()

            $rows = @()
            for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
                $update = $updatesToInstall.Item($i)
                $perUpdate = $installResult.GetUpdateResult($i)
                $codeText = ConvertTo-ResultCodeText -Code $perUpdate.ResultCode
                $success = $perUpdate.ResultCode -in 2,3
                $kb = Get-KbText -Update $update
                $rows += [PSCustomObject]@{
                    Kind = 'row'; Name = [string]$update.Title
                    PackageId = $(if ($kb) { $kb } else { [string]$update.Identity.UpdateID })
                    Kb = $kb; ConfirmedKb = $kb
                    Status = $(if ($success) { 'Succeeded' } else { 'Failed' }); Success = $success
                    RebootRequired = [bool]($perUpdate.RebootRequired -or $installResult.RebootRequired)
                    Evidence = "Windows Update install result=$codeText; HResult=$($perUpdate.HResult); DownloadResult=$(ConvertTo-ResultCodeText -Code $downloadResult.ResultCode); Categories=$((Get-CategoryNames -Update $update) -join '; '); Severity=$($update.MsrcSeverity)"
                }
            }
            return $rows
        } catch {
            return @([PSCustomObject]@{ Kind = 'summary'; Status = 'Failed'; Success = $false; Evidence = "Windows Update provider exception: $_" })
        }
    }

    $timeoutSeconds = [Math]::Max(60, [int]$script:CFG.WindowsUpdate.TimeoutSeconds)
    $ps = $null
    try {
        Write-Log "Windows Update: discovering applicable software updates (timeout: ${timeoutSeconds}s)." -Level INFO
        $ps = [powershell]::Create()
        [void]$ps.AddScript($wuScript).
            AddArgument([string]$script:CFG.WindowsUpdate.SearchCriteria).
            AddArgument([bool]$script:CFG.WindowsUpdate.IncludeDrivers).
            AddArgument([bool]$script:CFG.WindowsUpdate.IncludeFeatureUpdates).
            AddArgument([bool]$script:CFG.WindowsUpdate.IncludeOptionalUpdates).
            AddArgument([bool]$DryRun.IsPresent)

        $asyncHandle = $ps.BeginInvoke()
        if (-not $asyncHandle.AsyncWaitHandle.WaitOne($timeoutSeconds * 1000)) {
            # Ask the pipeline to stop but do not block on a hung COM call
            try { $ps.BeginStop($null, $null) | Out-Null } catch { }
            Write-Log "Windows Update provider timed out after ${timeoutSeconds}s." -Level WARN
            return @((New-PatchResult -Name 'Windows Update' -PackageId 'Windows.Update' -Provider $provider -Source $provider -Status 'Failed' -Evidence "Windows Update provider timed out after ${timeoutSeconds}s (WindowsUpdate.TimeoutSeconds). Search, download, or install did not complete."))
        }

        $wuRows = @($ps.EndInvoke($asyncHandle))
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($row in $wuRows) {
            if ($row.Kind -eq 'summary') {
                if ($row.Status -eq 'Failed') { Write-Log "Windows Update provider failed: $($row.Evidence)" -Level WARN }
                else { Write-Log 'Windows Update: no in-scope quality/security software updates found.' -Level INFO }
                $results.Add((New-PatchResult -Name 'Windows Update' -PackageId 'Windows.Update' -Provider $provider -Source $provider -Status $row.Status -Success ([bool]$row.Success) -Evidence $row.Evidence))
            } else {
                $results.Add((New-PatchResult -Name $row.Name -PackageId $row.PackageId -Provider $provider -Source $provider -AvailableVersion $row.Kb -ReportedVersion $row.Kb -ConfirmedVersion $row.ConfirmedKb -Status $row.Status -Success ([bool]$row.Success) -RebootRequired ([bool]$row.RebootRequired) -Evidence $row.Evidence))
            }
        }
        return @($results)
    } catch {
        Write-Log "Windows Update provider failed: $_" -Level WARN
        return @((New-PatchResult -Name 'Windows Update' -PackageId 'Windows.Update' -Provider $provider -Source $provider -Status 'Failed' -Evidence "Windows Update provider exception: $_"))
    } finally {
        if ($ps) {
            try { if ($ps.InvocationStateInfo.State -ne 'Running') { $ps.Dispose() } } catch { }
        }
    }
}

function Get-Microsoft365ClickToRunInfo {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    foreach ($path in $paths) {
        try {
            $cfg = Get-ItemProperty -Path $path -EA Stop
            $client = @(
                (Join-Path ${env:ProgramFiles} 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe')
                (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe')
            ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
            if ($client) {
                return [PSCustomObject]@{
                    ClientPath = $client
                    Version    = [string]$cfg.VersionToReport
                    Channel    = [string]$cfg.UpdateChannel
                    ProductIds = [string]$cfg.ProductReleaseIds
                }
            }
        } catch { }
    }
    return $null
}

function Get-C2RScenarioState {
    # Reads the Click-to-Run scenario state. ExecutingScenario is non-empty (e.g.
    # 'UPDATE') while the C2R service is working; LastScenario/LastScenarioResult
    # describe the most recently finished operation ('Success'/'Failure').
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun')) {
        try {
            $item = Get-ItemProperty -Path $path -EA Stop
            return [PSCustomObject]@{
                ExecutingScenario  = [string](Get-ObjectPropertyValue $item 'ExecutingScenario' '')
                LastScenario       = [string](Get-ObjectPropertyValue $item 'LastScenario' '')
                LastScenarioResult = [string](Get-ObjectPropertyValue $item 'LastScenarioResult' '')
            }
        } catch { }
    }
    return $null
}

function Invoke-Microsoft365Provider {
    $provider = 'microsoft365-clicktorun'
    if (-not $script:CFG.Microsoft365.Enabled) {
        $status = if (Test-IsFleetProfile -ScopeProfile $script:CFG.ScopeProfile) { 'Descoped' } else { 'Skipped' }
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -Status $status -Evidence 'Microsoft 365 provider disabled by configuration.'))
    }

    $before = Get-Microsoft365ClickToRunInfo
    if (-not $before) {
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -Status 'Skipped' -Evidence 'Microsoft 365 Click-to-Run was not detected.'))
    }

    $reason = ''
    if (Test-IsDescoped -Item ([PSCustomObject]@{ Name='Microsoft 365 Apps'; PackageId='Microsoft.Office.ClickToRun'; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -Status 'Descoped' -Evidence $reason))
    }

    if ($DryRun) {
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -Status 'Planned' -Evidence "Would run OfficeC2RClient update. Channel=$($before.Channel); Products=$($before.ProductIds)"))
    }

    $c2rArgs = @('/update', 'user', 'displaylevel=false')
    $c2rArgs += if ($script:CFG.Microsoft365.ForceAppShutdown) { 'forceappshutdown=true' } else { 'forceappshutdown=false' }
    try {
        Write-Log "Microsoft 365: running Click-to-Run update ($($before.ClientPath) $($c2rArgs -join ' '))." -Level INFO
        $timeoutSec = [Math]::Max(60, [int]$script:CFG.Microsoft365.TimeoutSeconds)
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        $proc = Start-Process -FilePath $before.ClientPath -ArgumentList $c2rArgs -PassThru -WindowStyle Hidden
        $completed = $proc.WaitForExit($timeoutSec * 1000)
        if (-not $completed) {
            try { $proc.Kill() } catch { }
            return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -Status 'Failed' -Evidence "OfficeC2RClient timed out after ${timeoutSec}s."))
        }

        # OfficeC2RClient hands the actual work to the Click-to-Run service and can
        # exit almost immediately, so an instant before/after compare misreports an
        # in-flight update as AlreadyCurrent. Poll ExecutingScenario until the
        # service is idle (or the timeout budget is spent), then judge the outcome.
        Start-Sleep -Seconds 5   # give the service a moment to raise ExecutingScenario
        $state = Get-C2RScenarioState
        while ($state -and $state.ExecutingScenario -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $state = Get-C2RScenarioState
        }

        $after = Get-Microsoft365ClickToRunInfo
        $afterVersion = if ($after) { $after.Version } else { '' }
        $updated = $afterVersion -and $afterVersion -ne $before.Version
        $scenarioText = if ($state) { "LastScenario=$($state.LastScenario)/$($state.LastScenarioResult)" } else { 'Scenario state unavailable' }

        if ($state -and $state.ExecutingScenario) {
            # Still applying when the budget ran out - report honestly; the next
            # run (and the version delta) will confirm the outcome.
            return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -AvailableVersion $afterVersion -Status 'Verifying' -Evidence "Click-to-Run is still applying an update (scenario '$($state.ExecutingScenario)') after ${timeoutSec}s; the result will be confirmed on the next run. Before=$($before.Version); Channel=$($before.Channel)."))
        }
        if (-not $updated -and $state -and $state.LastScenario -ieq 'UPDATE' -and $state.LastScenarioResult -ieq 'Failure') {
            return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -Status 'Failed' -Evidence "Click-to-Run reported the update scenario failed ($scenarioText). Before=$($before.Version); Channel=$($before.Channel)."))
        }
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -AvailableVersion $afterVersion -ConfirmedVersion $afterVersion -Status $(if ($updated) { 'Updated' } else { 'AlreadyCurrent' }) -Success $true -Evidence "Click-to-Run finished ($scenarioText). Before=$($before.Version); After=$afterVersion; Channel=$($before.Channel)."))
    } catch {
        return @((New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Provider $provider -Source $provider -InstalledVersion $before.Version -Status 'Failed' -Evidence "Microsoft 365 provider exception: $_"))
    }
}

function Get-InstalledFileVersion {
    # ProductVersion of the first candidate file that exists, or ''. Reads the
    # binary on disk, so it reflects an applied update immediately - unlike
    # BLBeacon-style registry beacons, which apps only rewrite on next launch.
    param([string[]]$Candidates)
    foreach ($path in @($Candidates | Where-Object { $_ })) {
        try {
            if (Test-Path $path) {
                $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion
                if ($ver) { return ([string]$ver).Trim() }
            }
        } catch { }
    }
    return ''
}

function Get-BrowserVersion {
    param([ValidateSet('Chrome','Edge')] [string]$Browser)
    # Prefer the installed binary's version: BLBeacon is only rewritten when the
    # browser next launches, so it under-reports a just-applied native update
    # as "no change". BLBeacon remains the fallback (e.g. unusual install paths).
    $exeCandidates = if ($Browser -eq 'Chrome') {
        @(
            (Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe')
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        )
    } else {
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
            (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe')
        )
    }
    $fileVersion = Get-InstalledFileVersion -Candidates $exeCandidates
    if ($fileVersion) { return $fileVersion }

    $paths = if ($Browser -eq 'Chrome') {
        @('HKLM:\SOFTWARE\Google\Chrome\BLBeacon','HKCU:\SOFTWARE\Google\Chrome\BLBeacon')
    } else {
        @('HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon','HKCU:\SOFTWARE\Microsoft\Edge\BLBeacon')
    }
    foreach ($path in $paths) {
        try {
            $item = Get-ItemProperty -Path $path -EA Stop
            if ($item.version) { return [string]$item.version }
        } catch { }
    }
    return ''
}

function Resolve-BrowserUpdater {
    param([ValidateSet('Chrome','Edge')] [string]$Browser)
    $paths = if ($Browser -eq 'Chrome') {
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Update\GoogleUpdate.exe')
            (Join-Path ${env:ProgramFiles} 'Google\Update\GoogleUpdate.exe')
            (Join-Path $env:LOCALAPPDATA 'Google\Update\GoogleUpdate.exe')
        )
    } else {
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
            (Join-Path ${env:ProgramFiles} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
            (Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
        )
    }
    # Select-Object -First 1 yields the item or nothing; do not index with [0],
    # which throws on an empty result under Set-StrictMode -Version Latest.
    return ($paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

# --- Generic native-updater helpers (used by the vendor/firmware providers) ---
# Generalisations of Get-BrowserVersion / Resolve-BrowserUpdater. The browser
# provider keeps its own tested copies; these serve the newer providers.

function Get-RegistryVersion {
    # Reads the first available version-style value from a list of registry keys.
    param([string[]]$Paths, [string]$ValueName = 'version')
    foreach ($path in @($Paths | Where-Object { $_ })) {
        try {
            $item = Get-ItemProperty -Path $path -EA Stop
            $val = $item.$ValueName
            if ($val) { return [string]$val }
        } catch { }
    }
    return ''
}

function Resolve-FirstExistingPath {
    # Returns the first candidate path that exists on disk, or $null.
    # (Select-Object -First 1 yields the item or nothing - never index an
    # array here, since @()[0] throws under Set-StrictMode -Version Latest.)
    param([string[]]$Candidates)
    return ($Candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
}

function Invoke-CapturedProcess {
    # Runs an external command with a hard timeout and captures merged stdout+stderr.
    # Returns: { ExitCode (nullable); TimedOut [bool]; Output [string] }
    #
    # Uses System.Diagnostics.Process directly rather than Start-Process -PassThru:
    # in Windows PowerShell 5.1, Start-Process -PassThru leaves .ExitCode $null when
    # the standard streams are redirected, even on a clean exit. Every consumer here
    # keys success/reboot handling off the exit code, so an unreliable code silently
    # misclassifies successful runs (e.g. choco upgrades reported as Failed, or a
    # 0-outdated discovery reported as "failed to run"). A direct Process returns the
    # real code. ProcessStartInfo.ArgumentList does not exist on .NET Framework 4.x,
    # so arguments are quoted into the .Arguments string as Invoke-StoreCliCommand does.
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        # Lines written to the child's stdin (then closed). Lets CLIs that prompt
        # (e.g. the Store CLI's y/n confirmation) run unattended.
        [string[]]$StandardInputLines = @()
    )

    $proc = $null
    try {
        $escaped = @($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = $escaped
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = ($StandardInputLines.Count -gt 0)

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        if ($StandardInputLines.Count -gt 0) {
            try {
                foreach ($line in $StandardInputLines) { $proc.StandardInput.WriteLine($line) }
            } catch { }
            try { $proc.StandardInput.Close() } catch { }
        }

        # Read both streams asynchronously so a full pipe buffer cannot deadlock the
        # child, and so the timeout below is honoured even if the child never exits.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return [PSCustomObject]@{ ExitCode = $null; TimedOut = $true; Output = "Timed out after ${TimeoutSeconds}s." }
        }
        # Second WaitForExit() ensures the async stream reads have fully flushed.
        $proc.WaitForExit()

        $outputText = [string]$outTask.Result + [string]$errTask.Result
        return [PSCustomObject]@{ ExitCode = $proc.ExitCode; TimedOut = $false; Output = $outputText }
    } catch {
        return [PSCustomObject]@{ ExitCode = $null; TimedOut = $false; Output = "Exception: $_" }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Invoke-BrowserProvider {
    param(
        [ValidateSet('Chrome','Edge')] [string]$Browser,
        [array]$WinGetCandidates = @()
    )

    if (-not $script:CFG.Browsers.Enabled) { return @() }
    if ($Browser -eq 'Chrome' -and -not $script:CFG.Browsers.ChromeEnabled) { return @() }
    if ($Browser -eq 'Edge' -and -not $script:CFG.Browsers.EdgeEnabled) { return @() }

    $provider = if ($Browser -eq 'Chrome') { 'google-update' } else { 'edge-update' }
    $packageId = if ($Browser -eq 'Chrome') { 'Google.Chrome' } else { 'Microsoft.Edge' }
    $name = if ($Browser -eq 'Chrome') { 'Google Chrome' } else { 'Microsoft Edge' }

    if (@($WinGetCandidates | Where-Object { $_.PackageId -like "$packageId*" }).Count -gt 0) {
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -Status 'Skipped' -Evidence 'Browser update is already represented by an actionable WinGet candidate.'))
    }

    $currentVersion = Get-BrowserVersion -Browser $Browser
    $updater = Resolve-BrowserUpdater -Browser $Browser
    if (-not $updater) {
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Skipped' -Evidence "$name native updater was not found."))
    }

    $reason = ''
    if (Test-IsDescoped -Item ([PSCustomObject]@{ Name=$name; PackageId=$packageId; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Descoped' -Evidence $reason))
    }

    if ($DryRun) {
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Planned' -Evidence "Would run native updater: $updater /ua /installsource scheduler."))
    }

    try {
        $updaterArgs = @('/ua', '/installsource', 'scheduler')
        Write-Log "${name}: running native updater ($updater $($updaterArgs -join ' '))." -Level INFO
        $proc = Start-Process -FilePath $updater -ArgumentList $updaterArgs -PassThru -WindowStyle Hidden
        $completed = $proc.WaitForExit([int]$script:CFG.Browsers.NativeTimeoutSeconds * 1000)
        if (-not $completed) {
            try { $proc.Kill() } catch { }
            return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Failed' -Evidence "Native updater timed out after $($script:CFG.Browsers.NativeTimeoutSeconds)s."))
        }
        $afterVersion = Get-BrowserVersion -Browser $Browser
        $updated = $afterVersion -and $currentVersion -and $afterVersion -ne $currentVersion
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -AvailableVersion $afterVersion -ConfirmedVersion $afterVersion -Status $(if ($updated) { 'Updated' } else { 'AlreadyCurrent' }) -Success $true -Evidence "Native updater exit code=$($proc.ExitCode); Before=$currentVersion; After=$afterVersion."))
    } catch {
        return @((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Failed' -Evidence "Browser provider exception: $_"))
    }
}

#endregion

#region -- Alternate Package Managers (Chocolatey, Scoop) -----------------------------

function Resolve-ChocoPath {
    $cmd = Get-Command 'choco.exe' -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command 'choco' -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function ConvertFrom-ChocoOutdated {
    # Parses `choco outdated -r --nocolor` machine-readable output. Each real
    # row is `id|current|available|pinned`. Non-conforming lines (warnings,
    # blanks, summaries) are ignored. Side-effect-free for unit testing.
    param([AllowEmptyCollection()] [string[]]$Lines)
    $items = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($line in @($Lines)) {
        $line = [string]$line
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Count -lt 4) { continue }
        $id = $parts[0].Trim()
        if (-not $id) { continue }
        # 'available' column must look like a version to be a real row
        if ($parts[2].Trim() -notmatch '\d') { continue }
        $items.Add([pscustomobject]@{
            Id        = $id
            Current   = $parts[1].Trim()
            Available = $parts[2].Trim()
            Pinned    = ($parts[3].Trim() -ieq 'true')
        })
    }
    return @($items)
}

function Invoke-ChocolateyProvider {
    $provider = 'chocolatey'
    if (-not [bool](Get-ObjectPropertyValue $script:CFG.PackageManagers 'ChocolateyEnabled' $false)) { return @() }

    $choco = Resolve-ChocoPath
    if (-not $choco) {
        Write-Log 'Chocolatey: choco.exe not found; provider skipped.' -Level DEBUG
        return @()   # choco isn't installed on most machines - stay silent
    }

    $timeout = [Math]::Max(30, [int](Get-ObjectPropertyValue $script:CFG.PackageManagers 'TimeoutSeconds' 300))
    Write-Log "Chocolatey: discovering outdated packages ($choco outdated)." -Level INFO
    $discovery = Invoke-CapturedProcess -FilePath $choco -Arguments @('outdated', '-r', '--nocolor') -TimeoutSeconds $timeout

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($discovery.TimedOut) {
        $results.Add((New-PatchResult -Name 'Chocolatey source' -PackageId 'Chocolatey.Source' -Provider 'chocolatey-discovery' -Source $provider -Status 'Failed' -Evidence "Chocolatey outdated discovery timed out after ${timeout}s."))
        return @($results)
    }
    if ($null -eq $discovery.ExitCode) {
        # The process never launched (or died before returning a code) - do not
        # report a clean "0 outdated" when discovery itself failed.
        $results.Add((New-PatchResult -Name 'Chocolatey source' -PackageId 'Chocolatey.Source' -Provider 'chocolatey-discovery' -Source $provider -Status 'Failed' -Evidence "Chocolatey outdated discovery failed to run: $($discovery.Output)"))
        return @($results)
    }

    $outdated = @(ConvertFrom-ChocoOutdated -Lines ([string]$discovery.Output -split '\r?\n') | Where-Object { -not $_.Pinned })
    $results.Add((New-PatchResult -Name 'Chocolatey source' -PackageId 'Chocolatey.Source' -Provider 'chocolatey-discovery' -Source $provider -Status 'Completed' -Success $true -Evidence "Chocolatey checked; $($outdated.Count) outdated package(s) found."))

    if ($outdated.Count -eq 0) { return @($results) }

    $applied = 0
    $max = [int](Get-ObjectPropertyValue $script:CFG.PackageManagers 'MaxUpdatesPerRun' 0)
    foreach ($pkg in $outdated) {
        $reason = ''
        if (Test-IsDescoped -Item ([PSCustomObject]@{ Name=$pkg.Id; PackageId=$pkg.Id; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Descoped' -Evidence $reason))
            continue
        }
        if ($max -gt 0 -and $applied -ge $max) {
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Skipped' -Evidence "Per-run update cap ($max) reached; deferred to next run."))
            continue
        }
        if ($DryRun) {
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Planned' -Evidence "Would run: choco upgrade $($pkg.Id) -y."))
            continue
        }

        Write-Log "Chocolatey: upgrading $($pkg.Id) $($pkg.Current) -> $($pkg.Available)." -Level INFO
        $upg = Invoke-CapturedProcess -FilePath $choco -Arguments @('upgrade', $pkg.Id, '-y', '--no-progress', '--nocolor', '-r') -TimeoutSeconds $timeout
        $applied++
        $summary = (([string]$upg.Output -replace '\s+', ' ').Trim())
        if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
        # choco: 0 = success; 1641/3010 = success + reboot required
        $rebootCodes = @(1641, 3010)
        if ($upg.TimedOut) {
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Failed' -Evidence "choco upgrade timed out after ${timeout}s."))
        } elseif ($upg.ExitCode -eq 0 -or $upg.ExitCode -in $rebootCodes) {
            $reboot = $upg.ExitCode -in $rebootCodes
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -ConfirmedVersion $pkg.Available -Status 'Succeeded' -Success $true -RebootRequired $reboot -Evidence "choco upgrade exit code=$($upg.ExitCode). $summary"))
        } else {
            $results.Add((New-PatchResult -Name $pkg.Id -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Failed' -Evidence "choco upgrade exit code=$($upg.ExitCode). $summary"))
        }
    }
    return @($results)
}

function Resolve-ScoopCommand {
    # Scoop is a per-user shim. Only resolvable from the user's own session -
    # never from a SYSTEM-context scheduled run. Prefer the .cmd shim: PowerShell
    # resolves 'scoop' to the .ps1 shim, which Start-Process (raw CreateProcess,
    # used by Invoke-CapturedProcess for stream redirection) cannot execute.
    $cmd = Get-Command 'scoop' -EA SilentlyContinue
    if ($cmd -and $cmd.Source) {
        if ($cmd.Source -like '*.ps1') {
            $sibling = [System.IO.Path]::ChangeExtension($cmd.Source, '.cmd')
            if (Test-Path $sibling) { return $sibling }
        } else {
            return $cmd.Source
        }
    }
    $userShim = Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'
    if (Test-Path $userShim) { return $userShim }
    return $null
}

function Invoke-ScoopProvider {
    $provider = 'scoop'
    if (-not [bool](Get-ObjectPropertyValue $script:CFG.PackageManagers 'ScoopEnabled' $false)) { return @() }

    $scoop = Resolve-ScoopCommand
    if (-not $scoop) {
        Write-Log 'Scoop: not found in the current user session; provider skipped.' -Level DEBUG
        return @()   # no scoop for this user (or SYSTEM context) - stay silent
    }

    $timeout = [Math]::Max(30, [int](Get-ObjectPropertyValue $script:CFG.PackageManagers 'TimeoutSeconds' 300))
    if ($DryRun) {
        return @((New-PatchResult -Name 'Scoop apps' -PackageId 'Scoop.Apps' -Provider $provider -Source $provider -Status 'Planned' -Evidence "Would refresh buckets and run: scoop update * ($scoop)."))
    }

    # Scoop has no machine-readable outdated format that is stable across
    # versions, so per-app descoping is not available here - the whole provider
    # is the control (disable it, or use `scoop hold <app>`). Refresh buckets,
    # then update all apps, and report one summary result.
    Write-Log "Scoop: refreshing buckets and updating all apps ($scoop update *)." -Level INFO
    $null = Invoke-CapturedProcess -FilePath $scoop -Arguments @('update') -TimeoutSeconds $timeout
    $upd = Invoke-CapturedProcess -FilePath $scoop -Arguments @('update', '*') -TimeoutSeconds $timeout
    $summary = (([string]$upd.Output -replace '\s+', ' ').Trim())
    if ($summary.Length -gt 600) { $summary = $summary.Substring(0, 600) + '...' }

    if ($upd.TimedOut) {
        return @((New-PatchResult -Name 'Scoop apps' -PackageId 'Scoop.Apps' -Provider $provider -Source $provider -Status 'Failed' -Evidence "scoop update timed out after ${timeout}s."))
    }
    $ok = ($upd.ExitCode -eq 0)
    return @((New-PatchResult -Name 'Scoop apps' -PackageId 'Scoop.Apps' -Provider $provider -Source $provider -Status $(if ($ok) { 'Completed' } else { 'Failed' }) -Success $ok -Evidence "scoop update * exit code=$($upd.ExitCode). $summary"))
}

#endregion

#region -- Python Install Manager -----------------------------------------------------
# Store/pymanager-installed Python is structurally invisible to WinGet: the msstore
# source reports the channel tag ('3.14-64') where a version belongs, so a patch-level
# update (3.14.5 -> 3.14.6) can never be discovered there. `py` owns these runtimes.

function Resolve-PyManagerCommand {
    # Returns the path to a *Python Install Manager* py.exe, or $null.
    #
    # Two different executables answer to `py`: the legacy PEP 397 launcher
    # (C:\Windows\py.exe, no install/list subcommands) and the Python Install
    # Manager. Probing for the launcher's absence is not enough - confirm the
    # binary actually speaks the manager's `list -f json` protocol.
    # pymanager is per-user, so a SYSTEM-context run resolves nothing (like Scoop).
    $candidates = @()
    $cmd = Get-Command 'py' -EA SilentlyContinue
    if ($cmd -and $cmd.Source) { $candidates += [string]$cmd.Source }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Python\bin\py.exe')

    foreach ($path in ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
        try {
            $probe = Invoke-CapturedProcess -FilePath $path -Arguments @('list', '--only-managed', '-f', 'json') -TimeoutSeconds 30
            if ($probe.TimedOut -or $probe.ExitCode -ne 0) { continue }
            # $null means "not a manager listing"; a zero-runtime listing is still a manager.
            if ($null -ne (ConvertFrom-PyManagerList -Json ([string]$probe.Output))) { return $path }
        } catch { continue }
    }
    return $null
}

function ConvertFrom-PyManagerList {
    # Parses `py list -f json` / `py list --online -f json`. Pure - unit-testable.
    #
    # Returns $null when the payload is not a Python Install Manager listing at all
    # (e.g. the legacy PEP 397 py launcher), otherwise a single object whose .Runtimes
    # is always an array - possibly empty, meaning "the manager reported no runtimes".
    #
    # That distinction has to survive the return, and a bare array return cannot carry
    # it: PowerShell unrolls arrays into the pipeline, so one runtime would arrive as a
    # scalar (no .Count under StrictMode) and zero runtimes as $null - indistinguishable
    # from "not the manager". Hence the wrapper object: Resolve-PyManagerCommand keys its
    # probe on $null, and the provider keys its Failed-discovery row on it.
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    # pymanager prints signature-verification notices before the JSON body.
    $start = $Json.IndexOf('{')
    if ($start -lt 0) { return $null }
    try { $doc = $Json.Substring($start) | ConvertFrom-Json -EA Stop } catch { return $null }
    if ($null -eq $doc -or -not $doc.PSObject.Properties['versions']) { return $null }

    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($v in @($doc.versions)) {
        $id = [string](Get-ObjectPropertyValue $v 'id' '')
        if (-not $id) { continue }
        $out.Add([pscustomobject]@{
            Id          = $id
            Tag         = [string](Get-ObjectPropertyValue $v 'tag' '')
            Company     = [string](Get-ObjectPropertyValue $v 'company' '')
            Version     = [string](Get-ObjectPropertyValue $v 'sort-version' '')
            DisplayName = [string](Get-ObjectPropertyValue $v 'display-name' $id)
            # 'unmanaged' is present-and-truthy only for runtimes pymanager did not install
            # (uv/Astral, python.org MSI). `py install --update` cannot touch those.
            Unmanaged   = [bool](Get-ObjectPropertyValue $v 'unmanaged' $false)
        })
    }
    return [pscustomobject]@{ Runtimes = @($out) }
}

function Find-PyManagerUpgrades {
    # Pairs installed runtimes against the online index by exact install id, keeping
    # only those with a strictly newer available version. Unmanaged runtimes are
    # excluded: pymanager does not own them, so it must not overwrite them.
    # Pure - unit-testable with fixtures.
    param([array]$Installed, [array]$Online)
    $upgrades = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not $Installed -or -not $Online) { return @($upgrades) }

    foreach ($inst in $Installed) {
        if ($inst.Unmanaged) { continue }
        $match = $Online | Where-Object { $_.Id -eq $inst.Id } | Select-Object -First 1
        if (-not $match) { continue }
        $cmp = Compare-SoftwareVersion $match.Version $inst.Version
        if ($null -eq $cmp -or $cmp -le 0) { continue }
        $upgrades.Add([pscustomobject]@{
            Id          = $inst.Id
            Tag         = $inst.Tag
            DisplayName = $inst.DisplayName
            Current     = $inst.Version
            Available   = $match.Version
        })
    }
    return @($upgrades)
}

function Get-PyManagerRuntimes {
    # Reads installed (or online) runtimes through the manager. Returns $null on any
    # failure, otherwise the ConvertFrom-PyManagerList wrapper (.Runtimes is an array).
    #
    # Deliberately NOT `--only-managed`: unmanaged runtimes (uv/Astral, python.org MSI)
    # are worth reporting as evidence even though pymanager must not update them. The
    # Unmanaged flag carries that distinction downstream.
    param([Parameter(Mandatory)] [string]$PyPath, [switch]$Online, [int]$TimeoutSeconds = 300)
    $pyArgs = @('list')
    if ($Online) { $pyArgs += '--online' }
    $pyArgs += @('-f', 'json')
    $res = Invoke-CapturedProcess -FilePath $PyPath -Arguments $pyArgs -TimeoutSeconds $TimeoutSeconds
    if ($res.TimedOut -or $res.ExitCode -ne 0) { return $null }
    return (ConvertFrom-PyManagerList -Json ([string]$res.Output))
}

function Resolve-PyUpdateOutcome {
    # Decides an update's verdict from the exit code and the version observed AFTER it.
    # Returns { Status; Success; Note }. Pure - unit-testable.
    #
    # The exit code is evidence, not a verdict. pymanager can install the runtime
    # successfully and THEN exit non-zero from its shortcut/alias refresh - observed on a
    # real 3.14.5 -> 3.14.6 update that exited 1 with
    #   [ERROR] INTERNAL ERROR: AttributeError: 'str' object has no attribute 'satisfied_by'
    # after "Restored site-packages / Restored Scripts", with 3.14.6 correctly in place.
    # Treating exit!=0 as failure would report an applied update as Failed and retry it
    # every run. The observed version is ground truth; the exit code rides in the evidence.
    param(
        [object]$ExitCode,               # nullable: $null when the process never returned one
        [string]$CurrentVersion,
        [string]$ObservedVersion         # '' when the post-update read failed
    )
    $advanced = $false
    if ($ObservedVersion) {
        $cmp = Compare-SoftwareVersion $ObservedVersion $CurrentVersion
        $advanced = ($null -ne $cmp -and $cmp -gt 0)
    }

    if ($advanced) {
        $note = if ($ExitCode -ne 0) { ' The updater exited non-zero after applying the update; treated as applied because the installed version was verified.' } else { '' }
        return [PSCustomObject]@{ Status = 'Succeeded'; Success = $true; Note = "Verified $CurrentVersion -> $ObservedVersion.$note" }
    }
    if ($ObservedVersion) {
        return [PSCustomObject]@{ Status = 'Failed'; Success = $false; Note = "The installed version is still $ObservedVersion." }
    }
    # Nothing observed. A clean exit is merely unverified; a dirty one is a failure.
    if ($ExitCode -eq 0) {
        return [PSCustomObject]@{ Status = 'Verifying'; Success = $false; Note = 'The applied version could not be confirmed.' }
    }
    return [PSCustomObject]@{ Status = 'Failed'; Success = $false; Note = 'The applied version could not be confirmed.' }
}

function Invoke-PythonManagerProvider {
    $provider = 'python-manager'
    if (-not [bool](Get-ObjectPropertyValue $script:CFG.PackageManagers 'PythonManagerEnabled' $false)) { return @() }

    $py = Resolve-PyManagerCommand
    if (-not $py) {
        Write-Log 'Python Install Manager: not found in the current session; provider skipped.' -Level DEBUG
        return @()   # not installed, or a SYSTEM-context run - stay silent
    }

    $timeout = [Math]::Max(30, [int](Get-ObjectPropertyValue $script:CFG.PackageManagers 'TimeoutSeconds' 300))
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    Write-Log "Python Install Manager: discovering runtimes ($py list)." -Level INFO
    $installedInfo = Get-PyManagerRuntimes -PyPath $py -TimeoutSeconds $timeout
    if ($null -eq $installedInfo) {
        $results.Add((New-PatchResult -Name 'Python Install Manager' -PackageId 'Python.PythonInstallManager' -Provider 'python-manager-discovery' -Source $provider -Status 'Failed' -Evidence 'Could not read installed runtimes (py list -f json).'))
        return @($results)
    }
    $onlineInfo = Get-PyManagerRuntimes -PyPath $py -Online -TimeoutSeconds $timeout
    if ($null -eq $onlineInfo) {
        $results.Add((New-PatchResult -Name 'Python Install Manager' -PackageId 'Python.PythonInstallManager' -Provider 'python-manager-discovery' -Source $provider -Status 'Failed' -Evidence 'Could not read the online runtime index (py list --online -f json).'))
        return @($results)
    }
    $installed = @($installedInfo.Runtimes)
    $online    = @($onlineInfo.Runtimes)

    $upgrades  = @(Find-PyManagerUpgrades -Installed $installed -Online $online)
    $unmanaged = @($installed | Where-Object { $_.Unmanaged })
    $managed   = @($installed | Where-Object { -not $_.Unmanaged })
    $evidence  = "Python Install Manager checked; $($managed.Count) managed runtime(s), $($unmanaged.Count) unmanaged, $($upgrades.Count) with an update available."
    $results.Add((New-PatchResult -Name 'Python Install Manager' -PackageId 'Python.PythonInstallManager' -Provider 'python-manager-discovery' -Source $provider -Status 'Completed' -Success $true -Evidence $evidence))

    foreach ($u in $unmanaged) {
        $results.Add((New-PatchResult -Name $u.DisplayName -PackageId $u.Id -Provider $provider -Source $provider -InstalledVersion $u.Version -Status 'Skipped' `
            -Evidence "Runtime is not managed by the Python Install Manager (company: $($u.Company)); it must be updated by whatever installed it." `
            -Remediation 'Update via the owning tool (for example `uv python upgrade`) or the vendor installer.'))
    }

    if ($upgrades.Count -eq 0) { return @($results) }

    $applied = 0
    $max = [int](Get-ObjectPropertyValue $script:CFG.PackageManagers 'MaxUpdatesPerRun' 0)
    foreach ($pkg in $upgrades) {
        $reason = ''
        if (Test-IsDescoped -Item ([PSCustomObject]@{ Name=$pkg.DisplayName; PackageId=$pkg.Id; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
            $results.Add((New-PatchResult -Name $pkg.DisplayName -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Descoped' -Evidence $reason))
            continue
        }
        if ($max -gt 0 -and $applied -ge $max) {
            $results.Add((New-PatchResult -Name $pkg.DisplayName -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Skipped' -Evidence "Per-run update cap ($max) reached; deferred to next run."))
            continue
        }
        # --by-id pins the exact install; a bare tag ('3.14-64') can resolve across companies.
        if ($DryRun) {
            $results.Add((New-PatchResult -Name $pkg.DisplayName -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Planned' -Evidence "Would run: py install --update --by-id $($pkg.Id)."))
            continue
        }

        Write-Log "Python Install Manager: updating $($pkg.Id) $($pkg.Current) -> $($pkg.Available)." -Level INFO
        $upg = Invoke-CapturedProcess -FilePath $py -Arguments @('install', '--update', '--yes', '--by-id', $pkg.Id) -TimeoutSeconds $timeout
        $applied++
        $summary = (([string]$upg.Output -replace '\s+', ' ').Trim())
        if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }

        if ($upg.TimedOut) {
            $results.Add((New-PatchResult -Name $pkg.DisplayName -PackageId $pkg.Id -Provider $provider -Source $provider -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -Status 'Failed' -Evidence "py install --update timed out after ${timeout}s."))
            continue
        }

        # Do not trust the exit code alone: re-read the manager for the applied version.
        $afterInfo = Get-PyManagerRuntimes -PyPath $py -TimeoutSeconds $timeout
        $nowEntry  = if ($null -ne $afterInfo) { @($afterInfo.Runtimes) | Where-Object { $_.Id -eq $pkg.Id } | Select-Object -First 1 } else { $null }
        $nowVer    = if ($nowEntry) { [string]$nowEntry.Version } else { '' }

        $outcome = Resolve-PyUpdateOutcome -ExitCode $upg.ExitCode -CurrentVersion $pkg.Current -ObservedVersion $nowVer
        $results.Add((New-PatchResult -Name $pkg.DisplayName -PackageId $pkg.Id -Provider $provider -Source $provider `
            -InstalledVersion $pkg.Current -AvailableVersion $pkg.Available -ConfirmedVersion $nowVer `
            -Status $outcome.Status -Success $outcome.Success `
            -Evidence "py install --update exit code=$($upg.ExitCode). $($outcome.Note) $summary"))
    }
    return @($results)
}

#endregion

#region -- Native Vendor Updaters -----------------------------------------------------

function Get-VendorUpdaterCatalogue {
    # Built-in catalogue of apps that ship a headless "apply update now" updater
    # (Omaha-style, same interface as Chrome/Edge). Each entry declares how to
    # read the installed version, where the updater lives, and how to run it.
    # Users extend this via VendorUpdaters.ExtraCatalogue (identical shape).
    $builtIn = @(
        [PSCustomObject]@{
            Name                 = 'Brave Browser'
            PackageId            = 'BraveSoftware.BraveBrowser'
            Provider             = 'brave-update'
            WinGetOverlapId      = 'BraveSoftware.BraveBrowser'
            # Binary version first (reflects an applied update immediately);
            # BLBeacon registry beacons are only rewritten on next app launch.
            VersionFilePaths     = @(
                (Join-Path ${env:ProgramFiles} 'BraveSoftware\Brave-Browser\Application\brave.exe')
                (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe')
                (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
            )
            VersionRegistryPaths = @(
                'HKLM:\SOFTWARE\WOW6432Node\BraveSoftware\Brave-Browser\BLBeacon'
                'HKCU:\SOFTWARE\BraveSoftware\Brave-Browser\BLBeacon'
            )
            VersionValueName     = 'version'
            UpdaterPathCandidates = @(
                (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Update\BraveUpdate.exe')
                (Join-Path ${env:ProgramFiles} 'BraveSoftware\Update\BraveUpdate.exe')
                (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Update\BraveUpdate.exe')
            )
            UpdaterArgs          = @('/ua', '/installsource', 'scheduler')
        }
    )
    $extra = @(Get-ObjectPropertyValue $script:CFG.VendorUpdaters 'ExtraCatalogue' @())
    return @($builtIn + $extra)
}

function Invoke-VendorUpdaterProvider {
    param([array]$WinGetCandidates = @())

    if (-not [bool](Get-ObjectPropertyValue $script:CFG.VendorUpdaters 'Enabled' $false)) { return @() }

    $timeout = [Math]::Max(30, [int](Get-ObjectPropertyValue $script:CFG.VendorUpdaters 'NativeTimeoutSeconds' 900))
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in @(Get-VendorUpdaterCatalogue)) {
        $name      = [string]$entry.Name
        $packageId = [string]$entry.PackageId
        $provider  = [string]$entry.Provider
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($provider)) { continue }

        # Locate the installed app's updater; if absent, the app isn't installed - stay silent.
        $updater = Resolve-FirstExistingPath -Candidates @($entry.UpdaterPathCandidates)
        if (-not $updater) {
            Write-Log "Vendor updater '$name': updater not found; app not installed." -Level DEBUG
            continue
        }

        # Defer to WinGet when it already has an actionable candidate for this app.
        $overlapId = [string](Get-ObjectPropertyValue $entry 'WinGetOverlapId' '')
        if ($overlapId -and @($WinGetCandidates | Where-Object { $_.PackageId -like "$overlapId*" }).Count -gt 0) {
            $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -Status 'Skipped' -Evidence 'Already represented by an actionable WinGet candidate.'))
            continue
        }

        $versionValueName = [string](Get-ObjectPropertyValue $entry 'VersionValueName' 'version')
        $versionFilePaths = @(Get-ObjectPropertyValue $entry 'VersionFilePaths' @())
        $currentVersion = Get-InstalledFileVersion -Candidates $versionFilePaths
        if (-not $currentVersion) { $currentVersion = Get-RegistryVersion -Paths @($entry.VersionRegistryPaths) -ValueName $versionValueName }

        $reason = ''
        if (Test-IsDescoped -Item ([PSCustomObject]@{ Name=$name; PackageId=$packageId; Provider=$provider; Source=$provider }) -Reason ([ref]$reason)) {
            $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Descoped' -Evidence $reason))
            continue
        }

        $updaterArgs = @($entry.UpdaterArgs)
        if ($DryRun) {
            $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Planned' -Evidence "Would run native updater: $updater $($updaterArgs -join ' ')."))
            continue
        }

        try {
            Write-Log "${name}: running native updater ($updater $($updaterArgs -join ' '))." -Level INFO
            # -ArgumentList rejects an empty array, and an ExtraCatalogue entry
            # may legitimately declare an updater that takes no arguments.
            $startArgs = @{ FilePath = $updater; PassThru = $true; WindowStyle = 'Hidden' }
            if ($updaterArgs.Count -gt 0) { $startArgs.ArgumentList = $updaterArgs }
            $proc = Start-Process @startArgs
            $completed = $proc.WaitForExit($timeout * 1000)
            if (-not $completed) {
                try { $proc.Kill() } catch { }
                $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Failed' -Evidence "Native updater timed out after ${timeout}s."))
                continue
            }
            $afterVersion = Get-InstalledFileVersion -Candidates $versionFilePaths
            if (-not $afterVersion) { $afterVersion = Get-RegistryVersion -Paths @($entry.VersionRegistryPaths) -ValueName $versionValueName }
            # If we can read a version delta, report Updated/AlreadyCurrent; otherwise
            # the vendor updater ran headlessly and we report Completed.
            $status = if ($currentVersion -and $afterVersion) {
                if ($afterVersion -ne $currentVersion) { 'Updated' } else { 'AlreadyCurrent' }
            } else { 'Completed' }
            $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -AvailableVersion $afterVersion -ConfirmedVersion $afterVersion -Status $status -Success $true -Evidence "Native updater exit code=$($proc.ExitCode); Before=$currentVersion; After=$afterVersion."))
        } catch {
            $results.Add((New-PatchResult -Name $name -PackageId $packageId -Provider $provider -Source $provider -InstalledVersion $currentVersion -Status 'Failed' -Evidence "Vendor updater exception: $_"))
        }
    }
    return @($results)
}

#endregion

#region -- Staleness Report (report-only) ---------------------------------------------

function New-StalenessFinding {
    # Shape for a report-only exposure finding. Severity 'review' = needs
    # attention; 'info' = evidence only (e.g. installed runtime versions).
    param(
        [string]$Category,
        [string]$Item,
        [string]$Detail,
        [ValidateSet('review', 'info')] [string]$Severity = 'info',
        [string]$Recommendation = ''
    )
    return [PSCustomObject]@{
        Category       = $Category
        Item           = $Item
        Detail         = $Detail
        Severity       = $Severity
        Recommendation = $Recommendation
        Timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
}

function Test-IsStale {
    # True when $LastUpdated is older than $MaxAgeDays. Null/unknown date is not
    # treated as stale (we cannot prove staleness without a date).
    param([datetime]$LastUpdated, [int]$MaxAgeDays)
    if ($null -eq $LastUpdated -or $LastUpdated -eq [datetime]::MinValue) { return $false }
    return ((Get-Date) - $LastUpdated).TotalDays -gt $MaxAgeDays
}

function Invoke-StalenessReport {
    # Report-only. Returns an array of findings; NEVER patches. Findings are
    # surfaced in their own report section and excluded from applied/failed counts.
    $cfg = Get-ObjectPropertyValue $script:CFG 'StalenessReport' $null
    if ($null -eq $cfg -or -not [bool](Get-ObjectPropertyValue $cfg 'Enabled' $false)) { return @() }

    $findings = [System.Collections.Generic.List[pscustomobject]]::new()

    # --- Microsoft Defender signature age ---
    if ([bool](Get-ObjectPropertyValue $cfg 'DefenderSignatures' $true)) {
        try {
            $mp = Get-MpComputerStatus -EA Stop
            $maxAge = [int](Get-ObjectPropertyValue $cfg 'DefenderMaxAgeDays' 7)
            $lastUpdated = [datetime]$mp.AntivirusSignatureLastUpdated
            $ageDays = [Math]::Round(((Get-Date) - $lastUpdated).TotalDays, 1)
            if (Test-IsStale -LastUpdated $lastUpdated -MaxAgeDays $maxAge) {
                $findings.Add((New-StalenessFinding -Category 'Antivirus definitions' -Item 'Microsoft Defender' -Detail "Signatures last updated $($lastUpdated.ToString('yyyy-MM-dd HH:mm')) (${ageDays} days ago), older than the ${maxAge}-day threshold." -Severity 'review' -Recommendation 'Run Update-MpSignature or check the Defender update channel.'))
            } else {
                $findings.Add((New-StalenessFinding -Category 'Antivirus definitions' -Item 'Microsoft Defender' -Detail "Signatures current (updated ${ageDays} days ago)." -Severity 'info'))
            }
        } catch {
            Write-Log "Staleness: Defender status unavailable: $_" -Level DEBUG
        }
    }

    # --- Windows feature-update lag ---
    if ([bool](Get-ObjectPropertyValue $cfg 'FeatureUpdateLag' $true)) {
        try {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA Stop
            $display = [string](Get-ObjectPropertyValue $cv 'DisplayVersion' (Get-ObjectPropertyValue $cv 'ReleaseId' ''))
            $build = "$([string]$cv.CurrentBuild).$([string](Get-ObjectPropertyValue $cv 'UBR' '0'))"
            $installEpoch = [int64](Get-ObjectPropertyValue $cv 'InstallDate' 0)
            $maxAge = [int](Get-ObjectPropertyValue $cfg 'FeatureUpdateMaxAgeDays' 365)
            if ($installEpoch -gt 0) {
                $installed = [System.DateTimeOffset]::FromUnixTimeSeconds($installEpoch).LocalDateTime
                $ageDays = [Math]::Round(((Get-Date) - $installed).TotalDays, 0)
                if (Test-IsStale -LastUpdated $installed -MaxAgeDays $maxAge) {
                    $findings.Add((New-StalenessFinding -Category 'Windows feature version' -Item "Windows $display (build $build)" -Detail "This feature update was installed ${ageDays} days ago, past the ${maxAge}-day threshold. A newer Windows feature version may be available." -Severity 'review' -Recommendation 'Review Windows feature-update eligibility; PatchManager does not apply feature updates automatically.'))
                } else {
                    $findings.Add((New-StalenessFinding -Category 'Windows feature version' -Item "Windows $display (build $build)" -Detail "Feature version installed ${ageDays} days ago." -Severity 'info'))
                }
            }
        } catch {
            Write-Log "Staleness: Windows version info unavailable: $_" -Level DEBUG
        }
    }

    # --- Dev runtime inventory (informational; no network 'latest' claim) ---
    if ([bool](Get-ObjectPropertyValue $cfg 'DevRuntimes' $true)) {
        $runtimes = @(
            @{ Item = '.NET SDK'; Exe = 'dotnet'; Args = @('--version') }
            @{ Item = 'Python';   Exe = 'python'; Args = @('--version') }
            @{ Item = 'Node.js';  Exe = 'node';   Args = @('--version') }
        )
        foreach ($rt in $runtimes) {
            $cmd = Get-Command $rt.Exe -EA SilentlyContinue
            if (-not $cmd) { continue }
            try {
                $res = Invoke-CapturedProcess -FilePath $cmd.Source -Arguments $rt.Args -TimeoutSeconds 30
                $ver = (([string]$res.Output -replace '\s+', ' ').Trim())
                if ($ver) {
                    $findings.Add((New-StalenessFinding -Category 'Developer runtime' -Item $rt.Item -Detail "Installed: $ver. Verify against the vendor's supported-version lifecycle." -Severity 'info'))
                }
            } catch { }
        }
    }

    $reviewCount = @($findings | Where-Object { $_.Severity -eq 'review' }).Count
    Write-Log "Staleness report: $($findings.Count) finding(s), $reviewCount need review." -Level $(if ($reviewCount -gt 0) { 'WARN' } else { 'INFO' })
    return @($findings)
}

#endregion

#region -- End-of-Life (report-only) --------------------------------------------------
# Authoritative end-of-life / end-of-support data from endoflife.date. Report-only:
# an app can be fully patched yet sit on a release line the vendor abandoned. EOL
# means "plan a major-version upgrade", never an automatic patch, so findings live
# in their own report section and never affect applied/failed counts.

function Get-CachedApiJson {
    # Generic cached GET against a JSON API. Returns the parsed object, or $null.
    # Caching/TTL/offline/stale-fallback mirror Get-CISAKEVData. Shared by the
    # endoflife.date and NVD providers.
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$CacheKey,
        [Parameter(Mandatory)] $Cfg,
        [hashtable]$Headers = @{},
        [string]$Label = 'API'
    )
    $cacheDir = [string](Get-ObjectPropertyValue $Cfg 'CachePath' 'C:\ProgramData\PatchManager\Cache')
    if (-not (Test-Path $cacheDir)) {
        try { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null } catch { }
    }
    $safeKey    = ($CacheKey -replace '[^A-Za-z0-9._-]', '_')
    $cacheFile  = Join-Path $cacheDir "$safeKey.json"
    $cacheHours = [double](Get-ObjectPropertyValue $Cfg 'CacheHours' 168)
    $offline    = [bool](Get-ObjectPropertyValue $Cfg 'Offline' $false)

    if (Test-Path $cacheFile) {
        $age = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalHours
        if ($offline -or $age -lt $cacheHours) {
            try { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
    } elseif ($offline) {
        return $null   # offline with nothing cached
    }

    $hdrs = @{ 'User-Agent' = 'PatchManager'; 'Accept' = 'application/json' }
    foreach ($k in $Headers.Keys) { $hdrs[$k] = $Headers[$k] }
    try {
        $resp = Invoke-RestMethod -Uri $Uri -TimeoutSec 30 -Headers $hdrs -EA Stop
        try { $resp | ConvertTo-Json -Depth 12 | Set-Content $cacheFile -Encoding UTF8 } catch { }
        return $resp
    } catch {
        Write-Log "${Label}: fetch '$Uri' failed: $_. $(if (Test-Path $cacheFile) { 'Using stale cache.' } else { 'No cache available.' })" -Level DEBUG
        if (Test-Path $cacheFile) {
            try { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
        return $null
    }
}

function Get-EndOfLifeCached {
    # Cached GET against endoflife.date. Returns the parsed JSON envelope, or $null.
    param(
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [string]$CacheKey,
        [Parameter(Mandatory)] $Cfg
    )
    $base = [string](Get-ObjectPropertyValue $Cfg 'ApiBaseUrl' 'https://endoflife.date/api/v1')
    return Get-CachedApiJson -Uri "$base/$RelativePath" -CacheKey $CacheKey -Cfg $Cfg `
        -Headers @{ 'User-Agent' = 'PatchManager-EOL' } -Label 'End-of-life'
}

function Get-EndOfLifeProduct {
    # Returns one product's .result object (with .releases), or $null.
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] $Cfg)
    $envelope = Get-EndOfLifeCached -RelativePath "products/$Name" -CacheKey "eol_$Name" -Cfg $Cfg
    if ($null -eq $envelope) { return $null }
    return (Get-ObjectPropertyValue $envelope 'result' $null)
}

function Get-EndOfLifeIndex {
    # Returns the product index (.result array of {name,aliases,label,...}), or @().
    param([Parameter(Mandatory)] $Cfg)
    $envelope = Get-EndOfLifeCached -RelativePath 'products' -CacheKey 'eol_index' -Cfg $Cfg
    if ($null -eq $envelope) { return @() }
    return @(Get-ObjectPropertyValue $envelope 'result' @())
}

function New-EndOfLifeFinding {
    # Shape for a report-only end-of-life finding. Severity 'review' = out of (or
    # near) support and needs action; 'info' = supported/evidence only.
    param(
        [string]$Product,
        [string]$Item,
        [string]$InstalledVersion,
        [string]$Cycle = '',
        [ValidateSet('EOL', 'NearEOL', 'PatchBehind', 'Supported', 'Unknown')] [string]$Status = 'Unknown',
        [string]$EolDate = '',
        [object]$DaysRemaining = $null,
        [string]$LatestSupported = '',
        [ValidateSet('review', 'info')] [string]$Severity = 'info',
        [string]$Detail = '',
        [string]$Recommendation = ''
    )
    return [PSCustomObject]@{
        Product          = $Product
        Item             = $Item
        InstalledVersion = $InstalledVersion
        Cycle            = $Cycle
        Status           = $Status
        EolDate          = $EolDate
        DaysRemaining    = $DaysRemaining
        LatestSupported  = $LatestSupported
        Severity         = $Severity
        Detail           = $Detail
        Recommendation   = $Recommendation
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
}

function ConvertTo-VersionCycleKeys {
    # Candidate endoflife cycle names for an installed version, most specific first:
    # "3.9.13" -> @('3.9','3'); "v20.11" -> @('20.11','20'); "8.0.10" -> @('8.0','8').
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return @() }
    $m = [regex]::Match($Version, '(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return @() }
    $maj = $m.Groups[1].Value
    $keys = @()
    if ($m.Groups[2].Success) { $keys += "$maj.$($m.Groups[2].Value)" }
    $keys += $maj
    return $keys
}

function Get-ReleaseLatestName {
    # Safely reads release.latest.name ('' when absent) under StrictMode.
    param($Release)
    $latest = Get-ObjectPropertyValue $Release 'latest' $null
    if ($null -eq $latest) { return '' }
    return [string](Get-ObjectPropertyValue $latest 'name' '')
}

function Resolve-EolReleaseForVersion {
    # Picks the release whose cycle name matches the installed major(.minor).
    # Returns the release object, or $null. Pure - unit-testable with fixtures.
    param([array]$Releases, [string]$InstalledVersion)
    if (-not $Releases -or $Releases.Count -eq 0) { return $null }
    foreach ($key in (ConvertTo-VersionCycleKeys -Version $InstalledVersion)) {
        $match = $Releases | Where-Object { [string]$_.name -ieq $key } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

function Resolve-WindowsEolRelease {
    # Maps a running Windows build to its endoflife release. Multiple cycles can
    # share a build (consumer 'W' vs enterprise 'E' vs 'LTS'/'IoT'); disambiguate
    # by edition. Pure - unit-testable with fixtures.
    param([array]$Releases, [string]$Build, [string]$Edition)
    if (-not $Releases -or [string]::IsNullOrWhiteSpace($Build)) { return $null }
    $buildPattern = "(^|\.)$([regex]::Escape($Build))$"
    $buildMatches = @($Releases | Where-Object { (Get-ReleaseLatestName $_) -match $buildPattern })
    if ($buildMatches.Count -eq 0) { return $null }

    $isEnterprise = $Edition -match 'Enterprise|Education'
    $suffix = if ($isEnterprise) { '-e' } else { '-w' }
    # Prefer the edition-matching client cycle (exclude LTS/IoT for a normal SKU).
    $preferred = $buildMatches |
        Where-Object { ([string]$_.name -like "*$suffix") -and (-not ([string]$_.name -match 'lts|iot')) } |
        Select-Object -First 1
    if ($preferred) { return $preferred }
    $nonLts = $buildMatches | Where-Object { -not ([string]$_.name -match 'lts|iot') } | Select-Object -First 1
    if ($nonLts) { return $nonLts }
    return ($buildMatches | Select-Object -First 1)
}

function Test-EolStatus {
    # Classifies a release: EOL / NearEOL / Supported / Unknown from isEol + eolFrom.
    # isEol (when present) is authoritative; the date refines NearEOL vs Supported.
    param($Release, [int]$WarnWithinDays = 90)
    if ($null -eq $Release) {
        return [PSCustomObject]@{ Status = 'Unknown'; EolDate = ''; DaysRemaining = $null }
    }
    $isEol     = Get-ObjectPropertyValue $Release 'isEol' $null
    $eolFromRaw = [string](Get-ObjectPropertyValue $Release 'eolFrom' '')

    $days = $null
    if ($eolFromRaw -match '^\d{4}-\d{2}-\d{2}') {
        try {
            $eolDate = [datetime]::ParseExact($eolFromRaw.Substring(0, 10), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $days = [int][Math]::Floor(($eolDate - (Get-Date).Date).TotalDays)
        } catch { }
    }

    $status = 'Unknown'
    if ($isEol -eq $true) {
        $status = 'EOL'
    } elseif ($isEol -eq $false) {
        $status = if ($null -ne $days -and $days -le $WarnWithinDays) { 'NearEOL' } else { 'Supported' }
    } elseif ($null -ne $days) {
        $status = if ($days -lt 0) { 'EOL' } elseif ($days -le $WarnWithinDays) { 'NearEOL' } else { 'Supported' }
    }
    return [PSCustomObject]@{ Status = $status; EolDate = $eolFromRaw; DaysRemaining = $days }
}

function New-EolFindingFromRelease {
    # Composes Test-EolStatus + New-EndOfLifeFinding for one resolved release.
    param(
        [string]$Product, [string]$Item, [string]$InstalledVersion,
        $Release, [int]$WarnWithinDays = 90, [string]$Recommendation = '',
        # Windows reports a bare build ('26200') against a latest of '10.0.26200' -
        # different scales, so patch-drift comparison is meaningless there.
        [switch]$SkipPatchDrift
    )
    if ($null -eq $Release) {
        return New-EndOfLifeFinding -Product $Product -Item $Item -InstalledVersion $InstalledVersion `
            -Status 'Unknown' -Severity 'info' `
            -Detail 'No matching endoflife.date release for the installed version.'
    }
    $cycle  = [string](Get-ObjectPropertyValue $Release 'name' '')
    $latest = Get-ReleaseLatestName $Release
    $st     = Test-EolStatus -Release $Release -WarnWithinDays $WarnWithinDays

    $status = $st.Status
    $detail = switch ($status) {
        'EOL'       { "Release $cycle reached end-of-life on $($st.EolDate). Latest supported: $latest." }
        'NearEOL'   { "Release $cycle reaches end-of-life on $($st.EolDate) (in $($st.DaysRemaining) day(s)). Latest supported: $latest." }
        'Supported' { "Release $cycle is supported$(if ($st.EolDate) { " until $($st.EolDate)" }). Latest: $latest." }
        default     { "Lifecycle status could not be determined for release $cycle." }
    }
    $rec = if ($status -in @('EOL', 'NearEOL')) { $Recommendation } else { '' }

    # A supported release line still leaves patch-level drift: 3.14.5 on a cycle whose
    # latest is 3.14.6 is behind on security fixes even though 3.14 lives until 2030.
    # endoflife.date already told us the latest; grade it instead of discarding it.
    if ($status -eq 'Supported' -and $latest -and -not $SkipPatchDrift) {
        $cmp = Compare-SoftwareVersion $InstalledVersion $latest
        if ($null -ne $cmp -and $cmp -lt 0) {
            $status = 'PatchBehind'
            $detail = "Installed $InstalledVersion is behind $latest, the latest patch release of the supported $cycle line$(if ($st.EolDate) { " (supported until $($st.EolDate))" })."
            $rec    = "Update $Item to $latest."
        }
    }

    $sev = if ($status -in @('EOL', 'NearEOL', 'PatchBehind')) { 'review' } else { 'info' }
    return New-EndOfLifeFinding -Product $Product -Item $Item -InstalledVersion $InstalledVersion `
        -Cycle $cycle -Status $status -EolDate $st.EolDate -DaysRemaining $st.DaysRemaining `
        -LatestSupported $latest -Severity $sev -Detail $detail -Recommendation $rec
}

function Invoke-EndOfLifeReport {
    # Report-only. Returns findings; NEVER patches. Each lookup is wrapped so a
    # network hiccup yields an Unknown/info note rather than failing the run.
    $cfg = Get-ObjectPropertyValue $script:CFG 'EndOfLife' $null
    if ($null -eq $cfg -or -not [bool](Get-ObjectPropertyValue $cfg 'Enabled' $false)) { return @() }

    $warn     = [int](Get-ObjectPropertyValue $cfg 'WarnWithinDays' 90)
    $findings = [System.Collections.Generic.List[pscustomobject]]::new()
    $curated  = @('windows', 'dotnet', 'python', 'nodejs')

    # --- Windows OS end-of-support (authoritative) ---
    if ([bool](Get-ObjectPropertyValue $cfg 'CheckWindows' $true)) {
        try {
            $cv      = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA Stop
            $build   = [string]$cv.CurrentBuild
            $display = [string](Get-ObjectPropertyValue $cv 'DisplayVersion' (Get-ObjectPropertyValue $cv 'ReleaseId' ''))
            $edition = [string](Get-ObjectPropertyValue $cv 'EditionID' '')
            $product = Get-EndOfLifeProduct -Name 'windows' -Cfg $cfg
            if ($product) {
                $rel = Resolve-WindowsEolRelease -Releases @($product.releases) -Build $build -Edition $edition
                $findings.Add((New-EolFindingFromRelease -Product 'windows' -Item "Windows $display (build $build)" `
                    -InstalledVersion $build -Release $rel -WarnWithinDays $warn -SkipPatchDrift `
                    -Recommendation 'Upgrade to a supported Windows feature version.'))
            }
        } catch { Write-Log "End-of-life: Windows check failed: $_" -Level DEBUG }
    }

    # --- Developer runtimes (.NET / Python / Node.js) ---
    if ([bool](Get-ObjectPropertyValue $cfg 'CheckRuntimes' $true)) {
        $runtimes = @(
            @{ Item = '.NET';    Product = 'dotnet'; Exe = 'dotnet'; Args = @('--version') }
            @{ Item = 'Python';  Product = 'python'; Exe = 'python'; Args = @('--version') }
            @{ Item = 'Node.js'; Product = 'nodejs'; Exe = 'node';   Args = @('--version') }
        )
        foreach ($rt in $runtimes) {
            $cmd = Get-Command $rt.Exe -EA SilentlyContinue
            if (-not $cmd) { continue }
            $ver = ''
            try {
                $res = Invoke-CapturedProcess -FilePath $cmd.Source -Arguments $rt.Args -TimeoutSeconds 30
                $ver = ([string]$res.Output -split '\r?\n' | ForEach-Object { ([regex]::Match($_, '\d+\.\d+(\.\d+)?')).Value } | Where-Object { $_ } | Select-Object -First 1)
            } catch { }
            if (-not $ver) { continue }
            $product = Get-EndOfLifeProduct -Name $rt.Product -Cfg $cfg
            if (-not $product) { continue }
            $rel = Resolve-EolReleaseForVersion -Releases @($product.releases) -InstalledVersion $ver
            $findings.Add((New-EolFindingFromRelease -Product $rt.Product -Item $rt.Item `
                -InstalledVersion $ver -Release $rel -WarnWithinDays $warn `
                -Recommendation "Upgrade $($rt.Item) to a supported release."))
        }
    }

    # --- Best-effort inventory scan (informational; only EOL/NearEOL surfaced) ---
    if ([bool](Get-ObjectPropertyValue $cfg 'InventoryScan' $false)) {
        try {
            $index = Get-EndOfLifeIndex -Cfg $cfg
            if ($index.Count -gt 0) {
                $maxLookups = [int](Get-ObjectPropertyValue $cfg 'InventoryMaxLookups' 40)
                $checked    = [System.Collections.Generic.HashSet[string]]::new()
                $lookups    = 0
                # Reuse the inventory Invoke-Main already built; a standalone call
                # (e.g. unit tests) falls back to a fresh enumeration.
                $apps = if (@($script:Inventory).Count -gt 0) { @($script:Inventory) } else { @(Get-SoftwareInventory) }
                foreach ($app in $apps) {
                    if ($lookups -ge $maxLookups) { break }
                    $name = [string]$app.Name
                    $ver  = [string]$app.Version
                    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($ver)) { continue }

                    $prod = $index | Where-Object {
                        $pn = [string]$_.name
                        if ($curated -contains $pn) { return $false }
                        $label = [string](Get-ObjectPropertyValue $_ 'label' '')
                        $aliasHit = @(@(Get-ObjectPropertyValue $_ 'aliases' @()) | Where-Object { ([string]$_).Length -ge 4 -and (Test-WordMatch $name ([string]$_)) }).Count -gt 0
                        ($label.Length -ge 4 -and (Test-WordMatch $name $label)) -or
                        ($pn.Length    -ge 4 -and (Test-WordMatch $name $pn))    -or
                        $aliasHit
                    } | Select-Object -First 1
                    if (-not $prod) { continue }
                    if (-not $checked.Add([string]$prod.name)) { continue }   # one finding per product
                    $lookups++

                    $full = Get-EndOfLifeProduct -Name ([string]$prod.name) -Cfg $cfg
                    if (-not $full) { continue }
                    $rel = Resolve-EolReleaseForVersion -Releases @($full.releases) -InstalledVersion $ver
                    $st  = Test-EolStatus -Release $rel -WarnWithinDays $warn
                    if ($st.Status -in @('EOL', 'NearEOL')) {
                        $findings.Add((New-EolFindingFromRelease -Product ([string]$prod.name) -Item $name `
                            -InstalledVersion $ver -Release $rel -WarnWithinDays $warn `
                            -Recommendation "Plan an upgrade of $name to a supported release."))
                    }
                }
            }
        } catch { Write-Log "End-of-life: inventory scan failed: $_" -Level DEBUG }
    }

    $reviewCount = @($findings | Where-Object { $_.Severity -eq 'review' }).Count
    Write-Log "End-of-life report: $($findings.Count) finding(s), $reviewCount needing review (out of support, near EOL, or behind the latest patch)." -Level $(if ($reviewCount -gt 0) { 'WARN' } else { 'INFO' })
    return @($findings)
}

#endregion

#region -- Firmware / BIOS (opt-in) ---------------------------------------------------

function Test-OnACPower {
    # True if on AC power or no battery (desktop/VM). Firmware updates on battery
    # are dangerous, so the firmware provider refuses to run without AC.
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -EA SilentlyContinue)
        if ($batteries.Count -eq 0) { return $true }   # no battery = desktop = wired
        # BatteryStatus 2 = "AC / plugged in" per the CIM schema.
        return @($batteries | Where-Object { $_.BatteryStatus -eq 2 }).Count -gt 0
    } catch {
        return $true   # can't tell -> don't block (pre-flight already guards this)
    }
}

function Get-FirmwareCatalogue {
    # Maps system manufacturer to its OEM update CLI. Scan then apply with reboots
    # suppressed. Reboot-required is surfaced via the result, never auto-actioned.
    return @(
        [PSCustomObject]@{
            Match     = 'Dell'
            Name      = 'Dell firmware & drivers'
            Provider  = 'firmware-dell'
            Tool      = 'Dell Command | Update'
            Paths     = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe')
                (Join-Path ${env:ProgramFiles} 'Dell\CommandUpdate\dcu-cli.exe')
            )
            ScanArgs  = @('/scan')
            ApplyArgs = @('/applyUpdates', '-reboot=disable')
            # Dell Command Update documented codes: 0=success, 1=reboot required,
            # 2=fatal error, 3=error, 4=invalid system, 5=reboot + rescan required.
            RebootCodes = @(1, 5)
        }
        [PSCustomObject]@{
            Match     = 'HP|Hewlett'
            Name      = 'HP firmware & drivers'
            Provider  = 'firmware-hp'
            Tool      = 'HP Image Assistant'
            Paths     = @(
                (Join-Path ${env:ProgramFiles} 'HP\HPIA\HPImageAssistant.exe')
                (Join-Path ${env:ProgramFiles(x86)} 'HP\HPIA\HPImageAssistant.exe')
            )
            ScanArgs  = @('/Operation:Analyze', '/Silent', '/Category:BIOS,Firmware', "/ReportFolder:$env:TEMP\HPIA")
            ApplyArgs = @('/Operation:Install', '/Silent', '/Category:BIOS,Firmware', "/ReportFolder:$env:TEMP\HPIA")
            # HP Image Assistant uses the MSI convention: 3010 = success, reboot required.
            RebootCodes = @(3010)
        }
        [PSCustomObject]@{
            Match     = 'Lenovo'
            Name      = 'Lenovo firmware & drivers'
            Provider  = 'firmware-lenovo'
            Tool      = 'Lenovo System Update'
            Paths     = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Lenovo\System Update\tvsu.exe')
            )
            ScanArgs  = @('/CM', '-search', 'A', '-action', 'LIST', '-noicon')
            ApplyArgs = @('/CM', '-search', 'A', '-action', 'INSTALL', '-noreboot', '-noicon')
            # Lenovo System Update publishes no reliable CLI exit-code table:
            # only 0 is trusted as success; anything else is reported as failed
            # with the tool output as evidence.
            RebootCodes = @()
        }
    )
}

function Invoke-FirmwareProvider {
    if (-not [bool](Get-ObjectPropertyValue (Get-ObjectPropertyValue $script:CFG 'Firmware' $null) 'Enabled' $false)) { return @() }

    $manufacturer = ''
    try { $manufacturer = [string](Get-CimInstance -ClassName Win32_ComputerSystem -EA Stop).Manufacturer } catch { }
    $entry = Get-FirmwareCatalogue | Where-Object { $manufacturer -imatch $_.Match } | Select-Object -First 1

    if (-not $entry) {
        return @((New-PatchResult -Name 'Firmware' -PackageId 'Firmware.OEM' -Provider 'firmware' -Source 'firmware' -Status 'Skipped' -Evidence "Firmware provider enabled, but manufacturer '$manufacturer' has no supported OEM tool mapping (Dell, HP, Lenovo)."))
    }

    $provider = $entry.Provider
    if (-not (Test-OnACPower)) {
        return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Skipped' -Evidence 'Firmware updates skipped: device is on battery. Connect AC power and rerun.'))
    }

    $tool = Resolve-FirstExistingPath -Candidates @($entry.Paths)
    if (-not $tool) {
        return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Skipped' -Evidence "$($entry.Tool) is not installed. Install it to enable OEM firmware/driver updates."))
    }

    if ($DryRun) {
        return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Planned' -Evidence "Would run: $tool $($entry.ScanArgs -join ' ') then $($entry.ApplyArgs -join ' ')."))
    }

    $timeout = [Math]::Max(120, [int](Get-ObjectPropertyValue $script:CFG.Firmware 'TimeoutSeconds' 1800))
    try {
        Write-Log "$($entry.Name): scanning ($tool $($entry.ScanArgs -join ' '))." -Level INFO
        $scan = Invoke-CapturedProcess -FilePath $tool -Arguments @($entry.ScanArgs) -TimeoutSeconds $timeout
        Write-Log "$($entry.Name): applying updates (reboot suppressed)." -Level INFO
        $apply = Invoke-CapturedProcess -FilePath $tool -Arguments @($entry.ApplyArgs) -TimeoutSeconds $timeout

        $summary = (("scan=$($scan.ExitCode); apply=$($apply.ExitCode); " + ([string]$apply.Output -replace '\s+', ' ')).Trim())
        if ($summary.Length -gt 600) { $summary = $summary.Substring(0, 600) + '...' }

        if ($apply.TimedOut) {
            return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Failed' -Evidence "OEM firmware tool timed out after ${timeout}s."))
        }
        # Reboot codes are vendor-specific and declared per catalogue entry. A
        # shared list previously treated Dell's exit 2 (fatal error) as success.
        $rebootCodes = @(Get-ObjectPropertyValue $entry 'RebootCodes' @())
        if ($apply.ExitCode -eq 0 -or $apply.ExitCode -in $rebootCodes) {
            $reboot = $apply.ExitCode -in $rebootCodes
            return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Completed' -Success $true -RebootRequired $reboot -Evidence "OEM firmware apply completed. $summary"))
        }
        return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Failed' -Evidence "OEM firmware apply reported exit code $($apply.ExitCode). $summary"))
    } catch {
        return @((New-PatchResult -Name $entry.Name -PackageId "Firmware.$($entry.Provider)" -Provider $provider -Source $provider -Status 'Failed' -Evidence "Firmware provider exception: $_"))
    }
}

#endregion

#region -- Microsoft Store Client -----------------------------------------------------

function Resolve-StoreCliPath {
    $cmd = Get-Command 'store.exe' -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cmd = Get-Command 'store' -EA SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $userExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\store.exe"
    try {
        if (Test-Path $userExe) { return $userExe }
    } catch { }

    return $null
}

function Test-StoreCimUpdateScanAvailable {
    try {
        $class = Get-CimClass -Namespace 'root\cimv2\mdm\dmmap' `
                              -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' `
                              -EA Stop
        return $class.CimClassMethods.ContainsKey('UpdateScanMethod')
    } catch {
        return $false
    }
}

function Get-StoreAppxSnapshot {
    $snapshot = [ordered]@{}

    try {
        Get-AppxPackage -AllUsers -EA SilentlyContinue |
            Where-Object { $_.Name -and $_.Version -and -not $_.IsFramework } |
            ForEach-Object {
                $key = $_.Name
                $snapshot[$key] = [PSCustomObject]@{
                    Name              = $_.Name
                    PackageFullName   = $_.PackageFullName
                    PackageFamilyName = $_.PackageFamilyName
                    Publisher         = $_.Publisher
                    Version           = [string]$_.Version
                    Architecture      = [string]$_.Architecture
                    InstallLocation   = $_.InstallLocation
                    SignatureKind     = [string]$_.SignatureKind
                    IsFramework       = $_.IsFramework
                    NonRemovable      = $_.NonRemovable
                }
            }
    } catch {
        Write-Log "Microsoft Store AppX snapshot failed: $_" -Level DEBUG
    }

    return $snapshot
}

function ConvertTo-StoreMatchKey {
    param($Value)
    return (([string]$Value).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Compare-VersionText {
    param($Left, $Right)

    try {
        $leftVersion = [version]([string]$Left)
        $rightVersion = [version]([string]$Right)
        return $leftVersion.CompareTo($rightVersion)
    } catch {
        return $null
    }
}

function Find-StoreSnapshotPackage {
    param(
        [hashtable]$Snapshot,
        [object]$Candidate
    )

    if (-not $Snapshot -or -not $Candidate) { return $null }

    $candidateKey = ConvertTo-StoreMatchKey $Candidate.Name
    if ([string]::IsNullOrWhiteSpace($candidateKey)) { return $null }

    foreach ($pkg in $Snapshot.Values) {
        $packageKeys = @(
            ConvertTo-StoreMatchKey $pkg.Name
            ConvertTo-StoreMatchKey $pkg.PackageFamilyName
            ConvertTo-StoreMatchKey $pkg.PackageFullName
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        foreach ($packageKey in $packageKeys) {
            if ($packageKey.Contains($candidateKey) -or $candidateKey.Contains($packageKey)) {
                return $pkg
            }
        }
    }

    return $null
}

function Compare-StoreAppxSnapshot {
    param(
        [Parameter(Mandatory)] [hashtable]$Before,
        [Parameter(Mandatory)] [hashtable]$After
    )

    $changes = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($key in $After.Keys) {
        $afterPkg = $After[$key]
        $beforePkg = if ($Before.Contains($key)) { $Before[$key] } else { $null }

        if (-not $beforePkg) {
            $changes.Add([PSCustomObject]@{
                Name      = $afterPkg.Name
                PackageId = $afterPkg.PackageFamilyName
                Source    = 'store-client'
                Provider  = 'microsoft-store-client'
                OldVer    = ''
                NewVer    = $afterPkg.Version
                Success   = $true
                Status    = 'Detected'
                Reason    = "New Store/AppX package detected after Store update trigger. FullName=$($afterPkg.PackageFullName); Publisher=$($afterPkg.Publisher); Architecture=$($afterPkg.Architecture)"
                IsKEV     = $false
                Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            })
            continue
        }

        if ([string]$beforePkg.Version -ne [string]$afterPkg.Version) {
            $changes.Add([PSCustomObject]@{
                Name      = $afterPkg.Name
                PackageId = $afterPkg.PackageFamilyName
                Source    = 'store-client'
                Provider  = 'microsoft-store-client'
                OldVer    = $beforePkg.Version
                NewVer    = $afterPkg.Version
                Success   = $true
                Status    = 'Updated'
                Reason    = "Store/AppX version changed. FullName=$($afterPkg.PackageFullName); Publisher=$($afterPkg.Publisher); Architecture=$($afterPkg.Architecture); InstallLocation=$($afterPkg.InstallLocation)"
                IsKEV     = $false
                Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            })
        }
    }

    return $changes
}

function Invoke-StoreCimUpdateScan {
    try {
        $instances = @(Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' `
                                      -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' `
                                      -EA Stop)
        if ($instances.Count -eq 0) {
            Invoke-CimMethod -Namespace 'root\cimv2\mdm\dmmap' `
                             -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' `
                             -MethodName 'UpdateScanMethod' `
                             -EA Stop | Out-Null
        } else {
            foreach ($instance in $instances) {
                Invoke-CimMethod -InputObject $instance -MethodName 'UpdateScanMethod' -EA Stop | Out-Null
            }
        }
        return $true
    } catch {
        Write-Log "Microsoft Store client update scan failed: $_" -Level WARN
        return $false
    }
}

function Invoke-StoreCliCommand {
    # Thin wrapper over Invoke-CapturedProcess preserving this function's historic
    # return shape ({ExitCode; TimedOut; Failed; Output}). The old Start-Process
    # implementation left .ExitCode $null with redirected streams on PS 5.1, which
    # silently disabled the "Store CLI exit code 5 -> MDM bridge fallback" logic.
    param(
        [Parameter(Mandatory)] [string]$StoreCli,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [string[]]$StandardInputLines = @()
    )

    $result = Invoke-CapturedProcess -FilePath $StoreCli -Arguments $Arguments `
                  -TimeoutSeconds $TimeoutSeconds -StandardInputLines $StandardInputLines
    return [PSCustomObject]@{
        ExitCode = $result.ExitCode
        TimedOut = [bool]$result.TimedOut
        # Failed = the process never ran/returned a code (launch exception). A
        # non-zero exit code is the caller's decision, exactly as before.
        Failed   = (-not $result.TimedOut -and $null -eq $result.ExitCode)
        Output   = [string]$result.Output
    }
}

function Get-StoreCliUpdateCandidates {
    param(
        [Parameter(Mandatory)] [string]$StoreCli,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )

    $script:StoreCliDiscoveryFailed = $false
    $script:StoreCliDiscoveryReason = ''

    $result = Invoke-StoreCliCommand -StoreCli $StoreCli -Arguments @('updates') -TimeoutSeconds $TimeoutSeconds -StandardInputLines @('n')
    if ($result.TimedOut) {
        $script:StoreCliDiscoveryFailed = $true
        $script:StoreCliDiscoveryReason = $result.Output
        Write-Log "Microsoft Store client: Store CLI discovery timed out. $($result.Output)" -Level WARN
        return @()
    }
    if ([bool](Get-ObjectPropertyValue $result 'Failed' $false)) {
        $script:StoreCliDiscoveryFailed = $true
        $script:StoreCliDiscoveryReason = $result.Output
        Write-Log "Microsoft Store client: Store CLI discovery failed. $($script:StoreCliDiscoveryReason)" -Level WARN
        return @()
    }
    if ($null -ne $result.ExitCode -and $result.ExitCode -ne 0) {
        $summary = (([string]$result.Output -replace '\s+', ' ').Trim())
        if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
        $script:StoreCliDiscoveryFailed = $true
        $script:StoreCliDiscoveryReason = "Store CLI exited with code $($result.ExitCode). $summary"
        Write-Log "Microsoft Store client: Store CLI discovery failed. $($script:StoreCliDiscoveryReason)" -Level WARN
        return @()
    }

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tableSeparatorPattern = '(?:\u2502|\u00d4\u00f6\u00e9)'
    foreach ($line in ([string]$result.Output -split '\r?\n')) {
        if ($line -notmatch "^\s*$tableSeparatorPattern") { continue }
        $parts = @($line -split $tableSeparatorPattern | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -lt 4 -or $parts[0] -eq 'Name') { continue }

        $candidates.Add([PSCustomObject]@{
            Name      = $parts[0]
            Publisher = $parts[1]
            Version   = $parts[2]
            Date      = $parts[3]
        })
    }

    if ($candidates.Count -gt 0) {
        Write-Log "Microsoft Store client: Store CLI discovered $($candidates.Count) update candidate(s): $(($candidates | ForEach-Object { $_.Name }) -join ', ')." -Level INFO
    } else {
        $summary = (([string]$result.Output -replace '\s+', ' ').Trim())
        if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
        Write-Log "Microsoft Store client: Store CLI discovered no update candidates. Output: $summary" -Level DEBUG
    }

    return @($candidates)
}

function Test-IsAppInUseUpdateFailure {
    param([string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }
    return $Output -imatch '0x80073D02|resources it modifies are currently in use|app.*in use|close.*app|currently running|files?.*in use'
}

function Invoke-MicrosoftStoreClientUpdates {
    if (-not $script:CFG.MicrosoftStore.Enabled) { return @() }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $result = [ordered]@{
        Name      = 'Microsoft Store library updates'
        PackageId = 'Microsoft.Store.ClientUpdates'
        Source    = 'store-client'
        Provider  = 'microsoft-store-client'
        OldVer    = ''
        NewVer    = 'Latest available'
        Success   = $false
        Status    = 'Skipped'
        Reason    = ''
        IsKEV     = $false
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    $storeCli = Resolve-StoreCliPath
    $useStoreCli = $storeCli -and ($script:CFG.MicrosoftStore.Provider -in @('Auto', 'StoreCli'))
    $useCim = $script:CFG.MicrosoftStore.UseCimFallback -and ($script:CFG.MicrosoftStore.Provider -in @('Auto', 'Cim'))
    $captureDiff = $script:CFG.MicrosoftStore.CaptureAppxDiff
    $beforeSnapshot = $null

    if ($DryRun) {
        if ($useStoreCli) {
            $storeArgs = @('updates')
            $result.Status = 'Planned'
            $result.Reason = "Would run Store CLI: $storeCli $($storeArgs -join ' '). Would capture before/after AppX diff when not in dry-run."
            Write-Log "DRY RUN: Would update Microsoft Store library apps via Store CLI ($storeCli $($storeArgs -join ' '))." -Level INFO
        } elseif ($useCim -and (Test-StoreCimUpdateScanAvailable)) {
            $result.Status = 'Planned'
            $result.Reason = 'Would trigger Microsoft Store client update scan via Windows MDM bridge. Would capture before/after AppX diff when not in dry-run.'
            Write-Log 'DRY RUN: Would trigger Microsoft Store client update scan via Windows MDM bridge.' -Level INFO
        } else {
            $result.Status = 'Skipped'
            $result.Reason = 'Microsoft Store client update provider unavailable: Store CLI not found and MDM bridge scan method unavailable.'
            Write-Log "Microsoft Store client updates skipped: $($result.Reason)" -Level WARN
        }
        return @([PSCustomObject]$result)
    }

    if ($captureDiff) {
        $beforeSnapshot = Get-StoreAppxSnapshot
        Write-Log "Microsoft Store client: captured pre-update AppX snapshot ($($beforeSnapshot.Count) package(s))." -Level DEBUG
    }

    if ($useStoreCli) {
        $timeout = [Math]::Max(30, [int]$script:CFG.MicrosoftStore.TimeoutSeconds)
        Write-Log "Microsoft Store client: discovering Store CLI updates ($storeCli updates)." -Level INFO
        $candidates = @(Get-StoreCliUpdateCandidates -StoreCli $storeCli -TimeoutSeconds ([Math]::Min($timeout, 120)))
        $storeCliRows = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($script:StoreCliDiscoveryFailed) {
            $result.Status = 'Failed'
            $result.Reason = "Store CLI discovery failed: $($script:StoreCliDiscoveryReason)"
            Write-Log "Microsoft Store client update discovery failed: $($result.Reason)" -Level WARN
        } elseif ($candidates.Count -eq 0) {
            $result.Success = $true
            $result.Status = 'Completed'
            $result.Reason = 'Store CLI discovery completed; no Store updates were reported.'
        } else {
            $failedCandidates = [System.Collections.Generic.List[string]]::new()
            foreach ($candidate in $candidates) {
                $beforeCandidatePackage = Find-StoreSnapshotPackage -Snapshot $beforeSnapshot -Candidate $candidate
                $candidateOldVersion = if ($beforeCandidatePackage) { $beforeCandidatePackage.Version } else { '' }
                $candidatePackageId = if ($beforeCandidatePackage) { $beforeCandidatePackage.PackageFamilyName } else { $candidate.Name }
                $candidateReportedVersion = [string]$candidate.Version
                $candidateTargetVersion = $candidateReportedVersion
                $candidateVersionNote = " StoreCliVersion=$candidateReportedVersion;"
                if (-not [string]::IsNullOrWhiteSpace($candidateOldVersion) -and -not [string]::IsNullOrWhiteSpace($candidateReportedVersion)) {
                    $versionComparison = Compare-VersionText -Left $candidateReportedVersion -Right $candidateOldVersion
                    if ($null -ne $versionComparison -and $versionComparison -lt 0) {
                        $candidateTargetVersion = ''
                        $candidateVersionNote = " StoreCliVersion=$candidateReportedVersion; Store CLI listed version is lower than local AppX version $candidateOldVersion, so it is recorded as Store-reported metadata rather than a confirmed target version;"
                    }
                }
                $candidatePackageDetail = if ($beforeCandidatePackage) {
                    " AppXName=$($beforeCandidatePackage.Name); PackageFamilyName=$($beforeCandidatePackage.PackageFamilyName);"
                } else {
                    ' Pre-update AppX package match was not found; previous version unavailable.'
                }

                $candidateArgs = @('update', $candidate.Name, '--apply', 'true')
                Write-Log "Microsoft Store client: applying Store update '$($candidate.Name)' ($storeCli $($candidateArgs -join ' '))." -Level INFO
                $applyResult = Invoke-StoreCliCommand -StoreCli $storeCli -Arguments $candidateArgs -TimeoutSeconds $timeout
                $summary = (([string]$applyResult.Output -replace '\s+', ' ').Trim())
                if ($summary.Length -gt 700) { $summary = $summary.Substring(0, 700) + '...' }

                $candidateDeferred = $false
                $appInUse = Test-IsAppInUseUpdateFailure -Output $applyResult.Output
                if ($appInUse) {
                    Write-Log "Microsoft Store client: '$($candidate.Name)' appears blocked because the app is in use." -Level WARN
                    $choice = Show-AppInUsePrompt -AppName $candidate.Name -Evidence $summary
                    if ($choice -eq 'Primary') {
                        Write-Log "Microsoft Store client: retrying Store update '$($candidate.Name)' after user prompt." -Level INFO
                        $applyResult = Invoke-StoreCliCommand -StoreCli $storeCli -Arguments $candidateArgs -TimeoutSeconds $timeout
                        $summary = (([string]$applyResult.Output -replace '\s+', ' ').Trim())
                        if ($summary.Length -gt 700) { $summary = $summary.Substring(0, 700) + '...' }
                        $appInUse = Test-IsAppInUseUpdateFailure -Output $applyResult.Output
                    } elseif ($choice -in @('Secondary','Timeout')) {
                        $candidateDeferred = $true
                    }
                }

                $candidateCommandCompleted = $applyResult.ExitCode -eq 0 -and -not $applyResult.TimedOut -and -not $appInUse -and -not $candidateDeferred
                if ($candidateCommandCompleted) {
                    Write-Log "Microsoft Store client: Store update '$($candidate.Name)' command completed; verifying result." -Level SUCCESS
                } else {
                    $failedCandidates.Add("$($candidate.Name): $summary")
                    if ($candidateDeferred) {
                        Write-Log "Microsoft Store client: Store update '$($candidate.Name)' deferred by user." -Level WARN
                    } else {
                        Write-Log "Microsoft Store client: Store update '$($candidate.Name)' command failed or remained blocked. $summary" -Level WARN
                    }
                }

                $storeRow = [PSCustomObject]@{
                    Name      = $candidate.Name
                    PackageId = $candidatePackageId
                    Source    = 'store-client'
                    Provider  = 'microsoft-store-cli'
                    OldVer    = $candidateOldVersion
                    NewVer    = $candidateTargetVersion
                    Success   = $false
                    Status    = if ($candidateCommandCompleted) { 'Verifying' } elseif ($appInUse -or $candidateDeferred) { 'Blocked' } else { 'Failed' }
                    Reason    = if ($candidateCommandCompleted) {
                        "Store CLI apply command completed; final update state pending verification. Publisher=$($candidate.Publisher); StoreDate=$($candidate.Date);$candidateVersionNote$candidatePackageDetail Output: $summary"
                    } elseif ($appInUse -or $candidateDeferred) {
                        "Store update blocked or deferred because '$($candidate.Name)' appears to be open or locked. Publisher=$($candidate.Publisher); StoreDate=$($candidate.Date);$candidateVersionNote$candidatePackageDetail Output: $summary Remediation: close the app and rerun PatchManager."
                    } else {
                        "Store CLI failed applying discovered Store update. Publisher=$($candidate.Publisher); StoreDate=$($candidate.Date);$candidateVersionNote$candidatePackageDetail Output: $summary"
                    }
                    Remediation = if ($appInUse -or $candidateDeferred) { "Close $($candidate.Name), then rerun PatchManager or update it from Microsoft Store." } else { '' }
                    IsKEV     = $false
                    Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                }
                $storeCliRows.Add($storeRow)
                $results.Add($storeRow)
            }

            if ($failedCandidates.Count -eq 0) {
                $result.Success = $true
                $result.Status = 'Completed'
                $result.Reason = "Store CLI completed apply command(s) for $($candidates.Count) discovered update(s): $(($candidates | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', '). See per-app Store CLI rows for verified result."
            } else {
                $result.Status = 'Failed'
                $result.Reason = "Store CLI failed for $($failedCandidates.Count) of $($candidates.Count) discovered update(s): $($failedCandidates -join ' | ')"
                Write-Log "Microsoft Store client update command failed: $($result.Reason)" -Level WARN
            }
        }

        if ($result.Status -eq 'Failed') {
            $cliFailure = $result.Reason
            if ($useCim -and (Test-StoreCimUpdateScanAvailable)) {
                Write-Log 'Microsoft Store client: Store CLI failed; trying Windows MDM bridge fallback.' -Level WARN
                if (Invoke-StoreCimUpdateScan) {
                    $result.Success = $true
                    $result.Status = 'Completed'
                    $result.Reason = "Store CLI failed ($cliFailure). MDM bridge fallback triggered successfully. Store service applies applicable app updates asynchronously."
                    Write-Log 'Microsoft Store client update scan triggered successfully via fallback.' -Level SUCCESS
                } else {
                    $result.Reason = "Store CLI failed ($cliFailure). MDM bridge fallback also failed."
                    Write-Log $result.Reason -Level WARN
                }
            }
        }

        $results.Add([PSCustomObject]$result)
        if ($captureDiff -and $result.Status -in @('Completed', 'Succeeded')) {
            $settle = [Math]::Max(0, [int]$script:CFG.MicrosoftStore.PostUpdateSettleSeconds)
            if ($settle -gt 0) {
                Write-Log "Microsoft Store client: waiting ${settle}s before post-update AppX snapshot." -Level DEBUG
                Start-Sleep -Seconds $settle
            }
            $afterSnapshot = Get-StoreAppxSnapshot
            $diffRows = @(Compare-StoreAppxSnapshot -Before $beforeSnapshot -After $afterSnapshot)
            Write-Log "Microsoft Store client: AppX diff found $($diffRows.Count) changed/new package(s)." -Level INFO

            $remainingCandidates = @()
            if ($storeCliRows -and $storeCliRows.Count -gt 0) {
                Write-Log 'Microsoft Store client: verifying Store CLI update results with a follow-up Store update check.' -Level DEBUG
                $remainingCandidates = @(Get-StoreCliUpdateCandidates -StoreCli $storeCli -TimeoutSeconds ([Math]::Min($timeout, 120)))

                foreach ($storeRow in $storeCliRows) {
                    if ($storeRow.Status -eq 'Failed') { continue }

                    $matchingDiff = @($diffRows | Where-Object {
                        (ConvertTo-StoreMatchKey $_.Name) -eq (ConvertTo-StoreMatchKey $storeRow.Name) -or
                        (ConvertTo-StoreMatchKey $_.PackageId).Contains((ConvertTo-StoreMatchKey $storeRow.Name)) -or
                        (ConvertTo-StoreMatchKey $storeRow.PackageId).Contains((ConvertTo-StoreMatchKey $_.Name))
                    } | Select-Object -First 1)

                    $stillOffered = @($remainingCandidates | Where-Object {
                        (ConvertTo-StoreMatchKey $_.Name) -eq (ConvertTo-StoreMatchKey $storeRow.Name)
                    } | Select-Object -First 1)

                    if ($matchingDiff.Count -gt 0) {
                        $storeRow.Success = $true
                        $storeRow.Status = 'Succeeded'
                        if ([string]::IsNullOrWhiteSpace([string]$storeRow.OldVer)) { $storeRow.OldVer = $matchingDiff[0].OldVer }
                        $storeRow.NewVer = $matchingDiff[0].NewVer
                        $storeRow.Reason = "$($storeRow.Reason) Verified by AppX version change."
                    } elseif ($stillOffered.Count -eq 0) {
                        $storeRow.Success = $true
                        $storeRow.Status = 'Succeeded'
                        $storeRow.Reason = "$($storeRow.Reason) Verified because Store no longer lists this update after apply."
                    } else {
                        $storeRow.Success = $false
                        $storeRow.Status = 'Blocked'
                        $storeRow.Reason = "$($storeRow.Reason) Store still lists this update after apply; the app may have been in use, paused, or blocked by Store state."
                    }
                }
            }

            foreach ($row in $diffRows) {
                if ($storeCliRows -and @($storeCliRows | Where-Object {
                    (ConvertTo-StoreMatchKey $_.Name) -eq (ConvertTo-StoreMatchKey $row.Name) -or
                    (ConvertTo-StoreMatchKey $_.PackageId).Contains((ConvertTo-StoreMatchKey $row.Name))
                }).Count -gt 0) {
                    continue
                }
                $results.Add($row)
            }
        }
        return $results
    }

    if ($useCim -and (Test-StoreCimUpdateScanAvailable)) {
        Write-Log 'Microsoft Store client: triggering Store update scan via Windows MDM bridge.' -Level INFO
        if (Invoke-StoreCimUpdateScan) {
            $result.Success = $true
            $result.Status = 'Completed'
            $result.Reason = 'Triggered Microsoft Store client update scan. Store service applies applicable app updates asynchronously.'
            Write-Log 'Microsoft Store client update scan triggered successfully.' -Level SUCCESS
        } else {
            $result.Status = 'Failed'
            $result.Reason = 'Microsoft Store client update scan failed.'
            Write-Log $result.Reason -Level WARN
        }
        $results.Add([PSCustomObject]$result)
        if ($captureDiff -and $result.Status -in @('Completed', 'Succeeded')) {
            $settle = [Math]::Max(0, [int]$script:CFG.MicrosoftStore.PostUpdateSettleSeconds)
            if ($settle -gt 0) {
                Write-Log "Microsoft Store client: waiting ${settle}s before post-update AppX snapshot." -Level DEBUG
                Start-Sleep -Seconds $settle
            }
            $afterSnapshot = Get-StoreAppxSnapshot
            $diffRows = @(Compare-StoreAppxSnapshot -Before $beforeSnapshot -After $afterSnapshot)
            Write-Log "Microsoft Store client: AppX diff found $($diffRows.Count) changed/new package(s)." -Level INFO
            foreach ($row in $diffRows) {
                $results.Add($row)
            }
        }
        return $results
    }

    $result.Status = 'Skipped'
    $result.Reason = 'Microsoft Store client update provider unavailable: Store CLI not found and MDM bridge scan method unavailable.'
    Write-Log "Microsoft Store client updates skipped: $($result.Reason)" -Level WARN
    return @([PSCustomObject]$result)
}

#endregion

#region -- System Restore Point -------------------------------------------------------

function New-PatchRestorePoint {
    if (-not $script:CFG.SystemRestore.Enabled) { return }
    if ($DryRun) { Write-Log 'DRY RUN: Would create system restore point.' -Level INFO; return }

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -EA SilentlyContinue

        # Checkpoint-Computer emits a non-terminating WARNING (not an error) when a
        # restore point was already created within the last 1440 min. That's expected
        # behaviour, not a problem - suppress the warning stream so it doesn't alarm.
        Checkpoint-Computer -Description $script:CFG.SystemRestore.Description `
                            -RestorePointType MODIFY_SETTINGS `
                            -WarningAction SilentlyContinue -EA Stop
        Write-Log 'System restore point created.' -Level INFO
    } catch {
        # The 1440-minute throttle surfaces as an error in some Windows builds.
        # A recent restore point already exists, which is fine for our purposes.
        if ($_.Exception.Message -match '1440|already been created') {
            Write-Log 'Recent restore point already exists (within 24h). Skipping - existing point is sufficient.' -Level INFO
        } else {
            Write-Log "Restore point creation failed: $_. Proceeding anyway." -Level WARN
        }
    }
}

#endregion

#region -- Compliance Reporting -------------------------------------------------------

function New-ComplianceReport {
    param(
        [array]$Results,
        [array]$KEVMatches,
        [array]$SLABreaches,
        [object]$PatchState,
        [object]$Metrics
    )

    $rptDir = $script:CFG.Reporting.LocalReportPath
    if (-not (Test-Path $rptDir)) { New-Item -ItemType Directory -Path $rptDir -Force | Out-Null }

    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base    = "PatchReport_$($script:HOSTNAME)_$stamp"
    $elapsed = [Math]::Round(((Get-Date) - $script:STARTTIME).TotalMinutes, 2)
    $jsonPath = $null
    $htmlPath = $null
    $statusSummary = @($Results | Group-Object {
        if ($_.PSObject.Properties['Status'] -and $_.Status) { [string]$_.Status } else { 'Unknown' }
    } | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{ Status = $_.Name; Count = $_.Count }
    })
    $providerSummary = @($Results | Group-Object {
        if ($_.PSObject.Properties['Provider'] -and $_.Provider) { [string]$_.Provider }
        elseif ($_.PSObject.Properties['Source'] -and $_.Source) { [string]$_.Source }
        else { 'unknown' }
    } | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{ Provider = $_.Name; Count = $_.Count }
    })
    $sourceSummary = @($Results | Group-Object {
        if ($_.PSObject.Properties['Source'] -and $_.Source) { [string]$_.Source } else { 'unknown' }
    } | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{ Source = $_.Name; Count = $_.Count }
    })
    $attentionItems = @($Results | Where-Object {
        $status = if ($_.PSObject.Properties['Status']) { [string]$_.Status } else { '' }
        $status -in @('Failed', 'Blocked', 'Verifying') -or ($_.PSObject.Properties['Success'] -and -not [bool]$_.Success -and $status -ne 'Skipped')
    })
    $rebootItems = @($Results | Where-Object {
        $_.PSObject.Properties['RebootRequired'] -and [bool]$_.RebootRequired
    })

    if ($script:CFG.Reporting.GenerateJSON) {
        $jsonPath = Join-Path $rptDir "$base.json"
        [ordered]@{
            Metadata = [ordered]@{
                Hostname    = $script:HOSTNAME
                ScriptVer   = $script:VERSION
                RunStart    = $script:STARTTIME.ToString('yyyy-MM-dd HH:mm:ss')
                DurationMin = $elapsed
                Ring        = $script:RING
                DryRun      = $DryRun.IsPresent
                Emergency   = $script:EmergencyPatch
                ScopeProfile = $script:CFG.ScopeProfile
                SelfUpdate   = $script:SelfUpdateStatus
            }
            Statistics  = $script:Stats
            Metrics     = $Metrics
            StatusSummary = $statusSummary
            SourceSummary = $sourceSummary
            ProviderSummary = $providerSummary
            AttentionItems = $attentionItems
            RebootRequiredItems = $rebootItems
            Updates     = $Results
            KEVMatches  = $KEVMatches
            InventoryKEVMatches = @($script:InventoryKEVMatches)
            StalenessFindings = @($script:StalenessFindings)
            EndOfLifeFindings = @($script:EndOfLifeFindings)
            SLABreaches = $SLABreaches
        } | ConvertTo-Json -Depth 10 | Set-Content $jsonPath -Encoding UTF8
        Write-Log "JSON report: $jsonPath" -Level INFO
    }

    if ([bool](Get-ObjectPropertyValue $script:CFG.Reporting 'GenerateCSV' $true)) {
        $csvPath = Join-Path $rptDir "$base.csv"
        try {
            $Results |
                Select-Object Name, PackageId, Provider, Source, InstalledVersion, AvailableVersion,
                              ReportedVersion, ConfirmedVersion, Status, Success, RebootRequired,
                              IsKEV, Timestamp, Evidence, Remediation |
                Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            Write-Log "CSV report: $csvPath" -Level INFO
        } catch {
            Write-Log "CSV report generation failed: $_" -Level WARN
        }
        if (@($script:StalenessFindings).Count -gt 0) {
            try {
                $stalenessCsv = Join-Path $rptDir "$base.staleness.csv"
                @($script:StalenessFindings) |
                    Select-Object Category, Item, Severity, Detail, Recommendation, Timestamp |
                    Export-Csv -Path $stalenessCsv -NoTypeInformation -Encoding UTF8
                Write-Log "Staleness CSV: $stalenessCsv" -Level INFO
            } catch {
                Write-Log "Staleness CSV generation failed: $_" -Level WARN
            }
        }
        if (@($script:EndOfLifeFindings).Count -gt 0) {
            try {
                $eolCsv = Join-Path $rptDir "$base.endoflife.csv"
                @($script:EndOfLifeFindings) |
                    Select-Object Product, Item, InstalledVersion, Cycle, Status, EolDate,
                                  DaysRemaining, LatestSupported, Severity, Detail, Recommendation, Timestamp |
                    Export-Csv -Path $eolCsv -NoTypeInformation -Encoding UTF8
                Write-Log "End-of-life CSV: $eolCsv" -Level INFO
            } catch {
                Write-Log "End-of-life CSV generation failed: $_" -Level WARN
            }
        }
    }

    if ($script:CFG.Reporting.GenerateHTML) {
        $htmlPath = Join-Path $rptDir "$base.html"
        try {
            New-HTMLReport -Results $Results -KEVMatches $KEVMatches `
                           -SLABreaches $SLABreaches -Elapsed $elapsed -Metrics $Metrics `
                           -InventoryKEVMatches @($script:InventoryKEVMatches) `
                           -StalenessFindings @($script:StalenessFindings) `
                           -EndOfLifeFindings @($script:EndOfLifeFindings) |
                Set-Content $htmlPath -Encoding UTF8 -EA Stop
            Write-Log "HTML report: $htmlPath" -Level INFO
        } catch {
            Write-Log "HTML report generation failed: $_" -Level ERROR
        }
    }

    $central = $script:CFG.Reporting.CentralReportPath
    if (-not [string]::IsNullOrWhiteSpace($central)) {
        $dest = Join-Path $central $script:HOSTNAME
        try {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Get-ChildItem (Join-Path $rptDir "$base*") | Copy-Item -Destination $dest -Force -EA Stop
            Write-Log "Reports copied to central store: $dest" -Level INFO
        } catch {
            Write-Log "Failed to copy reports to central store: $_" -Level WARN
        }
    }

    return [PSCustomObject]@{
        BaseName  = $base
        JsonPath  = $jsonPath
        HtmlPath  = $htmlPath
        ReportDir = $rptDir
    }
}


function New-HTMLReport {
    param([array]$Results, [array]$KEVMatches, [array]$SLABreaches, [double]$Elapsed, [object]$Metrics, [array]$InventoryKEVMatches = @(), [array]$StalenessFindings = @(), [array]$EndOfLifeFindings = @())

    function ConvertTo-ReportHtml {
        param($Value)
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    function Get-ReportProperty {
        param($Object, [string]$Name, $Default = '')
        if ($null -eq $Object) { return $Default }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $Default
    }

    function Get-ReportStat {
        param([string]$Name, $Default = 0)
        if ($script:Stats.Contains($Name)) { return $script:Stats[$Name] }
        return $Default
    }

    $plannedCount   = Get-ReportStat 'UpdatesPlanned' 0
    $appliedCount   = Get-ReportStat 'UpdatesApplied' 0
    $failCount      = Get-ReportStat 'UpdatesFailed' 0
    $inventoryCount = Get-ReportStat 'InventoryCount' 0
    $kevCount       = Get-ReportStat 'KEVMatches' 0
    $errorCount     = $script:Stats.Errors.Count
    $slaCount       = $SLABreaches.Count
    $avgDays        = ConvertTo-ReportHtml $Metrics.AvgDaysToApply
    $hostname       = ConvertTo-ReportHtml $script:HOSTNAME
    $ring           = ConvertTo-ReportHtml $script:RING
    $startStr       = ConvertTo-ReportHtml $script:STARTTIME.ToString('dd MMM yyyy HH:mm')
    $ver            = ConvertTo-ReportHtml $script:VERSION
    $isDryRun       = $DryRun.IsPresent
    $isEmergency    = $script:EmergencyPatch
    $elapsed2dp     = [Math]::Round($Elapsed, 1)
    $generatedAt    = ConvertTo-ReportHtml (Get-Date -Format 'dd MMM yyyy HH:mm:ss')
    $runMode        = if ($isDryRun) { 'Dry run' } else { 'Live run' }
    $primaryCount   = if ($isDryRun) { $plannedCount } else { $appliedCount }
    $primaryLabel   = if ($isDryRun) { 'Updates planned' } else { 'Updates applied' }
    $statusGroups = @($Results | Group-Object {
        $status = Get-ReportProperty $_ 'Status' ''
        if ([string]::IsNullOrWhiteSpace([string]$status)) { 'Unknown' } else { [string]$status }
    } | Sort-Object Name)
    $sourceGroups = @($Results | Group-Object {
        $source = Get-ReportProperty $_ 'Source' 'unknown'
        if ([string]::IsNullOrWhiteSpace([string]$source)) { 'unknown' } else { [string]$source }
    } | Sort-Object Name)
    $providerGroups = @($Results | Group-Object {
        $provider = Get-ReportProperty $_ 'Provider' (Get-ReportProperty $_ 'Source' 'unknown')
        if ([string]::IsNullOrWhiteSpace([string]$provider)) { 'unknown' } else { [string]$provider }
    } | Sort-Object Name)
    $blockedCount = @($Results | Where-Object { (Get-ReportProperty $_ 'Status' '') -eq 'Blocked' }).Count
    $verifyingCount = @($Results | Where-Object { (Get-ReportProperty $_ 'Status' '') -eq 'Verifying' }).Count
    $failedRowCount = @($Results | Where-Object { (Get-ReportProperty $_ 'Status' '') -eq 'Failed' }).Count
    $rebootCount = @($Results | Where-Object { [bool](Get-ReportProperty $_ 'RebootRequired' $false) }).Count
    $attentionCount = $blockedCount + $verifyingCount + $failedRowCount + $errorCount
    $attentionTone = if ($attentionCount -gt 0) { 'danger' } else { 'good' }

    $slaOk      = $slaCount -eq 0
    $slaTone    = if ($slaOk) { 'good' } else { 'danger' }
    $kevTone    = if ($kevCount -gt 0) { 'danger' } else { 'good' }
    $failTone   = if ($failCount -gt 0) { 'danger' } else { 'good' }
    $blockedTone = if ($blockedCount -gt 0) { 'danger' } else { 'good' }
    $verifyingTone = if ($verifyingCount -gt 0) { 'danger' } else { 'good' }
    $rebootTone = if ($rebootCount -gt 0) { 'danger' } else { 'good' }
    $errorTone  = if ($errorCount -gt 0) { 'danger' } else { 'good' }
    $runTone    = if ($isEmergency -or $kevCount -gt 0 -or $slaCount -gt 0 -or $failCount -gt 0 -or $errorCount -gt 0) { 'attention' } else { 'clean' }
    $runSummary = if ($attentionCount -gt 0) { "$attentionCount item(s) need review before closing this run." } elseif ($runTone -eq 'clean') { 'No actionable KEV, SLA, failure, or script error conditions were recorded.' } else { 'Review the highlighted sections below before closing this run.' }
    $verdictTitle = if ($runTone -eq 'clean') { 'Patch state holds.' } elseif ($isEmergency -or $kevCount -gt 0) { 'Exposure needs action.' } else { 'Review before close.' }
    $verdictCopy  = if ($runTone -eq 'clean') { 'The run completed with no actionable KEV, SLA, failure, or script-error signals. Provider evidence remains below for audit review.' } elseif ($isEmergency -or $kevCount -gt 0) { 'Security signals are present. Prioritise KEV and failed rows before treating this device as current.' } else { 'The report found items that need operator review. Follow the evidence trail, then use the table filters to isolate each row.' }

    # The KEV catalogue names products, never versions. Say so in the report, once.
    $kevMethodNote = "A KEV entry names an affected product, not an affected version - the catalogue carries no version data. Each candidate below is resolved against NVD's CPE version ranges: <strong>Affected</strong> means the installed version falls inside the vulnerable range, <strong>Not affected</strong> means it is past the fix, and <strong>Unknown</strong> means NVD had no comparable range and the version needs a manual check."

    function New-KEVRowsHtml {
        param([array]$Candidates)
        return (($Candidates | Sort-Object @{ Expression = {
            switch ([string](Get-ReportProperty $_ 'ExposureState' 'Unknown')) {
                'Affected'    { 0 }
                'Unknown'     { 1 }
                default       { 2 }
            } } }, CVE | ForEach-Object {
            $state = [string](Get-ReportProperty $_ 'ExposureState' 'Unknown')
            $fixed = [string](Get-ReportProperty $_ 'FixedVersion' '')
            $why   = [string](Get-ReportProperty $_ 'ExposureDetail' '')
            $badge = switch ($state) {
                'Affected'    { "<span class='status failed'>Affected</span>" }
                'NotAffected' { "<span class='status ok'>Not affected</span>" }
                default       { "<span class='status skipped'>Unknown</span>" }
            }
            $rowCls = if ($state -eq 'Affected') { 'breach' } else { '' }
            "<tr class='$rowCls'><td class='mono'>$(ConvertTo-ReportHtml $_.CVE)</td><td>$(ConvertTo-ReportHtml $_.InstalledApp)</td><td class='mono'>$(ConvertTo-ReportHtml $_.InstalledVer)</td><td>$badge</td><td class='mono'>$(ConvertTo-ReportHtml $(if ($fixed) { $fixed } else { '-' }))</td><td>$(ConvertTo-ReportHtml $_.Description)<div class='details'>$(ConvertTo-ReportHtml $why)</div></td><td class='nowrap'>$(ConvertTo-ReportHtml $_.CISADueDate)</td></tr>"
        }) -join "`n")
    }

    function Get-ReportRowKind {
        param($Row)
        $status = [string](Get-ReportProperty $Row 'Status' '')
        $rebootRequired = [bool](Get-ReportProperty $Row 'RebootRequired' $false)
        $isKev = [bool](Get-ReportProperty $Row 'IsKEV' $false)
        if ($status -in @('Failed', 'Blocked', 'Verifying') -or $rebootRequired -or $isKev) { return 'attention' }
        if ($status -eq 'Planned') { return 'action' }
        if ($status -in @('Succeeded', 'Updated', 'Detected')) { return 'updated' }
        if ($status -in @('Skipped', 'Descoped')) { return 'skipped' }
        return 'provider'
    }

    function New-ReportRowsHtml {
        param([array]$Rows)
        if ($Rows.Count -eq 0) { return '' }
        return (($Rows | ForEach-Object {
            $success = [bool](Get-ReportProperty $_ 'Success' $false)
            $isKev = [bool](Get-ReportProperty $_ 'IsKEV' $false)
            $name = Get-ReportProperty $_ 'Name' ''
            $packageId = Get-ReportProperty $_ 'PackageId' ''
            $installedVer = Get-ReportProperty $_ 'InstalledVersion' (Get-ReportProperty $_ 'OldVer' '')
            $availableVer = Get-ReportProperty $_ 'AvailableVersion' (Get-ReportProperty $_ 'NewVer' '')
            $reportedVer = Get-ReportProperty $_ 'ReportedVersion' ''
            $confirmedVer = Get-ReportProperty $_ 'ConfirmedVersion' ''
            $targetText = if ($availableVer -and $reportedVer -and $availableVer -ne $reportedVer) { "$availableVer / reported $reportedVer" } elseif ($availableVer) { $availableVer } else { $reportedVer }
            $rebootRequired = [bool](Get-ReportProperty $_ 'RebootRequired' $false)
            $timestamp = Get-ReportProperty $_ 'Timestamp' ''
            $status = Get-ReportProperty $_ 'Status' ''
            if ([string]::IsNullOrWhiteSpace([string]$status)) {
                $status = if ($success) { 'Succeeded' } else { 'Failed' }
            }
            $engineSource = Get-ReportProperty $_ 'Source' 'winget'
            $provider = Get-ReportProperty $_ 'Provider' $engineSource
            $rowClass = switch -Regex ($status) {
                '^Planned$'   { 'planned'; break }
                '^Succeeded$' { 'ok'; break }
                '^Completed$' { 'ok'; break }
                '^Updated$'   { 'ok'; break }
                '^Detected$'  { 'ok'; break }
                '^AlreadyCurrent$' { 'ok'; break }
                '^(Skipped|Descoped)$' { 'skipped'; break }
                '^Blocked$'   { 'fail'; break }
                '^Verifying$' { 'planned'; break }
                default       { if ($success) { 'ok' } else { 'fail' } }
            }
            $kev = if ($isKev) { '<span class="flag danger">KEV</span>' } else { '' }
            $evidence = Get-ReportProperty $_ 'Evidence' (Get-ReportProperty $_ 'Reason' '')
            $remediation = Get-ReportProperty $_ 'Remediation' ''
            $details = (($evidence, $remediation | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ')
            if ([string]::IsNullOrWhiteSpace([string]$details)) { $details = '-' }
            $rebootText = if ($rebootRequired) { 'Yes' } else { 'No' }
            $search = ConvertTo-ReportHtml "$name $packageId $engineSource $provider $status $details $installedVer $targetText $confirmedVer $rebootText"
            "<tr class='data-row $rowClass' data-status='$(ConvertTo-ReportHtml $status)' data-source='$(ConvertTo-ReportHtml $engineSource)' data-provider='$(ConvertTo-ReportHtml $provider)' data-search='$search'><td><strong>$(ConvertTo-ReportHtml $name)</strong>$kev</td><td class='mono'>$(ConvertTo-ReportHtml $packageId)</td><td><span class='source-pill'>$(ConvertTo-ReportHtml $engineSource)</span></td><td><span class='source-pill'>$(ConvertTo-ReportHtml $provider)</span></td><td class='mono'>$(ConvertTo-ReportHtml $installedVer)</td><td class='mono'>$(ConvertTo-ReportHtml $targetText)</td><td class='mono'>$(ConvertTo-ReportHtml $confirmedVer)</td><td><span class='status $rowClass'>$(ConvertTo-ReportHtml $status)</span></td><td>$(ConvertTo-ReportHtml $rebootText)</td><td class='nowrap'>$(ConvertTo-ReportHtml $timestamp)</td><td class='details'><details><summary>Evidence</summary><div>$(ConvertTo-ReportHtml $details)</div></details></td></tr>"
        }) -join "`n")
    }

    $actionableRows = @($Results | Where-Object { (Get-ReportRowKind $_) -in @('attention', 'action', 'updated') })
    $providerCheckRows = @($Results | Where-Object { (Get-ReportRowKind $_) -eq 'provider' })
    $skippedRows = @($Results | Where-Object { (Get-ReportRowKind $_) -eq 'skipped' })
    $actionableUpdateRows = New-ReportRowsHtml -Rows $actionableRows
    $providerCheckTableRows = New-ReportRowsHtml -Rows $providerCheckRows
    $skippedTableRows = New-ReportRowsHtml -Rows $skippedRows
    $providerCheckCount = $providerCheckRows.Count
    $visibleSkippedCount = $skippedRows.Count

    $kevRows = New-KEVRowsHtml -Candidates $KEVMatches

    $slaRows = ($SLABreaches | ForEach-Object {
        "<tr class='breach'><td>$(ConvertTo-ReportHtml $_.PackageName)</td><td class='mono'>$(ConvertTo-ReportHtml $_.PackageId)</td><td class='mono'>$(ConvertTo-ReportHtml $_.VersionAvailable)</td><td class='nowrap'>$(ConvertTo-ReportHtml $_.FirstSeenAvailable)</td><td class='nowrap'>$(ConvertTo-ReportHtml $_.SLADue)</td><td>$(ConvertTo-ReportHtml $_.Ring)</td></tr>"
    }) -join "`n"

    $errorItems = ($script:Stats.Errors | ForEach-Object {
        "<li>$(ConvertTo-ReportHtml $_)</li>"
    }) -join "`n"

    $statusRows = ($statusGroups | ForEach-Object {
        $statusName = [string]$_.Name
        $tone = switch -Regex ($statusName) {
            '^(Succeeded|Completed|Updated|Detected|AlreadyCurrent)$' { 'ok'; break }
            '^Planned$' { 'planned'; break }
            '^(Skipped|Descoped|Verifying)$' { 'skipped'; break }
            '^(Blocked|Failed)$' { 'fail'; break }
            default { 'skipped' }
        }
        "<tr class='$tone'><td><span class='status $tone'>$(ConvertTo-ReportHtml $statusName)</span></td><td class='mono'>$(ConvertTo-ReportHtml $_.Count)</td></tr>"
    }) -join "`n"

    $providerRows = ($providerGroups | ForEach-Object {
        "<tr><td><span class='source-pill'>$(ConvertTo-ReportHtml $_.Name)</span></td><td class='mono'>$(ConvertTo-ReportHtml $_.Count)</td></tr>"
    }) -join "`n"

    $sourceRows = ($sourceGroups | ForEach-Object {
        "<tr><td><span class='source-pill'>$(ConvertTo-ReportHtml $_.Name)</span></td><td class='mono'>$(ConvertTo-ReportHtml $_.Count)</td></tr>"
    }) -join "`n"

    $attentionSection = if ($attentionCount -gt 0) {
        "<section class='panel danger-panel'><div class='section-head'><div><p class='eyebrow'>Attention</p><h2>$attentionCount item(s) need review</h2></div><span class='count danger'>$attentionCount</span></div><p class='note danger-text'>Blocked, failed, verifying, reboot-required, KEV, or script-error states require follow-up. The actionable updates section below shows the package rows that matter first.</p></section>"
    } else {
        "<section class='panel'><div class='section-head'><div><p class='eyebrow'>Attention</p><h2>No review items</h2></div><span class='count good'>0</span></div><p class='note'>No blocked, failed, verifying, or script-error states were recorded.</p></section>"
    }

    $breakdownSection = "<div class='breakdown-grid'><section class='panel'><div class='section-head'><div><p class='eyebrow'>Result breakdown</p><h2>Status counts</h2></div><span class='count'>$(ConvertTo-ReportHtml $Results.Count)</span></div><div class='table-wrap compact'><table><thead><tr><th>Status</th><th>Rows</th></tr></thead><tbody>$statusRows</tbody></table></div></section><section class='panel'><div class='section-head'><div><p class='eyebrow'>Source breakdown</p><h2>Source counts</h2></div><span class='count'>$(ConvertTo-ReportHtml $sourceGroups.Count)</span></div><div class='table-wrap compact'><table><thead><tr><th>Source</th><th>Rows</th></tr></thead><tbody>$sourceRows</tbody></table></div></section><section class='panel'><div class='section-head'><div><p class='eyebrow'>Provider breakdown</p><h2>Provider counts</h2></div><span class='count'>$(ConvertTo-ReportHtml $providerGroups.Count)</span></div><div class='table-wrap compact'><table><thead><tr><th>Provider</th><th>Rows</th></tr></thead><tbody>$providerRows</tbody></table></div></section></div>"

    $interactiveTableHeader = "<thead><tr><th data-sort='text'>Package</th><th data-sort='text'>Package ID</th><th data-sort='text'>Source</th><th data-sort='text'>Provider</th><th data-sort='text'>Installed</th><th data-sort='text'>Available / reported</th><th data-sort='text'>Confirmed</th><th data-sort='text'>Result</th><th data-sort='text'>Reboot</th><th data-sort='text'>Time</th><th data-sort='text'>Details</th></tr></thead>"
    $plainTableHeader = "<thead><tr><th>Package</th><th>Package ID</th><th>Source</th><th>Provider</th><th>Installed</th><th>Available / reported</th><th>Confirmed</th><th>Result</th><th>Reboot</th><th>Time</th><th>Details</th></tr></thead>"

    $tableSection = if ($actionableRows.Count -gt 0) {
        "<div class='table-wrap'><table id='updatesTable'>$interactiveTableHeader<tbody>$actionableUpdateRows</tbody></table></div>"
    } else {
        '<div class="empty-state"><div class="empty-title">No package updates required action.</div><p>Source/provider checks, already-current items, and intentional skips are listed separately below so this section stays focused on actual update work.</p></div>'
    }

    $providerCheckSection = if ($providerCheckRows.Count -gt 0) {
        "<section class='panel secondary-panel'><div class='section-head'><div><p class='eyebrow'>Source and provider checks</p><h2>$providerCheckCount audit check row(s)</h2></div><span class='count'>$providerCheckCount</span></div><p class='note'>These rows prove each source or provider was checked. They are evidence of discovery/health, not package updates.</p><div class='table-wrap'><table>$plainTableHeader<tbody>$providerCheckTableRows</tbody></table></div></section>"
    } else {
        "<section class='panel secondary-panel'><div class='section-head'><div><p class='eyebrow'>Source and provider checks</p><h2>No audit check rows</h2></div><span class='count'>0</span></div><p class='note'>Every provider row in this run required action or follow-up.</p></section>"
    }

    $skippedSection = if ($skippedRows.Count -gt 0) {
        "<section class='panel secondary-panel'><div class='section-head'><div><p class='eyebrow'>Skipped and descoped</p><h2>$visibleSkippedCount row(s)</h2></div><span class='count'>$visibleSkippedCount</span></div><p class='note'>These items were intentionally not patched by PatchManager in this run. The evidence column records why.</p><div class='table-wrap'><table>$plainTableHeader<tbody>$skippedTableRows</tbody></table></div></section>"
    } else {
        "<section class='panel secondary-panel'><div class='section-head'><div><p class='eyebrow'>Skipped and descoped</p><h2>No skipped rows</h2></div><span class='count good'>0</span></div><p class='note'>No provider returned a skipped or descoped result.</p></section>"
    }

    $invKevRows      = New-KEVRowsHtml -Candidates $InventoryKEVMatches
    $invKevAffected  = @($InventoryKEVMatches | Where-Object { $_.ExposureState -eq 'Affected' }).Count
    $invKevUnknown   = @($InventoryKEVMatches | Where-Object { $_.ExposureState -eq 'Unknown' }).Count

    $invKevSection = if ($InventoryKEVMatches.Count -gt 0) {
        $tone      = if ($invKevAffected -gt 0) { 'danger-panel' } else { '' }
        $countTone = if ($invKevAffected -gt 0) { 'danger' } elseif ($invKevUnknown -gt 0) { '' } else { 'good' }
        $noteClass = if ($invKevAffected -gt 0) { 'note danger-text' } else { 'note' }
        $heading   = if ($invKevAffected -gt 0) { "$invKevAffected confirmed exposure(s) with no available update" } else { 'KEV product history, no confirmed exposure' }
        "<section class='panel $tone'><div class='section-head'><div><p class='eyebrow'>CISA KEV - installed software</p><h2>$heading</h2></div><span class='count $countTone'>$invKevAffected</span></div><p class='$noteClass'>$($InventoryKEVMatches.Count) installed application(s) match a product named in the CISA KEV catalogue, and no update was available through PatchManager's sources in this run. $kevMethodNote</p><div class='table-wrap'><table><thead><tr><th>CVE</th><th>Installed app</th><th>Version</th><th>Exposure</th><th>Fixed in</th><th>Vulnerability</th><th>CISA due</th></tr></thead><tbody>$invKevRows</tbody></table></div></section>"
    } else {
        "<section class='panel'><div class='section-head'><div><p class='eyebrow'>CISA KEV - installed software</p><h2>No inventory KEV matches</h2></div><span class='count good'>0</span></div><p class='note'>The full software inventory was scanned against the KEV catalogue; nothing matched beyond the actionable items above.</p></section>"
    }

    $stalenessReview = @($StalenessFindings | Where-Object { $_.Severity -eq 'review' })
    $stalenessRows = ($StalenessFindings | ForEach-Object {
        $sev = if ($_.Severity -eq 'review') { "<span class='status skipped'>Review</span>" } else { "<span class='status ok'>OK</span>" }
        $detail = (($_.Detail, $_.Recommendation | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ')
        "<tr><td>$(ConvertTo-ReportHtml $_.Category)</td><td><strong>$(ConvertTo-ReportHtml $_.Item)</strong></td><td>$sev</td><td class='details'>$(ConvertTo-ReportHtml $detail)</td></tr>"
    }) -join "`n"
    $stalenessSection = if ($StalenessFindings.Count -gt 0) {
        $tone = if ($stalenessReview.Count -gt 0) { 'danger-panel' } else { '' }
        $countTone = if ($stalenessReview.Count -gt 0) { 'danger' } else { 'good' }
        "<section class='panel $tone'><div class='section-head'><div><p class='eyebrow'>Environment staleness</p><h2>Report-only exposure checks</h2></div><span class='count $countTone'>$($stalenessReview.Count)</span></div><p class='note'>These checks never change the machine and are not counted as updates. $($stalenessReview.Count) of $($StalenessFindings.Count) finding(s) need review (antivirus definitions, Windows feature version, developer runtimes).</p><div class='table-wrap'><table><thead><tr><th>Category</th><th>Item</th><th>State</th><th>Detail</th></tr></thead><tbody>$stalenessRows</tbody></table></div></section>"
    } else { '' }

    $eolReview = @($EndOfLifeFindings | Where-Object { $_.Severity -eq 'review' })
    $eolRows = ($EndOfLifeFindings | ForEach-Object {
        $statusHtml = switch ($_.Status) {
            'EOL'         { "<span class='status failed'>End of life</span>" }
            'NearEOL'     { "<span class='status skipped'>Near EOL</span>" }
            'PatchBehind' { "<span class='status skipped'>Behind latest</span>" }
            'Supported'   { "<span class='status ok'>Supported</span>" }
            default       { "<span class='status'>Unknown</span>" }
        }
        $detail = (($_.Detail, $_.Recommendation | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ')
        "<tr><td>$(ConvertTo-ReportHtml $_.Item)</td><td class='mono'>$(ConvertTo-ReportHtml $_.InstalledVersion)</td><td class='mono'>$(ConvertTo-ReportHtml $_.Cycle)</td><td>$statusHtml</td><td class='nowrap'>$(ConvertTo-ReportHtml $_.EolDate)</td><td class='mono'>$(ConvertTo-ReportHtml $_.LatestSupported)</td><td class='details'>$(ConvertTo-ReportHtml $detail)</td></tr>"
    }) -join "`n"
    $eolSection = if ($EndOfLifeFindings.Count -gt 0) {
        $tone = if ($eolReview.Count -gt 0) { 'danger-panel' } else { '' }
        $countTone = if ($eolReview.Count -gt 0) { 'danger' } else { 'good' }
        "<section class='panel $tone'><div class='section-head'><div><p class='eyebrow'>End-of-life</p><h2>Support-lifecycle exposure</h2></div><span class='count $countTone'>$($eolReview.Count)</span></div><p class='note'>Authoritative end-of-support data from endoflife.date. Report-only - out-of-support software is fully patchable yet no longer receives fixes, so plan a major-version upgrade. <strong>Behind latest</strong> means the release line is still supported but the installed build is behind its newest patch release. $($eolReview.Count) of $($EndOfLifeFindings.Count) finding(s) need review.</p><div class='table-wrap'><table><thead><tr><th>Item</th><th>Installed</th><th>Cycle</th><th>Status</th><th>EOL date</th><th>Latest supported</th><th>Detail</th></tr></thead><tbody>$eolRows</tbody></table></div></section>"
    } else { '' }

    $kevSection = if ($KEVMatches.Count -gt 0) {
        $tone      = if ($kevCount -gt 0) { 'danger-panel' } else { '' }
        $countTone = if ($kevCount -gt 0) { 'danger' } else { 'good' }
        $noteClass = if ($kevCount -gt 0) { 'note danger-text' } else { 'note' }
        $heading   = if ($kevCount -gt 0) { "$kevCount confirmed KEV exposure(s)" } else { 'KEV product history, no confirmed exposure' }
        "<section class='panel $tone'><div class='section-head'><div><p class='eyebrow'>CISA KEV</p><h2>$heading</h2></div><span class='count $countTone'>$kevCount</span></div><p class='$noteClass'>$($KEVMatches.Count) upgrade candidate(s) match a product named in the CISA KEV catalogue. $kevMethodNote$(if ($kevCount -gt 0) { ' Confirmed exposures bypassed the maintenance window and were patched first.' } else { ' No confirmed exposure, so no maintenance-window bypass was triggered.' })</p><div class='table-wrap'><table><thead><tr><th>CVE</th><th>Package</th><th>Version</th><th>Exposure</th><th>Fixed in</th><th>Vulnerability</th><th>CISA due</th></tr></thead><tbody>$kevRows</tbody></table></div></section>"
    } else {
        "<section class='panel'><div class='section-head'><div><p class='eyebrow'>CISA KEV</p><h2>No actionable KEV matches</h2></div><span class='count good'>0</span></div><p class='note'>KEV matching ran only against packages PatchManager can action from upgrade discovery.</p></section>"
    }

    $slaSection = if ($SLABreaches.Count -gt 0) {
        "<section class='panel danger-panel'><div class='section-head'><div><p class='eyebrow'>SLA</p><h2>Updates past deadline</h2></div><span class='count danger'>$slaCount</span></div><p class='note danger-text'>These updates have exceeded the configured $($script:CFG.SLA.Critical)-day application window.</p><div class='table-wrap'><table><thead><tr><th>Package</th><th>Package ID</th><th>Available</th><th>First seen</th><th>SLA due</th><th>Ring</th></tr></thead><tbody>$slaRows</tbody></table></div></section>"
    } else {
        "<section class='panel'><div class='section-head'><div><p class='eyebrow'>SLA</p><h2>No SLA breaches</h2></div><span class='count good'>0</span></div><p class='note'>No tracked update has exceeded the configured application window.</p></section>"
    }

    $errSection = if ($errorCount -gt 0) {
        "<section class='panel danger-panel'><div class='section-head'><div><p class='eyebrow'>Runtime</p><h2>Script errors</h2></div><span class='count danger'>$errorCount</span></div><ul class='error-list'>$errorItems</ul></section>"
    } else {
        "<section class='panel'><div class='section-head'><div><p class='eyebrow'>Runtime</p><h2>No script errors</h2></div><span class='count good'>0</span></div><p class='note'>The run completed without logging script-level errors.</p></section>"
    }

    $emergencyBanner = if ($isEmergency) {
        "<div class='callout danger-callout'><strong>Emergency patch run.</strong><span>$kevCount installed version(s) were confirmed against NVD to fall inside a CISA KEV vulnerable range, triggering a maintenance-window bypass.</span></div>"
    } else { '' }

    $kevCandidateCount = $KEVMatches.Count + $InventoryKEVMatches.Count
    $kevBentoNote = if ($kevCount -gt 0) {
        "$kevCount of $kevCandidateCount KEV candidate(s) confirmed affected by installed version. $slaCount SLA breach(es) recorded."
    } elseif ($kevCandidateCount -gt 0) {
        "$kevCandidateCount KEV product match(es), none confirmed affected by installed version. $slaCount SLA breach(es) recorded."
    } else {
        "No KEV product matches. $slaCount SLA breach(es) recorded."
    }

    $bentoSection = @"
  <section class="bento-board reveal" id="summary" aria-label="Run summary">
    <article class="bento-card bento-primary good"><span class="bento-kicker">$primaryLabel</span><strong>$primaryCount</strong><p>$verdictCopy</p></article>
    <article class="bento-card bento-review $attentionTone"><span class="bento-kicker">Needs review</span><strong>$attentionCount</strong><p>Blocked, failed, verifying, and script-error signals to follow up. See the actions below.</p></article>
    <article class="bento-card bento-security $kevTone"><span class="bento-kicker">Security</span><strong>$kevCount KEV</strong><p>$kevBentoNote KEV and SLA exposure is detailed in the security section.</p></article>
    <article class="bento-card bento-reboot $rebootTone"><span class="bento-kicker">Reboot required</span><strong>$rebootCount</strong><p>Update(s) needing a restart to finish - PatchManager never reboots on its own.</p></article>
  </section>
"@

    $evidenceRail = @"
    <aside class="evidence-rail" aria-label="Report navigation">
      <p class="rail-kicker">On this page</p>
      <nav class="rail-links" aria-label="Report sections">
        <a href="#updates">Actionable updates</a>
        <a href="#security">Security &amp; lifecycle</a>
        <a href="#auditDetail">Audit detail</a>
      </nav>
      <p class="scrub-copy"><span>Start with the actions above.</span> <span>Security, staleness, and end-of-life follow.</span> <span>Full provider evidence and counts are under Audit detail.</span></p>
    </aside>
"@

    $brandMark = @'
<svg class="brand-mark" viewBox="0 0 64 64" aria-hidden="true" focusable="false"><rect width="64" height="64" rx="14" fill="#f6f2e8"/><path d="M32 7 53 15v15c0 13.5-8.5 22-21 28C19.5 52 11 43.5 11 30V15L32 7Z" fill="#111513"/><path d="M32 12.5 47 18v12c0 9.5-5.5 16.5-15 21.5C22.5 46.5 17 39.5 17 30V18l15-5.5Z" fill="#f6f2e8"/><path d="M24.5 18h11.5l6.5 6.5V42h-18V18Z" fill="#fff" stroke="#18324a" stroke-width="2" stroke-linejoin="round"/><path d="M36 18v7h6.5" fill="none" stroke="#18324a" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M24 34 29.5 39.5 41 27.5" fill="none" stroke="#24744f" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 46.5c3.5 4 8 7 13 9.5 5-2.5 9.5-5.5 13-9.5" fill="none" stroke="#c49a3d" stroke-width="2" stroke-linecap="round"/></svg>
'@

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="PatchManager compliance report for $hostname">
<title>PatchManager report - $hostname</title>
<style>
  /* PatchManager evidence ledger - charcoal command band over ivory paper.
     Content is NEVER visibility-gated: no scroll reveals, no opacity scrubs.
     A compliance artifact must capture, print, and read completely, always. */
  :root{--charcoal:#111513;--charcoal-2:#1a201c;--paper:#f6f2e8;--paper-soft:#efe8d9;--card:#fcfaf3;--ink:#111513;--muted:#5f6a62;--line:#ddd5c2;--line-strong:#c8bfa6;--blue:#18324a;--blue-soft:#e8edf2;--green:#24744f;--green-bg:#e9f2ea;--red:#a53b35;--red-bg:#f7e6e1;--amber:#9b6324;--amber-curve:#c49a3d;--amber-bg:#faf0d8;--steel:#365f72;--steel-bg:#e6eef1;--card-shadow:0 1px 2px rgba(17,21,19,.05),0 10px 32px rgba(17,21,19,.07)}
  *{box-sizing:border-box}
  html{scroll-behavior:smooth;background:var(--paper)}
  body{margin:0;overflow-x:hidden;background:var(--paper);color:var(--ink);font:14px/1.55 "Segoe UI Variable Text","Aptos","Segoe UI",system-ui,-apple-system,sans-serif;font-variant-numeric:tabular-nums}
  .skip-link{position:absolute;left:-999px;top:8px;background:#fff;color:#000;padding:8px 10px;border-radius:6px;z-index:20}.skip-link:focus{left:8px}
  .brand-lockup{display:inline-flex;align-items:center;gap:10px}.brand-mark{width:30px;height:30px;flex:0 0 auto}.brand-word{font-weight:820}.hero-brand{margin-bottom:16px;color:#f6f2e8;font-weight:760}.hero-brand .brand-mark{width:34px;height:34px}.footer-brand .brand-mark{width:24px;height:24px}
  .report-nav{position:sticky;top:0;z-index:12;display:grid;grid-template-columns:auto minmax(260px,1fr);gap:18px;align-items:start;padding:12px 32px;background:rgba(17,21,19,.96);backdrop-filter:blur(14px);border-bottom:1px solid rgba(246,242,232,.12);color:#fff}.nav-inner{display:contents}.nav-brand{font-weight:820}.nav-links{display:flex;gap:8px;flex-wrap:wrap}.nav-links a{color:#cfd8d1;text-decoration:none;border:1px solid rgba(246,242,232,.16);border-radius:999px;padding:7px 11px;font-size:.82rem;transition:color .18s ease,border-color .18s ease,background .18s ease}.nav-links a:hover{color:#fff;border-color:rgba(246,242,232,.4);background:rgba(246,242,232,.07)}.toolbar{display:grid;grid-template-columns:minmax(220px,1fr) 135px 135px 155px auto auto;gap:8px;align-items:end;grid-column:1/-1}
  label{display:block;color:#a9b4ab;font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.07em;margin-bottom:4px}input,select,button{font:inherit}input,select{width:100%;height:38px;border:1px solid rgba(246,242,232,.22);border-radius:7px;background:rgba(246,242,232,.08);color:#fff;padding:0 10px;outline:none;transition:border-color .18s ease,box-shadow .18s ease,background .18s ease}select option{color:#111513;background:#fff}input::placeholder{color:#96a29a}input:focus,select:focus,button:focus-visible{outline:3px solid rgba(196,154,61,.35);border-color:var(--amber-curve)}button{height:38px;border:1px solid rgba(246,242,232,.25);border-radius:7px;background:var(--paper);color:var(--ink);padding:0 13px;cursor:pointer;font-weight:760;transition:transform .18s ease,background .18s ease,box-shadow .18s ease}button:hover{background:#fff;box-shadow:0 8px 22px rgba(0,0,0,.28)}button:active{transform:translateY(1px)}
  .hero{position:relative;color:#fff;padding:56px 32px 60px;background:linear-gradient(180deg,var(--charcoal-2),var(--charcoal)),linear-gradient(90deg,rgba(246,242,232,.045) 1px,transparent 1px);background-blend-mode:normal;border-bottom:3px solid var(--amber-curve)}.hero-inner{position:relative;max-width:1440px;margin:0 auto;display:grid;grid-template-columns:minmax(0,1fr) minmax(280px,420px);gap:42px;align-items:end}.hero-copy{max-width:72rem}.eyebrow{margin:0 0 8px;color:var(--muted);font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.08em}.hero .eyebrow{color:#a9b4ab}h1,h2,p{margin-top:0}h1{font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(2.1rem,3.8vw,3.4rem);line-height:1.04;margin:0 0 14px;font-weight:800;text-wrap:balance}h2{font-size:1.12rem;line-height:1.2;margin:0 0 4px;font-weight:760;text-wrap:balance}.hero-host{display:inline-flex;align-items:center;gap:8px;margin:0 0 18px;padding:7px 12px;border:1px solid rgba(246,242,232,.2);border-radius:7px;background:rgba(246,242,232,.06);font-family:"Cascadia Mono","Consolas",monospace;font-size:1rem;color:#f6f2e8}.hero-host:before{content:"";width:8px;height:8px;border-radius:50%;background:var(--amber-curve)}.hero-summary{max-width:62rem;color:#c8d2ca;font-size:1.05rem;margin:0;text-wrap:pretty}.run-pill{display:inline-flex;align-items:center;gap:9px;border:1px solid rgba(246,242,232,.2);background:rgba(246,242,232,.07);padding:9px 12px;border-radius:7px;font-weight:780;white-space:nowrap}.run-pill:before{content:"";width:9px;height:9px;border-radius:50%;background:#69c592;box-shadow:0 0 0 4px rgba(105,197,146,.14)}.run-pill.attention:before{background:#e6a557;box-shadow:0 0 0 4px rgba(230,165,87,.16)}
  .hero-panel{align-self:stretch;display:grid;align-content:end;gap:12px;padding:16px;border:1px solid rgba(246,242,232,.16);border-radius:8px;background:rgba(246,242,232,.05)}.meta-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.meta-item,.hero-proof{border:1px solid rgba(246,242,232,.13);background:rgba(7,9,8,.35);border-radius:7px;padding:12px}.meta-item span,.hero-proof span{display:block;color:#a9b4ab;font-size:.72rem;font-weight:720;text-transform:uppercase;letter-spacing:.06em}.meta-item strong,.hero-proof strong{display:block;margin-top:3px;font-size:1rem;color:#fff}.hero-proof strong{line-height:1.3}
  main{max-width:1440px;margin:0 auto;padding:0 32px 56px;overflow-x:hidden}.callout{display:flex;gap:10px;align-items:center;border-radius:8px;padding:13px 14px;margin:26px 0 0;border:1px solid var(--line)}.danger-callout{background:var(--red-bg);border-color:#e0b0a8;color:#77221e}
  .bento-board{display:grid;grid-template-columns:repeat(12,1fr);grid-auto-flow:dense;gap:14px;margin:44px 0 52px}.bento-card{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--blue);border-radius:8px;padding:20px 20px 22px;box-shadow:var(--card-shadow);transition:box-shadow .25s ease,transform .25s ease}.bento-card:hover{box-shadow:0 2px 4px rgba(17,21,19,.06),0 18px 44px rgba(17,21,19,.12);transform:translateY(-2px)}.bento-card strong{display:block;font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(1.9rem,2.8vw,3rem);line-height:1;margin:10px 0 8px;color:var(--ink)}.bento-card p{margin:0;color:var(--muted);max-width:38rem;text-wrap:pretty}.bento-kicker{font-size:.72rem;font-weight:780;text-transform:uppercase;letter-spacing:.08em;color:var(--blue)}.bento-primary,.bento-review,.bento-security,.bento-reboot{grid-column:span 3}.bento-card.danger{border-left-color:var(--red)}.bento-card.danger .bento-kicker{color:var(--red)}.bento-card.good{border-left-color:var(--green)}.bento-card.good .bento-kicker{color:var(--green)}
  .evidence-layout{display:grid;grid-template-columns:minmax(260px,340px) minmax(0,1fr);gap:22px;align-items:start}.evidence-rail{position:sticky;top:126px;background:var(--charcoal);color:#fff;border:1px solid rgba(246,242,232,.12);border-radius:8px;padding:22px;border-bottom:3px solid var(--amber-curve)}.rail-kicker{color:#a9b4ab;font-size:.72rem;font-weight:760;text-transform:uppercase;letter-spacing:.08em;margin:0 0 10px}.scrub-copy{margin:0}.scrub-copy span{display:block;color:#dce5df;margin:10px 0}.rail-links{display:grid;gap:8px;margin-top:18px}.rail-links a{color:#fff;text-decoration:none;border:1px solid rgba(246,242,232,.15);border-radius:7px;padding:9px 11px;transition:border-color .18s ease,background .18s ease}.rail-links a:hover{border-color:rgba(246,242,232,.4);background:rgba(246,242,232,.07)}.evidence-stack{min-width:0}
  /* Audit-detail appendix. Rendered expanded by default so no-JS and print keep
     the full compliance record; JS collapses it on screen for a lighter view. */
  .audit-divider{display:flex;align-items:center;gap:14px;margin:34px 0 18px}.audit-divider span{font-size:.72rem;font-weight:800;text-transform:uppercase;letter-spacing:.09em;color:var(--muted);white-space:nowrap}.audit-divider:before,.audit-divider:after{content:"";height:1px;background:var(--line-strong);flex:1}.audit-divider:before{flex:0 0 8px}.audit-toggle{white-space:nowrap}.audit-note{margin:0 0 16px;color:var(--muted);font-size:.86rem}.audit-detail.is-collapsed{display:none}
  .panel{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:22px;margin-bottom:18px;box-shadow:var(--card-shadow)}.panel.danger-panel{border-left:3px solid var(--red)}.secondary-panel{background:var(--paper-soft)}.section-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:14px}.count{display:inline-flex;min-width:36px;justify-content:center;border-radius:7px;padding:4px 9px;font-weight:820;background:#e7dfcc;color:#332f29}.count.good{background:var(--green-bg);color:var(--green)}.count.danger{background:var(--red-bg);color:var(--red)}
  .note{color:var(--muted);margin:0 0 14px;max-width:68ch;text-wrap:pretty}.danger-text{color:#842a25}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px;background:#fffdf6}.table-wrap.compact th,.table-wrap.compact td{padding:9px 10px}table{width:100%;border-collapse:separate;border-spacing:0;font-size:.89rem}th,td{padding:11px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}th{position:sticky;top:0;background:#efe8d7;color:#4a453c;font-size:.71rem;font-weight:800;text-transform:uppercase;letter-spacing:.06em;white-space:nowrap;user-select:none;box-shadow:0 1px 0 var(--line)}th[data-sort]{cursor:pointer}th[data-sort]:hover{color:var(--ink)}th[data-sort]:after{content:" sort";color:#9a9081;font-weight:700;text-transform:none;letter-spacing:0;margin-left:4px}tbody tr:last-child td{border-bottom:none}tbody tr:hover td{background:#fdf9ee}
  tr.ok td{box-shadow:inset 3px 0 0 var(--green)}tr.fail td{box-shadow:inset 3px 0 0 var(--red)}tr.planned td{box-shadow:inset 3px 0 0 var(--steel)}tr.skipped td,tr.breach td{box-shadow:inset 3px 0 0 var(--amber-curve)}tr.ok td:not(:first-child),tr.fail td:not(:first-child),tr.planned td:not(:first-child),tr.skipped td:not(:first-child),tr.breach td:not(:first-child){box-shadow:none}.status,.source-pill,.flag{display:inline-flex;align-items:center;border-radius:6px;padding:3px 7px;font-size:.75rem;font-weight:820;white-space:nowrap}.status.ok{background:var(--green-bg);color:var(--green)}.status.fail{background:var(--red-bg);color:var(--red)}.status.planned{background:var(--steel-bg);color:var(--steel)}.status.skipped{background:var(--amber-bg);color:var(--amber)}.source-pill{background:#eae2d0;color:#4f493f}.flag{margin-left:8px}.flag.danger{background:var(--red);color:#fff}.details{min-width:260px;max-width:620px;color:var(--muted);font-size:.82rem;line-height:1.35;white-space:normal}.details summary{cursor:pointer;font-weight:800;color:#4f493f}.details div{margin-top:6px}
  .mono{font-family:"Cascadia Mono","Consolas",monospace;font-size:.84rem}.nowrap{white-space:nowrap}.empty-state{border:1px dashed var(--line-strong);background:#fffdf6;border-radius:8px;padding:24px;max-width:780px}.empty-title{font-weight:820;margin-bottom:4px}.empty-state p{color:var(--muted);margin:0}.two-col{display:grid;grid-template-columns:1fr 1fr;gap:18px}.breakdown-grid{display:grid;grid-template-columns:1.12fr .94fr .94fr;gap:18px}.error-list{margin:0;padding-left:18px;color:#77221e}.result-count{color:var(--muted);font-size:.86rem;margin-top:10px}.footer{margin-top:34px;padding:26px 28px;border-radius:8px;background:var(--charcoal);color:#c8d2ca;display:flex;justify-content:space-between;gap:18px;align-items:center;border-bottom:3px solid var(--amber-curve)}.footer a{color:#fff;text-decoration-color:rgba(196,154,61,.7);text-underline-offset:3px}.footer a:hover{text-decoration-color:var(--amber-curve)}
  .reveal{opacity:1;transform:none}
  @media (max-width:1180px){.bento-board{grid-template-columns:repeat(6,1fr)}.bento-primary,.bento-review,.bento-security,.bento-reboot{grid-column:span 3}.evidence-layout{grid-template-columns:1fr}.evidence-rail{position:static}.breakdown-grid{grid-template-columns:1fr}}@media (max-width:980px){.report-nav{grid-template-columns:1fr}.toolbar{grid-template-columns:1fr 1fr}.toolbar .search-field{grid-column:1/-1}.hero-inner,.two-col{grid-template-columns:1fr}.hero-panel{max-width:620px}}@media (max-width:620px){.report-nav,.hero,main{padding-left:18px;padding-right:18px}.toolbar,.meta-grid{grid-template-columns:1fr}.bento-board{grid-template-columns:1fr;margin-top:28px}.bento-primary,.bento-review,.bento-security,.bento-reboot{grid-column:span 1}h1{font-size:clamp(1.9rem,9vw,2.6rem)}.panel{padding:16px}.section-head{display:block}.count{margin-top:8px}.footer{display:block}.table-wrap{border-radius:7px}}@media print{body{background:#fff;color:#000}.report-nav,button,.skip-link{display:none}.hero{background:#fff;color:#000;padding:18px 0;border-bottom:2px solid #000}.hero-host{color:#000;border-color:#999}.hero-summary,.meta-item span,.hero-proof span{color:#333}.bento-card,.hero-panel,.meta-item,.hero-proof,.panel,.evidence-rail{box-shadow:none;background:#fff;color:#000}.bento-board,.evidence-layout,.two-col,.breakdown-grid{display:block}.audit-detail,.audit-detail.is-collapsed{display:block !important}.audit-toggle{display:none}main{padding:18px 0}.table-wrap{overflow:visible}.panel{break-inside:avoid}.reveal{opacity:1 !important;transform:none !important;transition:none !important}}
  @media (prefers-reduced-motion: reduce){html{scroll-behavior:auto}*{transition:none !important}}
</style>
<noscript><style>.reveal{opacity:1;transform:none}.audit-detail,.audit-detail.is-collapsed{display:block !important}.audit-toggle{display:none}</style></noscript>
</head>
<body>
<a class="skip-link" href="#updates">Skip to update table</a>
<nav class="report-nav" aria-label="Report command bar">
  <div class="nav-brand brand-lockup">$brandMark<span class="brand-word">PatchManager</span></div>
  <div class="nav-links"><a href="#summary">Summary</a><a href="#updates">Action queue</a><a href="#providers">Providers</a><a href="#security">Security</a><a href="#runtime">Runtime</a></div>
  <div class="toolbar" aria-label="Report controls">
    <div class="search-field"><label for="searchInput">Search packages</label><input id="searchInput" type="search" placeholder="Name, package ID, source, version"></div>
    <div><label for="statusFilter">Result</label><select id="statusFilter"><option value="">All results</option><option value="Planned">Planned</option><option value="Completed">Completed</option><option value="Updated">Updated</option><option value="Detected">Detected</option><option value="AlreadyCurrent">Already current</option><option value="Skipped">Skipped</option><option value="Descoped">Descoped</option><option value="Succeeded">Succeeded</option><option value="Blocked">Blocked</option><option value="Verifying">Verifying</option><option value="Failed">Failed</option></select></div>
    <div><label for="sourceFilter">Source</label><select id="sourceFilter"><option value="">All sources</option></select></div>
    <div><label for="providerFilter">Provider</label><select id="providerFilter"><option value="">All providers</option></select></div>
    <div><label>&nbsp;</label><button type="button" id="clearFilters">Clear</button></div>
    <div><label>&nbsp;</label><button type="button" id="printReport">Print</button></div>
  </div>
</nav>
<header class="hero">
  <div class="hero-inner">
    <div class="hero-copy"><div class="hero-brand brand-lockup">$brandMark<span>Patch. Verify. Prove it.</span></div><p class="eyebrow">PatchManager compliance report</p><h1>$verdictTitle<br>$hostname</h1><p class="hero-summary">$runSummary</p></div>
    <div class="hero-panel"><div class="run-pill $runTone">$runMode</div><div class="meta-grid"><div class="meta-item"><span>Ring</span><strong>$ring</strong></div><div class="meta-item"><span>Started</span><strong>$startStr</strong></div><div class="meta-item"><span>Duration</span><strong>${elapsed2dp}m</strong></div><div class="meta-item"><span>Version</span><strong>$ver</strong></div></div><div class="hero-proof"><span>Evidence rows</span><strong>$($Results.Count) total / $($actionableRows.Count) action / $providerCheckCount provider</strong></div></div>
  </div>
</header>
<main id="content">
  $emergencyBanner
  $bentoSection
  <div class="evidence-layout">
    $evidenceRail
    <div class="evidence-stack">
      <div class="reveal">$attentionSection</div>
      <section class="panel reveal" id="updates"><div class="section-head"><div><p class="eyebrow">Actionable package updates</p><h2>$($actionableRows.Count) action row(s)</h2></div><span class="count">$(ConvertTo-ReportHtml $Results.Count) total</span></div>$tableSection<div class="result-count" id="resultCount"></div></section>
      <div id="security" class="two-col reveal">$kevSection$slaSection</div>
      <div class="reveal">$invKevSection</div>
      <div class="reveal">$stalenessSection</div>
      <div class="reveal">$eolSection</div>
      <div class="audit-divider" id="auditDivider"><span>Audit detail</span><button type="button" class="audit-toggle" id="auditToggle" hidden aria-expanded="true" aria-controls="auditDetail">Hide audit detail</button></div>
      <section id="auditDetail" class="audit-detail" aria-label="Audit detail">
        <p class="audit-note">Full provider evidence, per-status counts, and run diagnostics. Included in print and PDF exports for the compliance record.</p>
        <div class="reveal">$skippedSection</div>
        <div id="providers" class="reveal">$providerCheckSection</div>
        <div class="reveal">$breakdownSection</div>
        <div id="runtime" class="reveal">$errSection</div>
        <section class="panel reveal"><div class="section-head"><div><p class="eyebrow">Run metrics</p><h2>Patch state summary</h2></div><span class="count">$avgDays avg days</span></div><p class="note">Tracked updates: $(ConvertTo-ReportHtml $Metrics.TotalTracked). Applied in state: $(ConvertTo-ReportHtml $Metrics.Applied). Pending in state: $(ConvertTo-ReportHtml $Metrics.Pending).</p><p class="note">Coverage: $inventoryCount inventory item(s) across $($sourceGroups.Count) source group(s) and $($providerGroups.Count) provider group(s); $providerCheckCount provider check(s). $visibleSkippedCount skipped or descoped row(s). Generated in ${elapsed2dp}m by PatchManager v$ver.</p></section>
      </section>
    </div>
  </div>
  <div class="footer"><span class="footer-brand brand-lockup">$brandMark<span>Generated by <a href="https://github.com/ciaranwhiteside/PatchManager" target="_blank" rel="noopener">PatchManager</a> v$ver on $generatedAt.</span></span><span>Self-contained HTML report</span></div>
</main>
<script>
(function(){
  var rows = Array.prototype.slice.call(document.querySelectorAll('tr.data-row'));
  var updateRows = Array.prototype.slice.call(document.querySelectorAll('#updatesTable tbody tr.data-row'));
  var search = document.getElementById('searchInput');
  var statusFilter = document.getElementById('statusFilter');
  var sourceFilter = document.getElementById('sourceFilter');
  var providerFilter = document.getElementById('providerFilter');
  var resultCount = document.getElementById('resultCount');
  var clearFilters = document.getElementById('clearFilters');
  var printReport = document.getElementById('printReport');
  var sources = [];
  var providers = [];
  rows.forEach(function(row){var source = row.getAttribute('data-source') || '';if(source && sources.indexOf(source) === -1){sources.push(source);}});
  rows.forEach(function(row){var provider = row.getAttribute('data-provider') || '';if(provider && providers.indexOf(provider) === -1){providers.push(provider);}});
  function appendUniqueOption(select, value){if(!select || !value){return;}var exists = Array.prototype.some.call(select.options, function(option){return option.value === value;});if(exists){return;}var option = document.createElement('option');option.value = value;option.textContent = value;select.appendChild(option);}
  sources.sort().forEach(function(source){appendUniqueOption(sourceFilter, source);});
  providers.sort().forEach(function(provider){appendUniqueOption(providerFilter, provider);});
  var expandAuditForFilter = function(){};
  function applyFilters(){var query = (search.value || '').toLowerCase();var status = statusFilter.value;var source = sourceFilter.value;var provider = providerFilter.value;if(query || status || source || provider){expandAuditForFilter();}var visible = 0;rows.forEach(function(row){var rowText = (row.getAttribute('data-search') || '').toLowerCase();var rowStatus = row.getAttribute('data-status') || '';var rowSource = row.getAttribute('data-source') || '';var rowProvider = row.getAttribute('data-provider') || '';var show = (!query || rowText.indexOf(query) !== -1) && (!status || rowStatus === status) && (!source || rowSource === source) && (!provider || rowProvider === provider);row.style.display = show ? '' : 'none';if(show){visible += 1;}});if(resultCount){resultCount.textContent = visible + ' of ' + rows.length + ' report row(s) visible';}}
  [search,statusFilter,sourceFilter,providerFilter].forEach(function(control){if(control){control.addEventListener('input', applyFilters);control.addEventListener('change', applyFilters);}});
  if(clearFilters){clearFilters.addEventListener('click', function(){search.value = '';statusFilter.value = '';sourceFilter.value = '';providerFilter.value = '';applyFilters();search.focus();});}
  if(printReport){printReport.addEventListener('click', function(){window.print();});}
  document.querySelectorAll('#updatesTable th[data-sort]').forEach(function(th, index){th.addEventListener('click', function(){var tbody = th.closest('table').querySelector('tbody');var direction = th.getAttribute('data-direction') === 'asc' ? 'desc' : 'asc';document.querySelectorAll('#updatesTable th[data-sort]').forEach(function(other){other.removeAttribute('data-direction');});th.setAttribute('data-direction', direction);updateRows.sort(function(a,b){var av = (a.children[index].innerText || '').trim();var bv = (b.children[index].innerText || '').trim();return direction === 'asc' ? av.localeCompare(bv, undefined, {numeric:true}) : bv.localeCompare(av, undefined, {numeric:true});});updateRows.forEach(function(row){tbody.appendChild(row);});applyFilters();});});
  // Audit-detail progressive disclosure. The appendix renders expanded (so no-JS
  // and print keep the full record); here we enable the toggle and collapse it
  // for the on-screen view only.
  var auditDetail = document.getElementById('auditDetail');
  var auditToggle = document.getElementById('auditToggle');
  if(auditDetail && auditToggle){
    var setAuditCollapsed = function(collapsed){auditDetail.classList.toggle('is-collapsed', collapsed);auditToggle.setAttribute('aria-expanded', String(!collapsed));auditToggle.textContent = collapsed ? 'Show audit detail' : 'Hide audit detail';};
    auditToggle.hidden = false;
    setAuditCollapsed(true);
    auditToggle.addEventListener('click', function(){setAuditCollapsed(!auditDetail.classList.contains('is-collapsed'));});
    // A nav/rail link into the collapsed appendix must expand it before scrolling.
    document.querySelectorAll('a[href^="#"]').forEach(function(link){link.addEventListener('click', function(){var id = link.getAttribute('href').slice(1);if(!id){return;}var target = document.getElementById(id);if(target && (target === auditDetail || auditDetail.contains(target))){setAuditCollapsed(false);}});});
    // An active search/filter must reveal appendix rows it matches - otherwise the
    // result count claims rows are visible while they sit inside the collapsed appendix.
    expandAuditForFilter = function(){if(auditDetail.classList.contains('is-collapsed')){setAuditCollapsed(false);}};
  }
  applyFilters();
})();
</script>
</body>
</html>
"@
}

#endregion

#region -- Notifications --------------------------------------------------------------

function Send-RunNotification {
    # Posts a compact JSON run summary to a webhook (Teams/Slack incoming webhooks
    # and generic JSON receivers). Both a human-readable "text" field and structured
    # fields are included. Fire-and-forget: a webhook failure never fails the run.
    param([object]$ReportInfo, [array]$KEVMatches, [array]$SLABreaches)

    $notify = Get-ObjectPropertyValue $script:CFG 'Notifications' $null
    if ($null -eq $notify) { return }
    if (-not [bool](Get-ObjectPropertyValue $notify 'Enabled' $false)) { return }
    $url = [string](Get-ObjectPropertyValue $notify 'WebhookUrl' '')
    if ([string]::IsNullOrWhiteSpace($url)) { return }

    $hasProblems = ($script:Stats.UpdatesFailed -gt 0) -or
                   ($script:Stats.Errors.Count -gt 0) -or
                   ($KEVMatches.Count -gt 0) -or
                   ($SLABreaches.Count -gt 0) -or
                   ($script:ExitCode -ne 0)

    if ([bool](Get-ObjectPropertyValue $notify 'OnlyOnProblems' $true) -and -not $hasProblems) {
        Write-Log 'Notification skipped: run was clean and OnlyOnProblems is enabled.' -Level DEBUG
        return
    }

    $statusWord = if ($hasProblems) { 'NEEDS ATTENTION' } else { 'OK' }
    # Lifecycle exposure (review-severity staleness/EOL findings) is reported in the
    # payload but deliberately NOT part of $hasProblems: an estate with one EOL app
    # would otherwise ping the channel on every run under OnlyOnProblems.
    $stalenessReview = @($script:StalenessFindings | Where-Object { [string]$_.Severity -eq 'review' }).Count
    $eolExposure     = @($script:EndOfLifeFindings | Where-Object { [string]$_.Severity -eq 'review' }).Count
    $summaryText = "PatchManager $statusWord on $($script:HOSTNAME): " +
                   "applied=$($script:Stats.UpdatesApplied) failed=$($script:Stats.UpdatesFailed) " +
                   "skipped=$($script:Stats.UpdatesSkipped) KEV=$($script:Stats.KEVMatches) " +
                   "SLA breaches=$($script:Stats.SLABreaches) errors=$($script:Stats.Errors.Count) " +
                   "staleness=$stalenessReview EOL=$eolExposure"

    $payload = [ordered]@{
        text            = $summaryText
        hostname        = $script:HOSTNAME
        version         = $script:VERSION
        ring            = $script:RING
        dryRun          = $DryRun.IsPresent
        emergency       = $script:EmergencyPatch
        status          = $statusWord
        applied         = $script:Stats.UpdatesApplied
        failed          = $script:Stats.UpdatesFailed
        skipped         = $script:Stats.UpdatesSkipped
        kevMatches      = $script:Stats.KEVMatches
        slaBreaches     = $script:Stats.SLABreaches
        errors          = $script:Stats.Errors.Count
        stalenessReview = $stalenessReview
        eolExposure     = $eolExposure
        reportPath      = if ($ReportInfo) { [string]$ReportInfo.ReportDir } else { '' }
        timestamp       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json

    try {
        $timeoutSec = [Math]::Max(5, [int](Get-ObjectPropertyValue $notify 'TimeoutSec' 15))
        Invoke-RestMethod -Uri $url -Method Post -Body $payload `
                          -ContentType 'application/json; charset=utf-8' `
                          -TimeoutSec $timeoutSec -EA Stop | Out-Null
        Write-Log 'Run notification posted to webhook.' -Level INFO
    } catch {
        Write-Log "Webhook notification failed (run is unaffected): $_" -Level WARN
    }
}

#endregion

#region -- Self Update ----------------------------------------------------------------

function Get-ScriptVersionFromContent {
    # Extracts the $script:VERSION literal from a copy of the script's source.
    # Standalone and side-effect-free so it can be unit tested.
    param([string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $null }
    $match = [regex]::Match($Content, "\`$script:VERSION\s*=\s*'([^']+)'")
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Test-SelfUpdateSource {
    param(
        [string]$Repository,
        [string]$Ref
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return $false }
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $false }
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,240}$') { return $false }
    if ($Ref -match '(^|/)\.\.(/|$)') { return $false }
    return $true
}

function Get-LatestReleaseTagFromJson {
    # Extracts tag_name from a GitHub releases/latest API response. Standalone
    # and side-effect-free for unit testing.
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try {
        $tag = [string]($Json | ConvertFrom-Json).tag_name
        if ([string]::IsNullOrWhiteSpace($tag)) { return $null }
        return $tag
    } catch { return $null }
}

function Resolve-SelfUpdateRef {
    # 'latest' resolves to the newest PUBLISHED release tag (the API excludes
    # drafts and pre-releases). Any other value is used verbatim (pin a tag, or
    # 'main' to track the branch). Returns $null on failure so the caller skips.
    param([string]$Repository, [string]$Ref, [int]$TimeoutSec)
    if ($Ref -ne 'latest') { return $Ref }
    $api = "https://api.github.com/repos/$Repository/releases/latest"
    try {
        $resp = Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec $TimeoutSec `
                    -Headers @{ 'User-Agent' = 'PatchManager-SelfUpdate'; 'Accept' = 'application/vnd.github+json' } -EA Stop
        return (Get-LatestReleaseTagFromJson -Json ([string]$resp.Content))
    } catch {
        Write-Log "Self-update: could not resolve the latest release tag: $_" -Level WARN
        return $null
    }
}

function Invoke-SelfUpdate {
    # Refresh PatchManager itself from GitHub. Security posture:
    #   - On for Personal/Commercial, off for CommercialManaged (resolved by profile).
    #   - Tracks PUBLISHED releases by default (Ref 'latest'): a moving branch or a
    #     momentary bad commit never auto-ships; drafts/pre-releases are excluded.
    #   - HTTPS only (TLS 1.2 enforced at startup) to a validated GitHub repo/ref.
    #   - Version-gated: only a strictly newer [version] is considered (no downgrades).
    #   - The download is PARSE-VALIDATED before it is installed, and its hash is
    #     checked against ExpectedSha256 when that is pinned.
    #   - The current on-disk script is backed up to a timestamped .bak; the new version is
    #     NEVER executed in this run - the next run picks it up.
    #   - Works for clone and zip installs; in a clone it updates only Invoke-PatchManager.ps1.
    #   - Apply is skipped in DryRun/ReportOnly.
    $su = Get-ObjectPropertyValue $script:CFG 'SelfUpdate' $null
    if ($null -eq $su -or -not [bool](Get-ObjectPropertyValue $su 'Enabled' $false)) {
        $script:SelfUpdateStatus = 'Disabled'
        return
    }

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
        Write-Log 'Self-update: cannot resolve the running script path; skipping.' -Level WARN
        $script:SelfUpdateStatus = 'Skipped (unresolved path)'
        return
    }

    $scriptDir = Split-Path -Parent $scriptPath
    $isGitClone = Test-Path (Join-Path $scriptDir '.git')

    $repo    = [string](Get-ObjectPropertyValue $su 'Repository' 'ciaranwhiteside/PatchManager')
    $ref     = [string](Get-ObjectPropertyValue $su 'Ref' 'main')
    $timeout = [Math]::Max(5, [int](Get-ObjectPropertyValue $su 'TimeoutSec' 30))
    if (-not (Test-SelfUpdateSource -Repository $repo -Ref $ref)) {
        Write-Log "Self-update: invalid Repository or Ref value ('$repo' @ '$ref'); skipping." -Level WARN
        $script:SelfUpdateStatus = 'Skipped (invalid source)'
        return
    }

    # Resolve 'latest' to the newest published release tag (published releases only).
    $resolvedRef = Resolve-SelfUpdateRef -Repository $repo -Ref $ref -TimeoutSec $timeout
    if ([string]::IsNullOrWhiteSpace($resolvedRef) -or -not (Test-SelfUpdateSource -Repository $repo -Ref $resolvedRef)) {
        Write-Log "Self-update: could not resolve a valid release ref from '$ref'; skipping." -Level WARN
        $script:SelfUpdateStatus = 'Skipped (no release found)'
        return
    }

    $rawUrl  = "https://raw.githubusercontent.com/$repo/$resolvedRef/Invoke-PatchManager.ps1"

    $tempFile = Join-Path $scriptDir ".PatchManager.selfupdate.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-Log "Self-update: checking $repo@$resolvedRef for a newer version..." -Level INFO
        Invoke-WebRequest -Uri $rawUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec $timeout -EA Stop

        $remoteContent = Get-Content $tempFile -Raw
        $remoteVerText = Get-ScriptVersionFromContent -Content $remoteContent
        if ([string]::IsNullOrWhiteSpace($remoteVerText)) {
            Write-Log 'Self-update: could not read a version from the downloaded script; skipping.' -Level WARN
            $script:SelfUpdateStatus = 'Skipped (no remote version)'
            return
        }

        try {
            $remoteVer = [version]$remoteVerText
            $localVer  = [version]$script:VERSION
        } catch {
            Write-Log "Self-update: version comparison failed (local '$($script:VERSION)', remote '$remoteVerText'); skipping." -Level WARN
            $script:SelfUpdateStatus = 'Skipped (unparseable version)'
            return
        }

        if ($remoteVer -le $localVer) {
            Write-Log "Self-update: already current (local $localVer, remote $remoteVer)." -Level INFO
            $script:SelfUpdateStatus = "Current ($localVer)"
            return
        }

        Write-Log "Self-update: newer version available: $localVer -> $remoteVer." -Level WARN

        # Integrity gate 1: the download must parse cleanly as PowerShell. This
        # rejects truncated or corrupted downloads before they are ever installed.
        $parseErrors = $null; $parseTokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tempFile, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Log "Self-update: downloaded script failed to parse ($($parseErrors.Count) error(s)); refusing to install." -Level ERROR
            $script:SelfUpdateStatus = 'Available (download failed validation)'
            return
        }

        # Integrity gate 2: optional pinned hash for locked-down estates.
        $expectedHash = [string](Get-ObjectPropertyValue $su 'ExpectedSha256' '')
        if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
            $actualHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
            if ($actualHash -ine $expectedHash.Trim()) {
                Write-Log "Self-update: SHA256 mismatch (expected $($expectedHash.Trim()), got $actualHash); refusing to install." -Level ERROR
                $script:SelfUpdateStatus = 'Available (hash mismatch)'
                return
            }
            Write-Log 'Self-update: pinned SHA256 verified.' -Level INFO
        }

        if (-not [bool](Get-ObjectPropertyValue $su 'AutoApply' $true)) {
            Write-Log "Self-update: update $localVer -> $remoteVer is available. AutoApply is off; not modifying the script." -Level WARN
            $script:SelfUpdateStatus = "Available ($localVer -> $remoteVer, AutoApply off)"
            return
        }

        if ($DryRun -or $ReportOnly) {
            Write-Log "Self-update: update $localVer -> $remoteVer available. Not applied in DryRun/ReportOnly." -Level INFO
            $script:SelfUpdateStatus = "Available ($localVer -> $remoteVer)"
            return
        }

        # Apply: back up the current script, then swap in the validated download.
        # The running process keeps executing the old version; the next run uses
        # the new one - we never execute freshly downloaded elevated code inline.
        if ($isGitClone) {
            Write-Log 'Self-update: git clone install detected; replacing Invoke-PatchManager.ps1 only. Use git pull to refresh docs/config/tests.' -Level INFO
        }
        $backupPath = "$scriptPath.$((Get-Date).ToString('yyyyMMddHHmmss')).bak"
        Copy-Item -Path $scriptPath -Destination $backupPath -Force -EA Stop
        Copy-Item -Path $tempFile -Destination $scriptPath -Force -EA Stop

        # Keep only the three most recent backups so updates don't accumulate
        # stale copies of an elevated script indefinitely.
        $scriptLeaf = Split-Path -Leaf $scriptPath
        Get-ChildItem -Path $scriptDir -Filter "$scriptLeaf.*.bak" -File -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 3 |
            Remove-Item -Force -EA SilentlyContinue
        Write-Log "Self-update: applied $localVer -> $remoteVer. Backup: $backupPath. Takes effect on the next run." -Level SUCCESS
        Write-RunEvent -EventId 1030 -Type Information -Message "PatchManager self-updated on $($script:HOSTNAME): $localVer -> $remoteVer (effective next run)."
        $script:SelfUpdateStatus = "Applied ($localVer -> $remoteVer, effective next run)"
    } catch {
        Write-Log "Self-update check failed (run is unaffected): $_" -Level WARN
        $script:SelfUpdateStatus = 'Check failed'
    } finally {
        Remove-Item $tempFile -Force -EA SilentlyContinue
    }
}

#endregion

#region -- Reboot Detection -----------------------------------------------------------

function Test-RebootRequired {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

#endregion

#region -- Main Orchestration ---------------------------------------------------------

function Invoke-Main {
    $script:CFG = Import-Configuration -Path $ConfigPath

    if ($InstallStartupTask) {
        Install-PatchManagerStartupTask -Name $TaskName -DelayMinutes $TaskDelayMinutes
        return
    }
    if ($UninstallStartupTask) {
        Uninstall-PatchManagerStartupTask -Name $TaskName
        return
    }

    Initialize-Logging

    Write-Log ('=' * 70) -Level INFO
    Write-Log "PatchManager v$($script:VERSION) | Host: $($script:HOSTNAME)" -Level INFO
    Write-Log "Mode: DryRun=$($DryRun.IsPresent) | ReportOnly=$($ReportOnly.IsPresent) | Force=$($Force.IsPresent)" -Level INFO
    Write-Log ('=' * 70) -Level INFO
    Write-RunEvent -EventId 1000 -Type Information -Message "PatchManager run started on $($script:HOSTNAME) (v$($script:VERSION))"

    # Single-instance guard - prevents overlapping runs corrupting state
    if (-not (Enter-SingleInstance)) {
        exit 0
    }

    $script:RING = Get-DeploymentRing
    $ringDelay   = $script:CFG.Ring.Delays[$script:RING]
    Write-Log "Ring: $($script:RING) (suggested delay: ${ringDelay}d - enforce via deployment tooling)" -Level INFO

    #-- Pre-flight ------------------------------------------------------------
    if (-not (Invoke-PreFlightChecks)) {
        Write-Log 'Pre-flight checks failed. Aborting without changes.' -Level ERROR
        exit 2
    }

    #-- Self-update -----------------------------------------------------------
    # Runs after pre-flight (network confirmed). If it applies an update, this run
    # continues on the current version; the next run uses the new one.
    Invoke-SelfUpdate

    #-- BITS throttle ---------------------------------------------------------
    Set-BITSThrottle

    #-- Inventory + KEV emergency detection -----------------------------------
    # Done before the maintenance window check so actionable KEV matches can bypass it.
    $inventory = Get-SoftwareInventory
    $script:Inventory = @($inventory)   # shared with the EOL scan - avoid a second full enumeration
    $script:Stats.InventoryCount = $inventory.Count
    $script:SkippedUpgradeResults.Clear()
    $script:SourceCheckResults.Clear()

    $allUpgrades      = @(Get-WinGetUpgrades)
    $filteredUpgrades = @(Get-FilteredUpgrades -Upgrades $allUpgrades)

    $kevData    = Get-CISAKEVData
    $kevMatches = @(Add-KEVExposure -Candidates @(Find-KEVCandidates -Packages $filteredUpgrades -KEVData $kevData))

    # Informational pass over the FULL inventory: KEV-listed software with no
    # actionable update still deserves visibility in the report. Exclude anything
    # already covered by an actionable match. Does not trigger emergency handling.
    $actionableKevKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $kevMatches) { [void]$actionableKevKeys.Add("$($m.CVE)|$($m.InstalledApp)") }
    $script:InventoryKEVMatches = @(Add-KEVExposure -Candidates @(
        Find-KEVCandidates -Packages $inventory -KEVData $kevData -Informational |
            Where-Object { -not $actionableKevKeys.Contains("$($_.CVE)|$($_.InstalledApp)") }))

    # Only a CONFIRMED version match justifies bypassing the maintenance window. A
    # name-only KEV hit proves nothing about the installed build: every Chrome install
    # matches a 2020 Chrome CVE. Unknown exposure is reported, never escalated.
    $confirmedKev = @($kevMatches | Where-Object { $_.ExposureState -eq 'Affected' })
    $script:Stats.KEVCandidates = $kevMatches.Count + $script:InventoryKEVMatches.Count
    $script:Stats.KEVMatches    = $confirmedKev.Count

    $kevBreakdown = ($kevMatches + $script:InventoryKEVMatches | Group-Object ExposureState |
        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    if ($script:Stats.KEVCandidates -gt 0) {
        Write-Log "CISA KEV: $($script:Stats.KEVCandidates) candidate(s) resolved against NVD [$kevBreakdown]." -Level INFO
    }

    if ($confirmedKev.Count -gt 0) {
        $script:EmergencyPatch = $true
        Write-Log "EMERGENCY: $($confirmedKev.Count) CISA KEV match(es) confirmed affected by version. Bypassing maintenance window and reducing jitter." -Level ERROR
        Write-RunEvent -EventId 9001 -Type Error `
            -Message "KEV EMERGENCY on $($script:HOSTNAME): $(($confirmedKev | ForEach-Object { "$($_.CVE) ($($_.InstalledApp) $($_.InstalledVer))" }) -join ', ')"
    } elseif ($kevMatches.Count -gt 0) {
        Write-Log "CISA KEV: $($kevMatches.Count) actionable candidate(s), none confirmed affected by installed version. No emergency." -Level INFO
    }

    #-- Maintenance window ----------------------------------------------------
    if (-not $ReportOnly) {
        $inWindow = Test-MaintenanceWindow
        if (-not $inWindow -and -not $script:EmergencyPatch) {
            Write-Log 'Outside maintenance window and no emergency detected. Exiting.' -Level INFO
            exit 0
        }

        # Emergency patches get max 5 min jitter. Normal runs use config value.
        $jitterCap = if ($script:EmergencyPatch) { 5 } else { 0 }
        Start-JitteredDelay -Ring $script:RING -CapMinutes $jitterCap
    }

    #-- Load patch state + SLA breaches ---------------------------------------
    $patchState  = Get-PatchState
    $slaBreaches = @(Get-SLABreaches -State $patchState)

    if ($slaBreaches.Count -gt 0) {
        Write-Log "SLA BREACH: $($slaBreaches.Count) update(s) available for over $($script:CFG.SLA.Critical) days." -Level ERROR
        $slaBreaches | ForEach-Object {
            Write-Log "  BREACH: $($_.PackageName) v$($_.VersionAvailable) available since $($_.FirstSeenAvailable) (due: $($_.SLADue))" -Level ERROR
        }
        $script:Stats.SLABreaches = $slaBreaches.Count
        Write-RunEvent -EventId 1020 -Type Error `
            -Message "SLA BREACH on $($script:HOSTNAME): $($slaBreaches.Count) update(s) past the $($script:CFG.SLA.Critical)-day deadline. Packages: $(($slaBreaches | ForEach-Object { $_.PackageName }) -join ', ')"
    }

    #-- Patching --------------------------------------------------------------
    $updateResults = @($script:SourceCheckResults) + @($script:SkippedUpgradeResults)

    if (-not $ReportOnly) {
        New-PatchRestorePoint

        $updateResults = @($script:SourceCheckResults) +
                         @($script:SkippedUpgradeResults) +
                         @(Invoke-WindowsUpdateProvider) +
                         @(Invoke-AllUpdates -Upgrades $filteredUpgrades -KEVMatches $kevMatches) +
                         @(Invoke-Microsoft365Provider) +
                         @(Invoke-BrowserProvider -Browser Chrome -WinGetCandidates $filteredUpgrades) +
                         @(Invoke-BrowserProvider -Browser Edge -WinGetCandidates $filteredUpgrades) +
                         @(Invoke-MicrosoftStoreClientUpdates) +
                         @(Invoke-ChocolateyProvider) +
                         @(Invoke-ScoopProvider) +
                         @(Invoke-PythonManagerProvider) +
                         @(Invoke-VendorUpdaterProvider -WinGetCandidates $filteredUpgrades) +
                         @(Invoke-FirmwareProvider)

    }

    $updateResults = @($updateResults | ForEach-Object { ConvertTo-PatchResult -InputObject $_ })
    Update-StatsFromResults -Results $updateResults

    if (-not $ReportOnly -and -not $DryRun) {
        $patchState = Save-PatchState -State $patchState `
                                       -AvailableUpgrades $filteredUpgrades `
                                       -AppliedResults $updateResults
    }
    $slaBreaches = @(Get-SLABreaches -State $patchState)
    $script:Stats.SLABreaches = $slaBreaches.Count

    #-- Report-only staleness scan (never patches; own report section) --------
    $script:StalenessFindings = @(Invoke-StalenessReport)

    #-- Report-only end-of-life scan (endoflife.date; never patches) ----------
    $script:EndOfLifeFindings = @(Invoke-EndOfLifeReport)

    #-- Metrics + reporting ---------------------------------------------------
    $metrics = Get-PatchMetrics -State $patchState
    Write-Log "Metrics: Pending=$($metrics.Pending) | Breaches=$($metrics.SLABreaches) | Avg days to apply=$($metrics.AvgDaysToApply)" -Level INFO

    $reportInfo = New-ComplianceReport -Results $updateResults `
                                       -KEVMatches $kevMatches `
                                       -SLABreaches $slaBreaches `
                                       -PatchState $patchState `
                                       -Metrics $metrics

    Copy-LogsToCentral

    $retention = $script:CFG.Logging.RetentionDays
    Remove-OldFiles -Path $script:CFG.Logging.LocalLogPath     -Filter 'PatchManager_*.log'   -Days $retention
    Remove-OldFiles -Path $script:CFG.Reporting.LocalReportPath -Filter 'PatchReport_*.html'  -Days $retention
    Remove-OldFiles -Path $script:CFG.Reporting.LocalReportPath -Filter 'PatchReport_*.json'  -Days $retention
    Remove-OldFiles -Path $script:CFG.Reporting.LocalReportPath -Filter 'PatchReport_*.csv'   -Days $retention

    #-- Summary ---------------------------------------------------------------
    $elapsed = [Math]::Round(((Get-Date) - $script:STARTTIME).TotalMinutes, 2)
    Write-Log ('=' * 70) -Level INFO
    Write-Log "Completed in ${elapsed} minutes." -Level INFO
    Write-Log "Updates: Planned=$($script:Stats.UpdatesPlanned) | Applied=$($script:Stats.UpdatesApplied) | Failed=$($script:Stats.UpdatesFailed) | Skipped=$($script:Stats.UpdatesSkipped)" -Level INFO
    Write-Log "Security: KEV Matches=$($script:Stats.KEVMatches) | SLA Breaches=$($script:Stats.SLABreaches)" -Level INFO
    Write-Log ('=' * 70) -Level INFO

    # Lifecycle completion event for SIEM - one clean summary line per run
    $summaryMsg = "PatchManager completed on $($script:HOSTNAME) in ${elapsed}m. " +
                  "Planned=$($script:Stats.UpdatesPlanned) Applied=$($script:Stats.UpdatesApplied) Failed=$($script:Stats.UpdatesFailed) " +
                  "Skipped=$($script:Stats.UpdatesSkipped) KEV=$($script:Stats.KEVMatches) " +
                  "SLABreaches=$($script:Stats.SLABreaches)"
    if ($script:ExitCode -eq 0) {
        Write-RunEvent -EventId 1010 -Type Information -Message $summaryMsg
    } else {
        Write-RunEvent -EventId 1011 -Type Warning -Message $summaryMsg
    }

    Send-RunNotification -ReportInfo $reportInfo -KEVMatches $kevMatches -SLABreaches $slaBreaches

    if ($reportInfo -and $reportInfo.HtmlPath) {
        Show-CompletionPopup -HtmlReportPath $reportInfo.HtmlPath
    }

    Exit-SingleInstance

    if ($script:ExitCode -eq 0 -and (Test-RebootRequired)) {
        Write-Log 'Reboot required to complete updates.' -Level WARN
        Write-RunEvent -EventId 3010 -Type Warning -Message "Reboot required on $($script:HOSTNAME) to complete updates."
        exit 3010
    }

    exit $script:ExitCode
}

#endregion

# -- Entry point -----------------------------------------------------------------------
try {
    Invoke-Main
} catch {
    Write-Host "[FATAL][$($env:COMPUTERNAME)] Unhandled exception: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    try { Write-Log "FATAL: $_" -Level ERROR } catch { }
    try { Write-RunEvent -EventId 1011 -Type Error -Message "PatchManager FATAL on $($env:COMPUTERNAME): $_" } catch { }
    exit 99
} finally {
    # Always restore machine state, even on early exit or crash
    try { Restore-BITSThrottle } catch { }
    try { Exit-SingleInstance } catch { }
}

