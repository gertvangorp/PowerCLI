#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the clock of every ESXi host against a reference time, together with the host's NTP configuration.

.DESCRIPTION
    Connects to vCenter and asks every host for its current time (HostDateTimeSystem.QueryDateTime),
    then compares it with a reference time:
      - by default the host's own NTP server: the first server in the host's NTP config that answers
        from this machine,
      - with -ReferenceNtpServer, that one NTP server for every host,
      - with -UseLocalClock, or when no NTP server answers, the UTC clock of this machine.
    For an NTP reference the script asks the server once (SNTP, UDP 123) how far the local clock is
    off and corrects for that, so a wrong clock on your own machine does not show up as drift.
    The local time is taken halfway the QueryDateTime call, so the vCenter round trip is not counted
    as drift.

    Per host: cluster, host time, reference time, offset in seconds (positive = host is ahead),
    time protocol, configured NTP servers, ntpd running and its startup policy.
    OffsetLevel: OK below -WarningOffsetSeconds (default 2), Warning from 2 up to and including
    -CriticalOffsetSeconds (default 10), Critical above 10. Status is the worst of OffsetLevel and the
    NTP checks (no NTP server configured, ntpd not running, or its policy not "on" = Warning), with the
    reasons in Message. Hosts that are not connected or fail are reported too (Skipped / Failed).

    Results are written to the pipeline as objects, sorted by cluster and host. With -CsvPath they
    are also exported to CSV, with -HtmlPath to a self-contained HTML report (summary on top, offsets
    colour coded green / orange / red, hosts that need attention, all hosts per cluster). A short
    summary (min, max, average offset, warnings) is printed at the end.

    The script only reads. It changes nothing in vCenter or on the hosts. To fix the NTP settings
    use Set-EsxiNtpServer in this repository.

    Credentials (vCenter SSO account), in this order:
      -Credential, or VcUser / VcCredentialFile in the config file,
      -UseSddcCredentials: the vCenter SSO account is read from the SDDC Manager vault
                           (GET /v1/credentials, needs the SDDC Manager ADMIN role),
      otherwise Get-Credential asks.

.PARAMETER VCenter
    vCenter FQDN. Config: VCenter.

.PARAMETER Cluster
    One or more cluster names. Leave empty for all hosts in vCenter. Config: Cluster.

.PARAMETER VMHost
    One or more host names as known in vCenter (wildcards work). Combined with -Cluster, only the
    matching hosts in those clusters. Config: VMHost.

.PARAMETER WarningOffsetSeconds
    Offset (absolute, in seconds) from which a host is Warning (orange). Default 2. Config: WarningOffsetSeconds.

.PARAMETER CriticalOffsetSeconds
    Offset (absolute, in seconds) above which a host is Critical (red). Default 10. Config: CriticalOffsetSeconds.

.PARAMETER ReferenceNtpServer
    One NTP server used as the reference for every host, instead of each host's own NTP servers
    (needs UDP 123 from this machine). Config: ReferenceNtpServer.

.PARAMETER UseLocalClock
    Compare with the clock of this machine instead of NTP. Config: UseLocalClock.

.PARAMETER CsvPath
    Optional CSV export path. "{date}" is replaced with yyyyMMdd-HHmm, "{env}" with the environment
    name. Config: CsvPath.

.PARAMETER HtmlPath
    Optional HTML report path (one self-contained file; the folder is created when needed). "{date}"
    and "{env}" as for -CsvPath. Config: HtmlPath.

.PARAMETER Credential
    vCenter account. Config: VcUser (prompt) or VcCredentialFile (Export-Clixml).

.PARAMETER Environment
    Name of an environment config: reads config\<name>.config.json in this repository.

.PARAMETER ConfigFile
    Path to an environment config file (JSON). Command line wins over the file. Passwords are refused in the file.

.PARAMETER UseSddcCredentials
    Read the vCenter SSO account from the SDDC Manager vault. Needs -SddcManager.

.PARAMETER SddcManager
    SDDC Manager FQDN, only for -UseSddcCredentials. Config: SddcManager.

.PARAMETER SddcCredential
    SDDC Manager account with the ADMIN role. Config: SddcUser (prompt) or SddcCredentialFile.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the SDDC Manager TLS certificate. For vCenter, PowerCLI's own
    setting applies (Set-PowerCLIConfiguration -InvalidCertificateAction).

.EXAMPLE
    .\Get-EsxiTimeReport.ps1 -VCenter vc01.corp.local | Format-Table

.EXAMPLE
    # Every host against one NTP server (default: each host's own), only the hosts with a warning
    .\Get-EsxiTimeReport.ps1 -VCenter vc01.corp.local -ReferenceNtpServer ntp1.corp.local | Where-Object Status -ne 'OK'

