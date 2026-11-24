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
    time protocol, configured NTP servers, ntpd running and its startup policy. A host gets
    Status "Warning" with the reason in Message when the offset is larger than -MaxOffsetSeconds,
    no NTP server is configured, ntpd is not running, or its policy is not "on". Hosts that are not
    connected or fail are reported too (Skipped / Failed), not silently left out.

    Results are written to the pipeline as objects, sorted by cluster and host. With -CsvPath they
    are also exported to CSV. A short summary (min, max, average offset, warnings) is printed at the end.

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

.PARAMETER MaxOffsetSeconds
    Offset (absolute, in seconds) above which a host gets Status "Warning". Default 1. Config: MaxOffsetSeconds.

.PARAMETER ReferenceNtpServer
    One NTP server used as the reference for every host, instead of each host's own NTP servers
    (needs UDP 123 from this machine). Config: ReferenceNtpServer.

.PARAMETER UseLocalClock
    Compare with the clock of this machine instead of NTP. Config: UseLocalClock.

.PARAMETER CsvPath
    Optional CSV export path. "{date}" is replaced with yyyyMMdd-HHmm, "{env}" with the environment
    name. Config: CsvPath.

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
    .\Get-EsxiTimeReport.ps1 -Environment lab1 -UseSddcCredentials -CsvPath C:\Reports\{env}-time-{date}.csv

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
                     -Cluster / -VMHost filters, signed offset with -MaxOffsetSeconds and Status,
                     reference = the host's own NTP server, -ReferenceNtpServer or -UseLocalClock (SNTP)
                     instead of the retired earthtools.org web service,
                     ntpd policy, disconnects only its own vCenter session.
    1.0  2025-10-13  First version (Report-HostTime2NTP.ps1).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-EsxiTimeReport
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$Cluster,
    [string[]]$VMHost,
    [double]$MaxOffsetSeconds = 1,
    [string]$ReferenceNtpServer,
    [switch]$UseLocalClock,
    [string]$CsvPath,
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
$ConfigSettings = @{ VCenter = 'first'; Cluster = 'list'; VMHost = 'list'; MaxOffsetSeconds = 'string'; ReferenceNtpServer = 'string'; UseLocalClock = 'switch'; CsvPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
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
$MaxOffsetSeconds = [double]::Parse("$MaxOffsetSeconds", [Globalization.CultureInfo]::InvariantCulture)

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
            Reference = $null; TimeProtocol = $null; NtpServers = $null; NtpServiceRunning = $null; NtpServicePolicy = $null
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

            $issues = @()
            if ([Math]::Abs($offset) -gt $MaxOffsetSeconds) { $issues += "Offset $offset s is above $MaxOffsetSeconds s" }
            if ($protocol -ne 'ptp' -and -not $ntpServers) { $issues += 'No NTP server configured' }
            if (-not $service) { $issues += "Service $serviceKey not found" }
            else {
                if (-not $service.Running) { $issues += "$serviceKey is not running" }
                if ($service.Policy -ne 'on') { $issues += "$serviceKey policy is '$($service.Policy)', not 'on'" }
            }
            if ($issues) { $row.Status = 'Warning'; $row.Message = $issues -join '; ' }
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
if ($notOk) { Write-Warning "$($notOk.Count) host(s) need attention (Status Warning, Failed or Skipped)." }
elseif ($report.Count) { Write-Host "All hosts within $MaxOffsetSeconds s and NTP configured." -ForegroundColor Green }
else { Write-Warning 'No hosts found. Check -Cluster / -VMHost.' }

if ($CsvPath -and $report.Count) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -UseCulture -Force
    Write-Host "Report written to $CsvPath" -ForegroundColor Cyan
}
$report