.EXAMPLE
    # Environment config: reads config\lab1.config.json, vCenter account from the SDDC Manager vault
    .\Get-EsxiTimeReport.ps1 -Environment lab1 -UseSddcCredentials -HtmlPath C:\Reports\{env}-time-{date}.html

.NOTES
    Name        : Get-EsxiTimeReport.ps1
    Version     : 2.0
    Date        : 2026-11-24
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : PowerShell 7 or Windows PowerShell 5.1, VCF.PowerCLI (or VMware.PowerCLI).
    Config      : one file per environment, see config\environment.config.sample.json
    License     : provided as is, without warranty. Test in a lab first.
    Credits     : based on Get-VMHostTimeReport by Grzegorz Kulikowski (psvmware.wordpress.com).

    Version history
    2.0  2026-11-24  Rewrite for this repository: environment config, -UseSddcCredentials, Cluster column,
                     -Cluster / -VMHost filters, signed offset, OffsetLevel (<2 / 2-10 / >10 s) and Status,
                     reference = the host's own NTP server, -ReferenceNtpServer or -UseLocalClock (SNTP)
                     instead of the retired earthtools.org web service,
                     ntpd policy, -HtmlPath report, disconnects only its own vCenter session.
    1.0  2025-10-13  First version (Report-HostTime2NTP.ps1).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-EsxiTimeReport
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$Cluster,
    [string[]]$VMHost,
    [double]$WarningOffsetSeconds = 2,
    [double]$CriticalOffsetSeconds = 10,
    [string]$ReferenceNtpServer,
    [switch]$UseLocalClock,
    [string]$CsvPath,
    [string]$HtmlPath,
    [pscredential]$Credential,
    [string]$Environment,
    [string]$ConfigFile,
    [switch]$UseSddcCredentials,
    [string]$SddcManager,
    [pscredential]$SddcCredential,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '2.0 (2026-11-24)'
Write-Host "Get-EsxiTimeReport.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'HostTimeReport'
$ConfigSettings = @{ VCenter = 'first'; Cluster = 'list'; VMHost = 'list'; WarningOffsetSeconds = 'string'; CriticalOffsetSeconds = 'string'; ReferenceNtpServer = 'string'; UseLocalClock = 'switch'; CsvPath = 'string'; HtmlPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
$ConfigCredentials = [ordered]@{ Vc = 'Credential'; Sddc = 'SddcCredential' }

#region Environment config file (shared: identical in every script, checked by CI) -------------
# One config file per environment (lab, customer, ...), shared by all scripts in this repository:
#   -Environment lab1          reads <repo>\config\lab1.config.json
#   -ConfigFile <path>         reads that file
# Keys are read from the top level, then "Common", then this script's own section ($ConfigSection);
# a later one wins. Order of precedence: command line > config file > prompt.
# Passwords are never read from the file: use <X>User (prompt) or <X>CredentialFile (Export-Clixml).
$EnvironmentName = $null
if ($Environment -and -not $ConfigFile) {
    $ConfigFile = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config') "$Environment.config.json"
}
if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile (copy config\environment.config.sample.json)" }
    $cfgRaw = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    $cfg = @{}
    foreach ($part in @($cfgRaw, $cfgRaw.Common, $cfgRaw.$ConfigSection)) {
        if ($null -eq $part) { continue }
        foreach ($pp in $part.PSObject.Properties) {
            if ($pp.Name -like '_*' -or $pp.Value -is [System.Management.Automation.PSCustomObject]) { continue }
            $cfg[$pp.Name] = $pp.Value
        }
    }
    # No passwords anywhere in the file, also not in the sections of other scripts.
    $allNames = @($cfgRaw.PSObject.Properties | ForEach-Object {
            $_.Name
            if ($_.Value -is [System.Management.Automation.PSCustomObject]) { $_.Value.PSObject.Properties.Name }
        })
    $secretKeys = @($allNames | Where-Object { $_ -notlike '_*' -and $_ -match 'password|secret|token' } | Sort-Object -Unique)
    if ($secretKeys) { throw "Config file contains $($secretKeys -join ', '). Do not store passwords in it: use <X>User (prompt) or <X>CredentialFile (Export-Clixml)." }

    $EnvironmentName = if ($cfg.Environment) { [string]$cfg.Environment } else { [IO.Path]::GetFileName($ConfigFile) -replace '\.config\.json$|\.json$', '' }
    foreach ($k in $ConfigSettings.Keys) {
        if (-not $cfg.ContainsKey($k) -or $PSBoundParameters.ContainsKey($k) -or $null -eq $cfg[$k]) { continue }
        $v = switch ($ConfigSettings[$k]) {
            'list' { [string[]]@($cfg[$k] | Where-Object { $_ }) }
            'switch' { [switch][bool]$cfg[$k] }
            'first' { [string](@($cfg[$k])[0]) }   # a list is allowed (other scripts), this script takes the first
            default { [string]$cfg[$k] }
        }
        Set-Variable -Name $k -Value $v
    }
    foreach ($pre in $ConfigCredentials.Keys) {
        $name = $ConfigCredentials[$pre]
        if ($PSBoundParameters.ContainsKey($name)) { continue }
        $file = $cfg["${pre}CredentialFile"]; $user = $cfg["${pre}User"]
        if ($file) { Set-Variable -Name $name -Value (Import-Clixml ([Environment]::ExpandEnvironmentVariables([string]$file))) }
        # With -UseSddcCredentials only the SDDC Manager login is prompted for; the vault supplies the rest.
        elseif ($user -and -not ($UseSddcCredentials -and $pre -ne 'Sddc')) { Set-Variable -Name $name -Value (Get-Credential -UserName ([string]$user) -Message "Password for $user ($pre)") }
    }
    Write-Host "Environment: $EnvironmentName ($ConfigFile)" -ForegroundColor Cyan
}
# Placeholders in paths: {date} = yyyyMMdd-HHmm, {env} = environment name, plus %VARIABLES%.
function Expand-PathTemplate([string]$Path) {
    if (-not $Path) { return $Path }
    [Environment]::ExpandEnvironmentVariables($Path).Replace('{date}', (Get-Date -Format 'yyyyMMdd-HHmm')).Replace('{env}', $(if ($EnvironmentName) { $EnvironmentName } else { 'default' }))
}
#endregion
if (-not $VCenter) { throw 'No vCenter given. Use -VCenter or "VCenter" in the config file.' }
$CsvPath = Expand-PathTemplate $CsvPath
$HtmlPath = Expand-PathTemplate $HtmlPath
$WarningOffsetSeconds = [double]::Parse("$WarningOffsetSeconds", [Globalization.CultureInfo]::InvariantCulture)
$CriticalOffsetSeconds = [double]::Parse("$CriticalOffsetSeconds", [Globalization.CultureInfo]::InvariantCulture)
if ($CriticalOffsetSeconds -lt $WarningOffsetSeconds) { throw '-CriticalOffsetSeconds must be at least -WarningOffsetSeconds.' }

#region SDDC Manager vault functions (shared: identical in every script, checked by CI) -------
function Invoke-SddcApi {
    param([string]$Method = 'Get', [string]$Path, [hashtable]$Body, [string]$Token)
    $p = @{ Uri = "https://$SddcManager$Path"; Method = $Method; ContentType = 'application/json' }
    if ($Token) { $p.Headers = @{ Authorization = "Bearer $Token" } }
    if ($Body) { $p.Body = $Body | ConvertTo-Json }
    if ($isCore -and $SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
    Invoke-RestMethod @p
}
function Get-SddcVault {
    # Returns all vault entries. Passwords are only turned into SecureString, never written out.
    $body = @{ username = $SddcCredential.UserName; password = $SddcCredential.GetNetworkCredential().Password }
    $token = (Invoke-SddcApi -Method Post -Path '/v1/tokens' -Body $body).accessToken
    $body = $null
    @((Invoke-SddcApi -Path '/v1/credentials' -Token $token).elements)
}
function Get-VaultCredential {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The SDDC Manager API returns the password as plain text; it is converted at once and never written out.')]
    param($Vault, [string[]]$ResourceType, [string]$Name, [string]$CredentialType, [string]$UserName)
    $isIp = $Name -match '^\d{1,3}(\.\d{1,3}){3}$'
    $short = ($Name -split '\.')[0]
    $hit = $Vault | Where-Object {
        "$($_.resource.resourceType)" -in $ResourceType -and
        ($_.resource.resourceName -eq $Name -or $_.resource.resourceIp -eq $Name -or
            (-not $isIp -and ("$($_.resource.resourceName)" -split '\.')[0] -eq $short)) -and
        (-not $CredentialType -or $_.credentialType -eq $CredentialType) -and
        (-not $UserName -or $_.username -eq $UserName)
    } | Select-Object -First 1
    if (-not $hit -or -not $hit.password -or "$($hit.password)" -match '^\*+$') { return $null }
    [pscredential]::new($hit.username, (ConvertTo-SecureString "$($hit.password)" -AsPlainText -Force))
}
#endregion

#region Credentials --------------------------------------------------------------------------

if ($UseSddcCredentials -and -not $Credential) {
    if (-not $SddcManager) { throw '-UseSddcCredentials needs -SddcManager (or "SddcManager" in the config file).' }
    if ($SkipCertificateCheck) {
        Write-Warning 'SDDC Manager certificate validation is disabled. Use this in a lab only.'
        if (-not $isCore) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
    if (-not $SddcCredential) { $SddcCredential = Get-Credential -Message 'SDDC Manager account with the ADMIN role' }
    Write-Host "Reading the vCenter SSO account from the SDDC Manager vault on $SddcManager ..." -ForegroundColor Cyan
    # The SSO administrator is stored as credentialType SSO, under resourceType PSC (or VCENTER).
    $Credential = Get-VaultCredential -Vault (Get-SddcVault) -ResourceType 'PSC', 'VCENTER' -Name $VCenter -CredentialType 'SSO'
    if (-not $Credential) { Write-Warning "No SSO account for $VCenter in the SDDC Manager vault (needs the ADMIN role). Asking instead." }
}
#endregion

if (-not $Credential) { $Credential = Get-Credential -Message "vCenter account for $VCenter" }

#region Reference time -----------------------------------------------------------------------
function Get-NtpClockOffset {
    # Simple SNTP query (RFC 4330). Returns how far the local clock is behind the server, as a TimeSpan:
    # reference time = local UTC time + offset.
    param([string]$Server, [int]$TimeoutMs = 3000)
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, 123)
        $request = [byte[]]::new(48)
        $request[0] = 0x1B                                   # LI 0, version 3, mode 3 (client)
        $t1 = [DateTime]::UtcNow
        [void]$udp.Send($request, $request.Length)
        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $answer = $udp.Receive([ref]$remote)
        $t4 = [DateTime]::UtcNow
    }
    finally { $udp.Dispose() }
    if ($answer.Length -lt 48) { throw "No valid NTP answer from $Server" }
    $ntpEpoch = [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $toDate = {
        param([int]$o)
        $sec = ([uint64]$answer[$o] -shl 24) -bor ([uint64]$answer[$o + 1] -shl 16) -bor ([uint64]$answer[$o + 2] -shl 8) -bor [uint64]$answer[$o + 3]
        $frac = ([uint64]$answer[$o + 4] -shl 24) -bor ([uint64]$answer[$o + 5] -shl 16) -bor ([uint64]$answer[$o + 6] -shl 8) -bor [uint64]$answer[$o + 7]
        $ntpEpoch.AddMilliseconds($sec * 1000.0 + $frac * 1000.0 / 4294967296.0)
    }
    $t2 = & $toDate 32                                     # server receive time
    $t3 = & $toDate 40                                     # server transmit time
    [TimeSpan]::FromTicks(((($t2 - $t1).Ticks) + (($t3 - $t4).Ticks)) / 2)
}

# Offsets of the local clock against NTP servers, asked once per server. $null = server did not answer.
$ntpOffsets = @{}
function Resolve-Reference {
    # Returns the reference for one host: @{ Name; Offset }. Order: -UseLocalClock, -ReferenceNtpServer,
    # the host's own NTP servers (first one that answers), the local clock.
    param([string[]]$HostNtpServers)
    if ($UseLocalClock) { return @{ Name = 'Local clock'; Offset = [TimeSpan]::Zero } }
    $candidates = if ($ReferenceNtpServer) { @($ReferenceNtpServer) } else { @($HostNtpServers) }
    foreach ($server in $candidates) {
        if (-not $ntpOffsets.ContainsKey($server)) {
            try {
                $ntpOffsets[$server] = Get-NtpClockOffset -Server $server
                Write-Host ("Local clock vs NTP {0}: {1:N3} s (corrected in the report)" -f $server, (-$ntpOffsets[$server].TotalSeconds)) -ForegroundColor Cyan
            }
            catch {
                $ntpOffsets[$server] = $null
                Write-Warning "NTP server $server did not answer from this machine ($($_.Exception.Message))."
            }
        }
        if ($null -ne $ntpOffsets[$server]) { return @{ Name = "NTP $server"; Offset = $ntpOffsets[$server] } }
    }
    @{ Name = 'Local clock'; Offset = [TimeSpan]::Zero }
}
if ($UseLocalClock) { Write-Host 'Reference: the local clock of this machine.' -ForegroundColor Cyan }
elseif ($ReferenceNtpServer) { Write-Host "Reference: NTP server $ReferenceNtpServer for every host." -ForegroundColor Cyan }
else { Write-Host 'Reference: per host, the first of its own NTP servers that answers from this machine (else the local clock).' -ForegroundColor Cyan }
#endregion

#region HTML report -----------------------------------------------------------------------------
function ConvertTo-HtmlText($Value) { [System.Net.WebUtility]::HtmlEncode("$Value") }
function Export-TimeHtmlReport($Report, [string]$Path, [System.Collections.IDictionary]$Info) {
    # One self-contained file (no external CSS, JS or fonts), so it can be mailed or archived as is.
    $e = { param($v) ConvertTo-HtmlText $v }
    $cls = @{ OK = 'ok'; Warning = 'warn'; Critical = 'bad'; Failed = 'bad'; Skipped = 'muted' }
    $order = @('Critical', 'Failed', 'Warning', 'Skipped', 'OK')
    $fmt = { param($v) if ($null -eq $v) { '' } else { ([double]$v).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture) } }
    $measured = @($Report | Where-Object { $null -ne $_.OffsetSeconds })
    $bandCount = @{ ok = @($measured | Where-Object OffsetLevel -eq 'OK').Count; warn = @($measured | Where-Object OffsetLevel -eq 'Warning').Count; bad = @($measured | Where-Object OffsetLevel -eq 'Critical').Count }
    $ntpIssues = @($Report | Where-Object { $_.Message -match 'NTP server|not running|policy|not found' }).Count
    $notMeasured = @($Report | Where-Object { $null -eq $_.OffsetSeconds }).Count

    $sb = [System.Text.StringBuilder]::new()
    $title = "ESXi host time - $($Info.Environment)"
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $e $title)</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1d2330;--muted:#5d6675;--line:#e2e5ea;--ok:#1a7f45;--okbg:#e3f4ea;--warn:#946200;--warnbg:#fdf1d6;--bad:#b42318;--badbg:#fde7e5;--mutedbg:#eef0f3;--accent:#1f5fbf}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1c2027;--text:#e6e8ec;--muted:#9aa3b2;--line:#2c323c;--ok:#5fd08f;--okbg:#173525;--warn:#f0c058;--warnbg:#3a2f12;--bad:#ff8a80;--badbg:#3d1c1a;--mutedbg:#262b33;--accent:#7fb0ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 "Segoe UI",system-ui,-apple-system,sans-serif}
main{max-width:1400px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 10px}
.meta{color:var(--muted);display:flex;flex-wrap:wrap;gap:4px 18px;margin-bottom:16px}.meta b{color:var(--text);font-weight:600}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.card[data-level]{cursor:pointer;user-select:none}.card.off{opacity:.35}
.card .n{font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}.card .l{color:var(--muted)}
.card.ok .n{color:var(--ok)}.card.warn .n{color:var(--warn)}.card.bad .n{color:var(--bad)}.card.muted .n{color:var(--muted)}
.stats{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px;margin-top:10px;display:flex;flex-wrap:wrap;gap:4px 24px;color:var(--muted)}.stats b{color:var(--text)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--muted);background:var(--mutedbg)}
tr:last-child td{border-bottom:0}.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
tr.cl td{background:var(--mutedbg);font-weight:600}
.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.badge.ok{background:var(--okbg);color:var(--ok)}.badge.warn{background:var(--warnbg);color:var(--warn)}.badge.bad{background:var(--badbg);color:var(--bad)}.badge.muted{background:var(--mutedbg);color:var(--muted)}
.off-ok{color:var(--ok);font-weight:600}.off-warn{color:var(--warn);font-weight:700}.off-bad{color:var(--bad);font-weight:700}
.small{color:var(--muted);font-size:12px}.mono{font-family:Consolas,ui-monospace,monospace;font-size:12px;white-space:nowrap}
.bar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:8px 0}.bar input{flex:1;min-width:220px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text)}
.scroll{overflow-x:auto}footer{color:var(--muted);font-size:12px;margin-top:32px}
@media print{.bar{display:none}}
</style></head><body><main>
<h1>ESXi host time</h1>
<div class="meta">
"@)
    foreach ($k in $Info.Keys) { if ($Info[$k]) { [void]$sb.Append("<span>$(& $e $k): <b>$(& $e $Info[$k])</b></span>") } }
    [void]$sb.Append('</div>')

    # Summary: offset bands (click to show or hide), NTP config issues, hosts not measured, statistics.
    $w = & $fmt $WarningOffsetSeconds; $c = & $fmt $CriticalOffsetSeconds
    $w = $w -replace '\.?0+$', ''; $c = $c -replace '\.?0+$', ''
    [void]$sb.Append('<h2>Summary</h2><div class="cards">')
    [void]$sb.Append("<div class=`"card ok`" data-level=`"OK`" title=`"Click to show or hide`"><div class=`"n`">$($bandCount.ok)</div><div class=`"l`">Offset &lt; $w s</div></div>")
    [void]$sb.Append("<div class=`"card warn`" data-level=`"Warning`" title=`"Click to show or hide`"><div class=`"n`">$($bandCount.warn)</div><div class=`"l`">Offset $w to $c s</div></div>")
    [void]$sb.Append("<div class=`"card bad`" data-level=`"Critical`" title=`"Click to show or hide`"><div class=`"n`">$($bandCount.bad)</div><div class=`"l`">Offset &gt; $c s</div></div>")
    [void]$sb.Append("<div class=`"card $(if ($ntpIssues) { 'warn' } else { 'ok' })`"><div class=`"n`">$ntpIssues</div><div class=`"l`">NTP config issues</div></div>")
    [void]$sb.Append("<div class=`"card $(if ($notMeasured) { 'bad' } else { 'muted' })`" data-level=`"None`" title=`"Click to show or hide`"><div class=`"n`">$notMeasured</div><div class=`"l`">Not measured (failed / skipped)</div></div>")
    [void]$sb.Append("<div class=`"card muted`"><div class=`"n`">$($Report.Count)</div><div class=`"l`">Hosts in total</div></div>")
    [void]$sb.Append('</div>')
    if ($measured) {
        $st = $measured | Measure-Object -Property OffsetSeconds -Minimum -Maximum -Average
        $worst = $measured | Sort-Object { [Math]::Abs($_.OffsetSeconds) } -Descending | Select-Object -First 1
        $refs = @($measured.Reference | Sort-Object -Unique) -join ', '
        [void]$sb.Append("<div class=`"stats`"><span>Largest offset: <b>$(& $e $worst.VMHost) ($(& $fmt $worst.OffsetSeconds) s)</b></span><span>Min: <b>$(& $fmt $st.Minimum) s</b></span><span>Max: <b>$(& $fmt $st.Maximum) s</b></span><span>Average: <b>$(& $fmt $st.Average) s</b></span><span>Compared with: <b>$(& $e $refs)</b></span></div>")
    }

    # Needs attention: every host that is not OK, worst first.
    $attention = @($Report | Where-Object Status -ne 'OK' | Sort-Object { [array]::IndexOf($order, $_.Status) }, { if ($null -ne $_.OffsetSeconds) { -1 * [Math]::Abs($_.OffsetSeconds) } else { 0 } }, VMHost)
    [void]$sb.Append("<h2>Needs attention ($($attention.Count))</h2>")
    if (-not $attention) { [void]$sb.Append("<p class=`"small`">Every host is within $w s of its reference and has NTP configured and running.</p>") }
    else {
        [void]$sb.Append('<div class="scroll"><table><tr><th>Status</th><th>Host</th><th>Cluster</th><th class="num">Offset (s)</th><th>Reason</th></tr>')
        foreach ($r in $attention) {
            $oc = if ($r.OffsetLevel) { "off-$($cls[$r.OffsetLevel])" } else { '' }
            [void]$sb.Append("<tr><td><span class=`"badge $($cls[$r.Status])`">$($r.Status)</span></td><td>$(& $e $r.VMHost)</td><td>$(& $e $r.Cluster)</td><td class=`"num $oc`">$(& $fmt $r.OffsetSeconds)</td><td class=`"small`">$(& $e $r.Message)</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }

    # All hosts, per cluster.
    [void]$sb.Append('<h2>All hosts</h2><div class="bar"><input id="q" type="search" placeholder="Filter: host, cluster, NTP server, status ..."></div>')
    [void]$sb.Append('<div class="scroll"><table><tr><th>Host</th><th class="num">Offset (s)</th><th>Host time (UTC)</th><th>Reference time (UTC)</th><th>Reference</th><th>Protocol</th><th>NTP servers</th><th>Service</th><th>Status</th></tr>')
    foreach ($g in ($Report | Group-Object Cluster | Sort-Object Name)) {
        [void]$sb.Append("<tr class=`"cl`"><td colspan=`"9`">$(& $e $(if ($g.Name) { $g.Name } else { '(no cluster)' })) <span class=`"small`">$($g.Count) host(s)</span></td></tr>")
        foreach ($r in $g.Group) {
            $level = if ($r.OffsetLevel) { $r.OffsetLevel } else { 'None' }
            $oc = if ($r.OffsetLevel) { "off-$($cls[$r.OffsetLevel])" } else { '' }
            $svc = if ($null -ne $r.NtpServiceRunning) { "$(if ($r.NtpServiceRunning) { 'Running' } else { 'Stopped' }), policy $(& $e $r.NtpServicePolicy)" } else { '' }
            $msg = if ($r.Message) { "<div class=`"small`">$(& $e $r.Message)</div>" } else { '' }
            $search = (& $e ("$($r.VMHost) $($r.Cluster) $($r.NtpServers) $($r.Reference) $($r.Status) $($r.Message)").ToLower())
            [void]$sb.Append("<tr data-level=`"$level`" data-search=`"$search`"><td>$(& $e $r.VMHost)</td><td class=`"num $oc`">$(& $fmt $r.OffsetSeconds)</td><td class=`"mono`">$(& $e $r.VMHostTimeUtc)</td><td class=`"mono`">$(& $e $r.ReferenceTimeUtc)</td><td class=`"small`">$(& $e $r.Reference)</td><td>$(& $e $r.TimeProtocol)</td><td class=`"small`">$(& $e $r.NtpServers)</td><td class=`"small`">$svc</td><td><span class=`"badge $($cls[$r.Status])`">$($r.Status)</span>$msg</td></tr>")
        }
    }
    [void]$sb.Append('</table></div>')
    [void]$sb.Append(@"
<footer>Generated by Get-EsxiTimeReport.ps1 (https://github.com/gertvangorp/PowerCLI). Offset = host time minus reference time; positive means the host is ahead.
For an NTP reference, the clock of the machine that ran the script was measured against that NTP server and corrected.</footer>
</main><script>
(function(){var off={},q=document.getElementById('q');
function apply(){var t=(q.value||'').toLowerCase();document.querySelectorAll('tr[data-search]').forEach(function(r){r.style.display=(!off[r.dataset.level]&&(!t||r.dataset.search.indexOf(t)>=0))?'':'none'});}
document.querySelectorAll('.card[data-level]').forEach(function(c){c.addEventListener('click',function(){var l=c.dataset.level;off[l]=!off[l];c.classList.toggle('off',off[l]);apply();});});
q.addEventListener('input',apply);})();
</script></body></html>
"@)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}
#endregion

$vi = $null
$report = [System.Collections.Generic.List[object]]::new()
try {
    Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $VCenter -Credential $Credential -NotDefault -WarningAction SilentlyContinue

    $hostFilter = @{ Server = $vi }
    if ($VMHost) { $hostFilter.Name = $VMHost }
    $esxHosts = if ($Cluster) { Get-Cluster -Server $vi -Name $Cluster | Get-VMHost @hostFilter } else { Get-VMHost @hostFilter }

    foreach ($esx in @($esxHosts | Sort-Object { "$($_.Parent)" }, Name)) {
        $row = [ordered]@{
            VMHost = $esx.Name; Cluster = "$($esx.Parent)"; VMHostTimeUtc = $null; ReferenceTimeUtc = $null; OffsetSeconds = $null
            OffsetLevel = $null; Reference = $null; TimeProtocol = $null; NtpServers = $null; NtpServiceRunning = $null; NtpServicePolicy = $null
            Status = 'OK'; Message = ''
        }
        if ("$($esx.ConnectionState)" -notin 'Connected', 'Maintenance') {
            $row.Status = 'Skipped'; $row.Message = "Host is $($esx.ConnectionState)"
            $report.Add([pscustomobject]$row); continue
        }
        try {
            $dateTimeSystem = Get-View -Server $vi -Id $esx.ExtensionData.ConfigManager.DateTimeSystem -Property dateTimeInfo
            $serviceSystem = Get-View -Server $vi -Id $esx.ExtensionData.ConfigManager.ServiceSystem -Property serviceInfo

            $info = $dateTimeSystem.DateTimeInfo
            # vSphere 7.0 U3 and later report "ntp" or "ptp"; older hosts leave it empty (= NTP).
            $protocol = if ($info.PSObject.Properties['Protocol'] -and $info.Protocol) { "$($info.Protocol)" } else { 'ntp' }
            $serviceKey = if ($protocol -eq 'ptp') { 'ptpd' } else { 'ntpd' }
            $service = $serviceSystem.ServiceInfo.Service | Where-Object { $_.Key -eq $serviceKey } | Select-Object -First 1
            $ntpServers = @($info.NtpConfig.Server | Where-Object { $_ })
            $ref = Resolve-Reference -HostNtpServers $ntpServers

            # Local time halfway the call, so the round trip to vCenter and the host is not counted as drift.
            $before = [DateTime]::UtcNow
            $hostTime = $dateTimeSystem.QueryDateTime()
            # The API returns UTC; only convert when PowerCLI hands it over as local time.
            $hostTime = if ($hostTime.Kind -eq [DateTimeKind]::Local) { $hostTime.ToUniversalTime() } else { [DateTime]::SpecifyKind($hostTime, [DateTimeKind]::Utc) }
            $after = [DateTime]::UtcNow
            $referenceTime = $before.AddTicks(($after - $before).Ticks / 2) + $ref.Offset


            $offset = [Math]::Round(($hostTime - $referenceTime).TotalSeconds, 3)
            $row.VMHostTimeUtc = $hostTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
            $row.ReferenceTimeUtc = $referenceTime.ToString('yyyy-MM-dd HH:mm:ss.fff')
            $row.OffsetSeconds = $offset
            $row.Reference = $ref.Name
            $row.TimeProtocol = $protocol.ToUpper()
            $row.NtpServers = $ntpServers -join ', '
            $row.NtpServiceRunning = [bool]$service.Running
            $row.NtpServicePolicy = "$($service.Policy)"

            $absOffset = [Math]::Abs($offset)
            $row.OffsetLevel = if ($absOffset -gt $CriticalOffsetSeconds) { 'Critical' } elseif ($absOffset -ge $WarningOffsetSeconds) { 'Warning' } else { 'OK' }
            $issues = @()
            if ($row.OffsetLevel -eq 'Critical') { $issues += "Offset $offset s is above $CriticalOffsetSeconds s" }
            elseif ($row.OffsetLevel -eq 'Warning') { $issues += "Offset $offset s is $WarningOffsetSeconds s or more" }
            if ($protocol -ne 'ptp' -and -not $ntpServers) { $issues += 'No NTP server configured' }
            if (-not $service) { $issues += "Service $serviceKey not found" }
            else {
                if (-not $service.Running) { $issues += "$serviceKey is not running" }
                if ($service.Policy -ne 'on') { $issues += "$serviceKey policy is '$($service.Policy)', not 'on'" }
            }
            $row.Status = if ($row.OffsetLevel -eq 'Critical') { 'Critical' } elseif ($issues) { 'Warning' } else { 'OK' }
            $row.Message = $issues -join '; '
        }
        catch {
            $row.Status = 'Failed'; $row.Message = $_.Exception.Message
            Write-Warning "$($esx.Name) : $($_.Exception.Message)"
        }
        $report.Add([pscustomobject]$row)
    }
}
finally {
    # Only this script's own session, not every vCenter connection in the PowerShell session.
    if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
}

# Summary
$measured = @($report | Where-Object { $null -ne $_.OffsetSeconds })
if ($measured) {
    $stats = $measured | Measure-Object -Property OffsetSeconds -Minimum -Maximum -Average
    $worst = $measured | Sort-Object { [Math]::Abs($_.OffsetSeconds) } -Descending | Select-Object -First 1
    Write-Host ("{0} host(s) measured ({1}). Offset min {2:N3} s, max {3:N3} s, average {4:N3} s. Largest: {5} ({6:N3} s)." -f `
            $measured.Count, (@($measured.Reference | Sort-Object -Unique) -join ', '), $stats.Minimum, $stats.Maximum, $stats.Average, $worst.VMHost, $worst.OffsetSeconds) -ForegroundColor Cyan
}
$notOk = @($report | Where-Object Status -ne 'OK')
if ($notOk) { Write-Warning "$($notOk.Count) host(s) need attention (Status Critical, Warning, Failed or Skipped)." }
elseif ($report.Count) { Write-Host "All hosts below $WarningOffsetSeconds s and NTP configured." -ForegroundColor Green }
else { Write-Warning 'No hosts found. Check -Cluster / -VMHost.' }

if ($CsvPath -and $report.Count) {
    $csvDir = Split-Path -Path $CsvPath -Parent
    if ($csvDir -and -not (Test-Path -LiteralPath $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -UseCulture -Force
    Write-Host "CSV: $CsvPath" -ForegroundColor Green
}
if ($HtmlPath -and $report.Count) {
    $info = [ordered]@{
        Environment = $EnvironmentName
        vCenter     = $VCenter
        Generated   = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Reference   = if ($UseLocalClock) { 'local clock' } elseif ($ReferenceNtpServer) { "NTP $ReferenceNtpServer" } else { "each host's own NTP server" }
        Thresholds  = "orange from $WarningOffsetSeconds s, red above $CriticalOffsetSeconds s"
        Hosts       = $report.Count
        Script      = "version $script:ScriptVersion"
    }
    Export-TimeHtmlReport $report $HtmlPath $info
    Write-Host "HTML: $HtmlPath" -ForegroundColor Green
}
$report
