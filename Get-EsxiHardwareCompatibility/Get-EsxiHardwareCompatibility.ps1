#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the hardware of every ESXi host against the Broadcom Compatibility Guide: server model,
    CPU, network and storage PCI devices, and (for vSAN) storage controllers and disks, optionally
    for a target ESXi version range (for example 9.0 to 9.1.1).

.DESCRIPTION
    Connects to vCenter, reads the hardware of every host and looks each component up in the
    Broadcom Compatibility Guide (https://compatibilityguide.broadcom.com). One row per component
    per host; the Component column says what was checked:

      Server          Server model (vendor + model from the host) in "Systems / Servers". When the
                      CPU was found, only the entries of the model with that CPU series are used.
      CPU             CPU series in "CPU Series", matched on the exact CPUID signature (family,
                      model and stepping) that the host reports.
      PCI             Every PCI device whose class matches -DeviceClass (default: network and storage
                      controllers, including NVMe) in "IO Devices", matched on vendor, device,
                      subvendor and subdevice ID.
      vSAN controller Storage controllers in "vSAN I/O Controller" (vSAN hosts only, see -VsanCheck).
      vSAN NVMe       NVMe drives in "vSAN SSD", matched on their PCI IDs (vSAN hosts only).
      vSAN disk       Local SAS/SATA disks in "vSAN SSD" or "vSAN HDD", matched on the model
                      number (vSAN hosts only).

    PCI lookups first match all four IDs; when that finds nothing they retry without the subdevice
    ID and HclMatch says WithoutSSID (check the model on the linked page).

    Without a version range, each row lists the ESXi releases the guide supports. With
    -MinEsxiVersion and/or -MaxEsxiVersion, each row also gets a Status for that range:
      Supported      listed for every ESXi release in the range
      Partial        listed for some releases in the range; MissingReleases says which
      NotSupported   in the guide, but for no release in the range
      NotFound       no matching entry in the guide
      NotApplicable  virtual hardware (nested ESXi, VMware virtual devices): not in the guide
      LookupFailed   the guide could not be reached (see Message)
    Without a range, Status is Found instead of Supported/Partial/NotSupported.

    "Every release in the range" means every release in that range that the guide lists for at
    least one component in this report; the guide has no separate list of releases. If the lowest
    or highest version of the range is listed for nothing, the script warns. Releases are compared
    as numbers: "ESXi 8.0 U3" counts as 8.0.3, and the vSAN lists' "ESXi 9.0 (vSAN 9.0)" as 9.0.

    Every unique component is looked up once and the result is reused for every host. At the end
    the script prints a summary per component type and status. Results go to the pipeline; with
    -CsvPath also to CSV (with the list separator of your Windows region, for Excel), with
    -HtmlPath also to a self-contained HTML report.

    The script only reads. It changes nothing in vCenter or on the hosts. The Compatibility Guide
    API is not an official, documented API: Broadcom can change it. The guide stays the source of
    truth; check driver and firmware versions on the linked pages before an upgrade.

    Credentials (vCenter SSO account), in this order:
      -Credential, or VcUser / VcCredentialFile in the config file,
      -UseSddcCredentials: the vCenter SSO account is read from the SDDC Manager vault
                           (GET /v1/credentials, needs the SDDC Manager ADMIN role),
      otherwise Get-Credential asks.

.PARAMETER VCenter
    vCenter FQDN. Config: VCenter.

.PARAMETER Cluster
    One or more cluster names. Leave empty for all hosts in vCenter. Config: Cluster.

.PARAMETER MinEsxiVersion
    Lowest ESXi release of the target range, for example 9.0. Config: MinEsxiVersion.

.PARAMETER MaxEsxiVersion
    Highest ESXi release of the target range, for example 9.1.1. Config: MaxEsxiVersion.

.PARAMETER Component
    Which components to check: Server, CPU, PCI, Vsan. Default: all. Config: Component.

.PARAMETER DeviceClass
    Regular expressions matched against the PCI device class name. Default: network (Ethernet,
    Network, Fibre Channel, InfiniBand) and storage (Mass storage, RAID, SCSI, SAS, SATA,
    Non-Volatile memory) controllers. Config: DeviceClass.

.PARAMETER VsanCheck
    Auto (default): vSAN checks only for hosts in a cluster with vSAN enabled. Always: for every
    host. Never: no vSAN checks. Config: VsanCheck.

.PARAMETER SkipHclLookup
    Only inventory the hardware; do not query the Compatibility Guide. Config: SkipHclLookup.

.PARAMETER CsvPath
    Optional CSV export path; the folder is created when needed. "{date}" is replaced with
    yyyyMMdd-HHmm, "{env}" with the environment name. Config: CsvPath.

.PARAMETER HtmlPath
    Optional HTML report: one self-contained file with a summary, a component/status matrix and one
    section per host, with status colours, links to the guide and a filter box. The folder is
    created when needed. "{date}" and "{env}" as for -CsvPath. Config: HtmlPath.

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
    # Is all hardware supported on ESXi 9.0 up to 9.1.1?
    .\Get-EsxiHardwareCompatibility.ps1 -VCenter vc01.corp.local -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 |
        Format-Table VMHost, Component, Name, Status, MissingReleases

.EXAMPLE
    # Environment config (config\lab1.config.json), vCenter password from the SDDC Manager vault, CSV export
    .\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -UseSddcCredentials -CsvPath '%USERPROFILE%\Reports\{env}-hardware-{date}.csv'

.EXAMPLE
    # HTML report to open in a browser or mail around
    .\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 -HtmlPath '%USERPROFILE%\Reports\{env}-hardware-{date}.html'

.EXAMPLE
    # Only what is not fully supported, one line per unique component
    $r = .\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1
    $r | Where-Object Status -ne 'Supported' | Sort-Object Component, Name, VID, DID, SVID, SSID -Unique |
        Format-Table Component, Name, Status, MissingReleases, CompatibilityGuideUrl

.NOTES
    Name        : Get-EsxiHardwareCompatibility.ps1
    Version     : 2.0
    Date        : 2026-11-23
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : PowerShell 7 or Windows PowerShell 5.1, VCF.PowerCLI (or VMware.PowerCLI),
                  internet access to compatibilityguide.broadcom.com.
    Config      : one file per environment, see config\environment.config.sample.json
    Credits     : Compatibility Guide queries based on Check-BroadcomCompatIoDevice and
                  Check-BroadcomCompatVsanSsdDevice by William Lam (https://williamlam.com).
    License     : provided as is, without warranty. Test in a lab first.

    Version history
    2.0  2026-11-23  Rewrite (was Report-PCIDevices.ps1): environment config, standard header, ESXi
                     version range with Status, server/CPU/vSAN checks, storage controllers by default,
                     subdevice ID filter fixed (maxSsid), IDs zero-padded, lookup cache, CSV and HTML report.
    1.0  2025-10-17  First version (Report-PCIDevices.ps1): NICs and FC HBAs only.

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-EsxiHardwareCompatibility
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$Cluster,
    [string]$MinEsxiVersion,
    [string]$MaxEsxiVersion,
    [ValidateSet('Server', 'CPU', 'PCI', 'Vsan')]
    [string[]]$Component = @('Server', 'CPU', 'PCI', 'Vsan'),
    [string[]]$DeviceClass = @('Ethernet', 'Network', 'Fibre', 'InfiniBand', 'Mass storage', 'RAID', 'SCSI', 'Serial Attached', 'SATA', 'Non-Volatile memory'),
    [ValidateSet('Auto', 'Always', 'Never')]
    [string]$VsanCheck = 'Auto',
    [switch]$SkipHclLookup,
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
$script:ScriptVersion = '2.0 (2026-11-23)'
Write-Host "Get-EsxiHardwareCompatibility.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'HardwareCompatibility'
$ConfigSettings = @{ VCenter = 'first'; Cluster = 'list'; MinEsxiVersion = 'string'; MaxEsxiVersion = 'string'; Component = 'list'; DeviceClass = 'list'; VsanCheck = 'string'; SkipHclLookup = 'switch'; CsvPath = 'string'; HtmlPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
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

#region Compatibility Guide ------------------------------------------------------------------
# Warnings also go into the HTML report.
$script:notes = [System.Collections.Generic.List[string]]::new()
function Add-Note([string]$Text) { Write-Warning $Text; $script:notes.Add($Text) }
# The guide's web front end calls these endpoints; they are not an official, documented API.
$BcgBase = 'https://compatibilityguide.broadcom.com'

function ConvertTo-EsxiVersion([string]$Text) {
    # "9.0" -> 9.0.0, "9.1.1" -> 9.1.1, "ESXi 8.0 U3" -> 8.0.3, "ESXi 9.0 (vSAN 9.0)" -> 9.0.0. $null when there is no version.
    if ($Text -notmatch '(\d+)\.(\d+)(?:\.(\d+))?(?:\s*(?:U|Update\s*)(\d+))?') { return $null }
    $third = if ($Matches[3]) { $Matches[3] } elseif ($Matches[4]) { $Matches[4] } else { '0' }
    [version]::new([int]$Matches[1], [int]$Matches[2], [int]$third)
}
function Get-ReleaseLabel([version]$Version) {
    # One spelling for every list: "ESXi 8.0 U3", "ESXi 9.0", "ESXi 9.0.1".
    if ($Version.Build -le 0) { "ESXi $($Version.Major).$($Version.Minor)" }
    elseif ($Version.Major -ge 9) { "ESXi $($Version.Major).$($Version.Minor).$($Version.Build)" }
    else { "ESXi $($Version.Major).$($Version.Minor) U$($Version.Build)" }
}
function ConvertTo-ReleaseList($SupportedReleases) {
    # The programs return the releases as strings or as objects with .name. Returns labels, newest first.
    $versions = foreach ($r in @($SupportedReleases)) {
        $name = if ($r -is [string]) { $r } else { "$($r.name)" }
        $v = ConvertTo-EsxiVersion $name
        if ($v) { $v }
    }
    @($versions | Sort-Object -Unique -Descending | ForEach-Object { Get-ReleaseLabel $_ })
}
function Format-PciId($Value) {
    # esxcli returns the IDs as decimal numbers (sometimes as 0x... hex); the guide wants 4 lowercase hex digits.
    $s = "$Value".Trim()
    $n = if ($s -match '^0x([0-9a-f]+)$') { [Convert]::ToInt32($Matches[1], 16) } else { [int]$s }
    '{0:x4}' -f $n
}
function Invoke-Bcg([string]$Program, [System.Collections.IDictionary]$Filter, [string]$Keyword, [int]$Limit = 50, [int]$Page = 1) {
    # POST /compguide/programs/viewResults. $Filter: displayKey = value. Returns .data (count, fieldValues).
    $filters = @(foreach ($k in $Filter.Keys) { @{ displayKey = $k; filterValues = @($Filter[$k]) } })
    $body = [ordered]@{ programId = $Program; filters = $filters; keyword = @($Keyword | Where-Object { $_ }); date = @{ startDate = $null; endDate = $null } } | ConvertTo-Json -Depth 5
    $uri = "$BcgBase/compguide/programs/viewResults?limit=$Limit&page=$Page&sortBy=&sortType=ASC"
    (Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Headers @{ 'user-persona' = 'live' } -Body $body).data
}
function New-Lookup([string]$Program) {
    [pscustomobject]@{ Program = $Program; Match = 'None'; Brand = ''; Model = ''; Names = @(); Releases = @(); Url = ''; Error = ''; Note = '' }
}
function Set-LookupResult($Lookup, $Entries, [string]$Match) {
    # Several entries (models, capacities) can match: the component is supported on the union of their releases.
    $Lookup.Match = $Match
    $Lookup.Brand = (@($Entries | ForEach-Object { if ($_.brandName) { $_.brandName } else { $_.partnerName } } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
    # Model name (IO, server, disks) or CPU series name (CPU program).
    $Lookup.Names = @($Entries | ForEach-Object { if ($_.model) { $_.model.name } else { $_.cpuSeries.name } } | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $Lookup.Model = $Lookup.Names -join ' | '
    $Lookup.Releases = ConvertTo-ReleaseList @($Entries | ForEach-Object { $_.supportedReleases })
    if (@($Entries).Count -eq 1) {
        $u = @($Entries)[0].model.url; if (-not $u) { $u = @($Entries)[0].cpuSeries.url }
        if ($u) { $Lookup.Url = "$BcgBase/detail$(@($u)[0])&persona=live" }
    }
}
function Get-Cached([string]$Key, [scriptblock]$Find) {
    # Every unique component is looked up once; failures are cached too, so a dead link fails fast.
    if ($hclCache.ContainsKey($Key)) { return $hclCache[$Key] }
    $lookup = New-Lookup ($Key -split '\|')[0]
    try { & $Find $lookup }
    catch { $lookup.Error = $_.Exception.Message; Add-Note "Compatibility Guide lookup $Key failed: $($lookup.Error)" }
    $hclCache[$Key] = $lookup
    $lookup
}
function Find-PciDevice([string]$Program, [string]$SsidKey, $Ids) {
    # IO Devices uses "maxSsid" for the subdevice ID, the vSAN programs use "ssid" (a wrong key is silently ignored).
    Get-Cached "$Program|$($Ids.VID)|$($Ids.DID)|$($Ids.SVID)|$($Ids.SSID)" {
        param($l)
        $f = [ordered]@{ vid = $Ids.VID; did = $Ids.DID; svid = $Ids.SVID }
        $search = "vid=%5B$($Ids.VID)%5D&did=%5B$($Ids.DID)%5D&svid=%5B$($Ids.SVID)%5D"
        $f[$SsidKey] = $Ids.SSID
        $d = Invoke-Bcg $Program $f -Limit 100
        if ($d.count -gt 0) { Set-LookupResult $l $d.fieldValues 'Exact'; $search += "&$SsidKey=%5B$($Ids.SSID)%5D" }
        else {
            # Many entries leave the subdevice ID empty (any): try again without it.
            $f.Remove($SsidKey)
            $d = Invoke-Bcg $Program $f -Limit 100
            if ($d.count -gt 0) { Set-LookupResult $l $d.fieldValues 'WithoutSSID'; $l.Note = 'Matched on VID/DID/SVID only: check the model on the guide page' }
        }
        if (-not $l.Url) { $l.Url = "$BcgBase/search?program=$Program&persona=live&$search" }
    }
}
function Get-CpuList {
    # The whole CPU Series list is about 100 entries: read it once.
    if ($null -ne $script:cpuList) { return $script:cpuList }
    $all = [System.Collections.Generic.List[object]]::new(); $page = 1
    do {
        $d = Invoke-Bcg 'cpu' @{} -Limit 200 -Page $page
        foreach ($x in @($d.fieldValues)) { if ($x) { $all.Add($x) } }
        $page++
    } while ($all.Count -lt $d.count -and @($d.fieldValues).Count -gt 0)
    $script:cpuList = $all
    $all
}
function Find-Cpu([string]$CpuId, [string]$ProcessorType) {
    Get-Cached "cpu|$CpuId|$ProcessorType" {
        param($l)
        $hits = @(Get-CpuList | Where-Object { @("$($_.cpuids)" -split '[,\s]+' | Where-Object { $_ }) -contains $CpuId })
        if ($hits.Count -gt 1) {
            # Several series share one CPUID (Gold 6300 and Platinum 8300 are both Ice Lake). Narrow down on the
            # model number: Intel Xeon Gold 6338 -> "6300", AMD EPYC 7543 -> "7003", EPYC 9654 -> "9004".
            $token = $null
            if ($ProcessorType -match 'EPYC\s+(\d)\d\d(\d)') { $token = "$($Matches[1])00$($Matches[2])" }
            elseif ($ProcessorType -match 'Xeon.*?\b(?:Platinum|Gold|Silver|Bronze)\s+(\d)(\d)\d\d') { $token = "$($Matches[1])$($Matches[2])00" }
            $narrow = @($hits | Where-Object { $token -and "$($_.cpuSeries.name)" -match "\b$token\b" })
            if ($narrow) { $hits = $narrow } else { $l.Note = "CPUID $CpuId matches $($hits.Count) CPU series: check which one on the guide page" }
        }
        if ($hits) { Set-LookupResult $l $hits 'CPUID' }
        $l.Url = if ($hits.Count -eq 1) { $l.Url } else { "$BcgBase/search?program=cpu&persona=live" }
    }
}
function Find-Server([string]$Model, [string[]]$CpuSeries) {
    Get-Cached "server|$Model|$($CpuSeries -join ',')" {
        param($l)
        $d = Invoke-Bcg 'server' @{} -Keyword $Model -Limit 200
        $hits = @($d.fieldValues | Where-Object { $_ -and @($_.model.name) -contains $Model })
        if ($hits -and $CpuSeries) {
            $want = @($CpuSeries | ForEach-Object { "$_".Trim() })
            $withCpu = @($hits | Where-Object { @($_.cpuSeries.name | Where-Object { "$_".Trim() -in $want }).Count -gt 0 })
            if ($withCpu) { $hits = $withCpu } else { $l.Note = 'Model found, but not with this CPU series: check the guide page' }
        }
        elseif ($hits) { $l.Note = 'CPU series unknown: releases of all CPU options of this model' }
        if ($hits) { Set-LookupResult $l $hits 'Model' }
        if (-not $l.Url) { $l.Url = "$BcgBase/search?program=server&persona=live&keyword=$([uri]::EscapeDataString($Model))" }
    }
}
function Find-VsanDisk([string]$Program, [string]$Model) {
    Get-Cached "$Program|$Model" {
        param($l)
        # The guide's model names are longer ("Samsung ... MZILT960HBHQ-00007 (960GB)") and ESXi often reports
        # an OEM suffix ("MZILT960HBHQ0D3"): search the full model number, then without its last 3 characters.
        $candidates = @($Model) + $(if ($Model.Length -ge 10) { $Model.Substring(0, $Model.Length - 3) } else { @() })
        foreach ($kw in $candidates) {
            $d = Invoke-Bcg $Program @{} -Keyword $kw -Limit 100
            $key = $kw -replace '[^A-Za-z0-9]', ''
            $hits = @($d.fieldValues | Where-Object { $_ -and ((@($_.model.name) -join ' ') -replace '[^A-Za-z0-9]', '') -like "*$key*" })
            if ($hits) {
                if ($kw -ne $Model) { $l.Note = "Matched on '$kw' (model number without its last 3 characters): check the model on the guide page" }
                Set-LookupResult $l $hits $(if ($kw -eq $Model) { 'Model' } else { 'Keyword' })
                break
            }
        }
        if (-not $l.Url) { $l.Url = "$BcgBase/search?program=$Program&persona=live&keyword=$([uri]::EscapeDataString($Model))" }
    }
}
function Get-HostCpuId($VMHost) {
    # CPUID leaf 1 EAX (family/model/stepping), formatted like the guide: 0x000606A6. Type and reserved bits masked.
    $eax = @($VMHost.ExtensionData.Hardware.CpuFeature | Where-Object { $_.Level -eq 1 })[0].Eax
    if (-not $eax) { return $null }
    $n = [Convert]::ToUInt32(($eax -replace '[^01]', ''), 2) -band 0x0FFF3FFF
    '0x{0:X8}' -f $n
}
function Test-InRange([string]$Release) {
    $v = ConvertTo-EsxiVersion $Release
    $null -ne $v -and (-not $minVer -or $v -ge $minVer) -and (-not $maxVer -or $v -le $maxVer)
}
#endregion

#region HTML report -----------------------------------------------------------------------------
function ConvertTo-HtmlText($Value) { [System.Net.WebUtility]::HtmlEncode("$Value") }
function Export-HtmlReport($Report, [string]$Path, [System.Collections.IDictionary]$Info, [string[]]$Notes) {
    # One self-contained file (no external CSS, JS or fonts), so it can be mailed or archived as is.
    $order = @('NotSupported', 'NotFound', 'LookupFailed', 'Failed', 'Partial', 'Skipped', 'NotChecked', 'Found', 'Supported', 'NotApplicable')
    $cls = @{ Supported = 'ok'; Found = 'ok'; Partial = 'warn'; NotSupported = 'bad'; NotFound = 'bad'; LookupFailed = 'bad'; Failed = 'bad'; Skipped = 'muted'; NotChecked = 'muted'; NotApplicable = 'muted' }
    $e = { param($v) ConvertTo-HtmlText $v }
    $sb = [System.Text.StringBuilder]::new()
    $title = "ESXi hardware compatibility - $($Info.Environment)"
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
.notes{background:var(--warnbg);color:var(--warn);border-radius:8px;padding:10px 14px;margin:12px 0}.notes li{margin:2px 0}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;cursor:pointer;user-select:none}
.card .n{font-size:26px;font-weight:700}.card .l{color:var(--muted)}.card.off{opacity:.35}
.card.ok .n{color:var(--ok)}.card.warn .n{color:var(--warn)}.card.bad .n{color:var(--bad)}.card.muted .n{color:var(--muted)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--muted);background:var(--mutedbg)}
tr:last-child td{border-bottom:0}.num{text-align:center;font-variant-numeric:tabular-nums}
.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.badge.ok{background:var(--okbg);color:var(--ok)}.badge.warn{background:var(--warnbg);color:var(--warn)}.badge.bad{background:var(--badbg);color:var(--bad)}.badge.muted{background:var(--mutedbg);color:var(--muted)}
.ids{font-family:Consolas,ui-monospace,monospace;font-size:12px;white-space:nowrap}.small{color:var(--muted);font-size:12px}
a{color:var(--accent)}details{margin:10px 0}summary{cursor:pointer;padding:10px 14px;background:var(--card);border:1px solid var(--line);border-radius:10px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
details[open] summary{border-radius:10px 10px 0 0;border-bottom:0}details table{border-radius:0 0 10px 10px}summary .h{font-weight:600}summary .s{color:var(--muted)}
.bar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:8px 0}.bar input{flex:1;min-width:220px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text)}
.bar button{padding:7px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);cursor:pointer}
.scroll{overflow-x:auto}footer{color:var(--muted);font-size:12px;margin-top:32px}
@media print{.bar,.cards{display:none}details{break-inside:avoid}}
</style></head><body><main>
<h1>ESXi hardware compatibility</h1>
<div class="meta">
"@)
    foreach ($k in $Info.Keys) { if ($k -ne 'Environment' -or $Info[$k]) { [void]$sb.Append("<span>$(& $e $k): <b>$(& $e $Info[$k])</b></span>") } }
    [void]$sb.Append('</div>')
    if ($Notes) { [void]$sb.Append('<ul class="notes">'); foreach ($n in $Notes) { [void]$sb.Append("<li>$(& $e $n)</li>") }; [void]$sb.Append('</ul>') }

    # Summary cards (click to show/hide a status) and a component x status matrix.
    $statuses = @($order | Where-Object { $_ -in @($Report.Status) })
    [void]$sb.Append('<h2>Summary</h2><div class="cards">')
    foreach ($s in $statuses) {
        $n = @($Report | Where-Object Status -eq $s).Count
        [void]$sb.Append("<div class=`"card $($cls[$s])`" data-status=`"$s`" title=`"Click to show or hide`"><div class=`"n`">$n</div><div class=`"l`">$s</div></div>")
    }
    [void]$sb.Append('</div><h2>Per component</h2><div class="scroll"><table><tr><th>Component</th>')
    foreach ($s in $statuses) { [void]$sb.Append("<th class=`"num`">$s</th>") }
    [void]$sb.Append('</tr>')
    foreach ($c in @($Report.Component | Select-Object -Unique)) {
        [void]$sb.Append("<tr><td>$(& $e $c)</td>")
        foreach ($s in $statuses) {
            $n = @($Report | Where-Object { $_.Component -eq $c -and $_.Status -eq $s }).Count
            [void]$sb.Append($(if ($n) { "<td class=`"num`"><span class=`"badge $($cls[$s])`">$n</span></td>" } else { '<td class="num small">-</td>' }))
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table></div>')

    # One collapsible section per host; hosts with problems are open.
    [void]$sb.Append('<h2>Hosts</h2><div class="bar"><input id="q" type="search" placeholder="Filter: host, device, ID, driver, release ..."><button id="all">Expand all</button><button id="none">Collapse all</button></div>')
    foreach ($h in ($Report | Group-Object VMHost | Sort-Object Name)) {
        $rowsH = @($h.Group)
        $worst = @($order | Where-Object { $_ -in @($rowsH.Status) })[0]
        $open = if ($cls[$worst] -in 'bad', 'warn') { ' open' } else { '' }
        $f = $rowsH[0]
        [void]$sb.Append("<details$open><summary><span class=`"h`">$(& $e $h.Name)</span><span class=`"s`">$(& $e $f.Cluster) &middot; ESXi $(& $e $f.EsxiVersion)</span><span class=`"badge $($cls[$worst])`">$worst</span></summary>")
        [void]$sb.Append('<div class="scroll"><table><tr><th>Component</th><th>Name</th><th>Detail</th><th>IDs / driver</th><th>Status</th><th>In range</th><th>Missing</th><th>Guide</th></tr>')
        foreach ($r in $rowsH) {
            $ids = if ($r.VID) { "<span class=`"ids`">$($r.VID):$($r.DID):$($r.SVID):$($r.SSID)</span>" } else { '' }
            if ($r.Driver) { $ids += "<div class=`"small`">$(& $e $r.Driver)</div>" }
            $guide = if ($r.CompatibilityGuideUrl) { "<a href=`"$(& $e $r.CompatibilityGuideUrl)`" target=`"_blank`" rel=`"noopener`">open</a>" } else { '' }
            if ($r.HclModel) { $guide += "<div class=`"small`">$(& $e $r.HclModel)</div>" }
            $msg = if ($r.Message) { "<div class=`"small`">$(& $e $r.Message)</div>" } else { '' }
            $search = (& $e ("$($r.VMHost) $($r.Component) $($r.Name) $($r.Detail) $($r.Driver) $($r.VID) $($r.DID) $($r.SVID) $($r.SSID) $($r.HclModel) $($r.Status) $($r.SupportedReleases)").ToLower())
            [void]$sb.Append("<tr data-status=`"$($r.Status)`" data-search=`"$search`"><td>$(& $e $r.Component)</td><td>$(& $e $r.Name)$msg</td><td class=`"small`">$(& $e $r.Detail)</td><td>$ids</td><td><span class=`"badge $($cls[$r.Status])`">$(& $e $r.Status)</span></td><td class=`"small`">$(& $e $r.ReleasesInRange)</td><td class=`"small`">$(& $e $r.MissingReleases)</td><td>$guide</td></tr>")
        }
        [void]$sb.Append('</table></div></details>')
    }
    [void]$sb.Append(@"
<footer>Generated by Get-EsxiHardwareCompatibility.ps1 (https://github.com/gertvangorp/PowerCLI) from the Broadcom Compatibility Guide.
The guide is the source of truth: check driver and firmware versions on the linked pages before an upgrade.
Releases checked are the releases in the range that the guide lists for at least one component in this report.</footer>
</main><script>
(function(){var off={},q=document.getElementById('q');
function apply(){var t=(q.value||'').toLowerCase();document.querySelectorAll('tr[data-search]').forEach(function(r){r.style.display=(!off[r.dataset.status]&&(!t||r.dataset.search.indexOf(t)>=0))?'':'none'});
document.querySelectorAll('details').forEach(function(d){var v=d.querySelectorAll('tr[data-search]:not([style*="none"])').length;d.style.display=v?'':'none';if(t&&v)d.open=true})}
document.querySelectorAll('.card').forEach(function(c){c.addEventListener('click',function(){var s=c.dataset.status;off[s]=!off[s];c.classList.toggle('off',off[s]);apply()})});
q.addEventListener('input',apply);
document.getElementById('all').onclick=function(){document.querySelectorAll('details').forEach(function(d){d.open=true})};
document.getElementById('none').onclick=function(){document.querySelectorAll('details').forEach(function(d){d.open=false})};})();
</script></body></html>
"@)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}
#endregion

$minVer = $null; $maxVer = $null
if ($MinEsxiVersion) { $minVer = ConvertTo-EsxiVersion $MinEsxiVersion; if (-not $minVer) { throw "MinEsxiVersion '$MinEsxiVersion' is not a version (use for example 9.0)." } }
if ($MaxEsxiVersion) { $maxVer = ConvertTo-EsxiVersion $MaxEsxiVersion; if (-not $maxVer) { throw "MaxEsxiVersion '$MaxEsxiVersion' is not a version (use for example 9.1.1)." } }
if ($minVer -and $maxVer -and $minVer -gt $maxVer) { throw "MinEsxiVersion ($MinEsxiVersion) is higher than MaxEsxiVersion ($MaxEsxiVersion)." }
$hasRange = [bool]($minVer -or $maxVer)
if ($hasRange) { Write-Host "Target ESXi range: $(if ($minVer) { Get-ReleaseLabel $minVer } else { 'any' }) to $(if ($maxVer) { Get-ReleaseLabel $maxVer } else { 'any' })" -ForegroundColor Cyan }
if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
$classPattern = ($DeviceClass | Where-Object { $_ }) -join '|'
$storagePattern = 'Mass storage|RAID|SCSI|Serial Attached|SATA|Non-Volatile memory'
Write-Host "Components: $($Component -join ', '). PCI classes: $classPattern. vSAN checks: $VsanCheck" -ForegroundColor Cyan

$hclCache = @{}
$script:cpuList = $null
$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row([System.Collections.IDictionary]$HostInfo, [string]$Type, [System.Collections.IDictionary]$Data, $Lookup) {
    $o = [ordered]@{}
    foreach ($kv in $HostInfo.GetEnumerator()) { $o[$kv.Key] = $kv.Value }
    $o.Component = $Type
    foreach ($k in 'Name', 'Detail', 'Driver', 'VID', 'DID', 'SVID', 'SSID', 'Status', 'Message') { $o[$k] = '' }
    foreach ($kv in $Data.GetEnumerator()) { $o[$kv.Key] = $kv.Value }
    $rows.Add([pscustomobject]@{ Row = $o; Lookup = $Lookup })
}

$vi = $null
try {
    Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $VCenter -Credential $Credential -NotDefault -WarningAction SilentlyContinue

    $esxHosts = if ($Cluster) { Get-Cluster -Server $vi -Name $Cluster | Get-VMHost -Server $vi } else { Get-VMHost -Server $vi }
    $vsanClusters = @{}
    foreach ($esx in @($esxHosts | Sort-Object Name)) {
        $hostInfo = [ordered]@{ Cluster = "$($esx.Parent)"; VMHost = $esx.Name; EsxiVersion = "$($esx.Version) ($($esx.Build))" }
        if ("$($esx.ConnectionState)" -notin 'Connected', 'Maintenance') {
            Add-Note "$($esx.Name) skipped: host is $($esx.ConnectionState) in vCenter"
            Add-Row $hostInfo 'Host' @{ Name = "$($esx.Manufacturer) $($esx.Model)"; Status = 'Skipped'; Message = "Host is $($esx.ConnectionState)" } $null
            continue
        }
        Write-Host "  $($esx.Name)" -ForegroundColor Green
        $isVirtual = "$($esx.Manufacturer) $($esx.Model)" -match 'VMware'
        $virtualNote = 'Virtual hardware (nested ESXi): not in the Compatibility Guide'
        try {
            # --- CPU ------------------------------------------------------------------------
            $cpuLookup = $null
            if ('CPU' -in $Component -or 'Server' -in $Component) {
                $cpuId = Get-HostCpuId $esx
                if ($cpuId -and -not $SkipHclLookup) { $cpuLookup = Find-Cpu $cpuId "$($esx.ProcessorType)" }
                if ('CPU' -in $Component) {
                    $data = @{ Name = "$($esx.ProcessorType)"; Detail = "CPUID $cpuId, $($esx.ExtensionData.Hardware.CpuInfo.NumCpuPackages) socket(s), $($esx.NumCpu) cores" }
                    if (-not $cpuId) { $data.Status = 'NotFound'; $data.Message = 'The host reports no CPUID' }
                    Add-Row $hostInfo 'CPU' $data $cpuLookup
                }
            }
            # --- Server ---------------------------------------------------------------------
            if ('Server' -in $Component) {
                $data = @{ Name = "$($esx.Manufacturer) $($esx.Model)".Trim(); Detail = "BIOS $($esx.ExtensionData.Hardware.BiosInfo.BiosVersion)" }
                $lookup = $null
                if ($isVirtual) { $data.Status = 'NotApplicable'; $data.Message = $virtualNote }
                elseif (-not $SkipHclLookup) {
                    $series = if ($cpuLookup -and $cpuLookup.Match -ne 'None') { @($cpuLookup.Names) } else { @() }
                    $lookup = Find-Server "$($esx.Model)".Trim() $series
                }
                Add-Row $hostInfo 'Server' $data $lookup
            }
            # --- PCI devices ----------------------------------------------------------------
            $esxcli = Get-EsxCli -VMHost $esx -Server $vi -V2
            $doVsan = 'Vsan' -in $Component -and ($VsanCheck -eq 'Always' -or ($VsanCheck -eq 'Auto' -and $(
                        $c = "$($esx.Parent)"
                        if (-not $vsanClusters.ContainsKey($c)) { $vsanClusters[$c] = [bool](Get-Cluster -Server $vi -Name $c -ErrorAction SilentlyContinue).VsanEnabled }
                        $vsanClusters[$c])))
            if ('PCI' -in $Component -or $doVsan) {
                $devices = @($esxcli.hardware.pci.list.Invoke() | Where-Object { "$($_.DeviceClassName)" -match $classPattern -or ($doVsan -and "$($_.DeviceClassName)" -match $storagePattern) })
                foreach ($d in $devices) {
                    $ids = [ordered]@{ VID = Format-PciId $d.VendorID; DID = Format-PciId $d.DeviceID; SVID = Format-PciId $d.SubVendorID; SSID = Format-PciId $d.SubDeviceID }
                    $data = @{ Name = "$($d.VendorName) $($d.DeviceName)".Trim(); Detail = "$($d.Address) $($d.DeviceClassName)"; Driver = "$($d.ModuleName)" }
                    foreach ($kv in $ids.GetEnumerator()) { $data[$kv.Key] = $kv.Value }
                    $virtual = $ids.VID -eq '15ad'
                    if ($virtual) { $data.Status = 'NotApplicable'; $data.Message = 'VMware virtual device: not in the Compatibility Guide' }
                    if ('PCI' -in $Component -and "$($d.DeviceClassName)" -match $classPattern) {
                        $l = if ($virtual -or $SkipHclLookup) { $null } else { Find-PciDevice 'io' 'maxSsid' $ids }
                        Add-Row $hostInfo 'PCI' $data $l
                    }
                    if ($doVsan -and "$($d.DeviceClassName)" -match $storagePattern) {
                        $isNvme = "$($d.DeviceClassName)" -match 'Non-Volatile memory'
                        $program = if ($isNvme) { 'ssd' } else { 'vsanio' }
                        $l = if ($virtual -or $SkipHclLookup) { $null } else { Find-PciDevice $program 'ssid' $ids }
                        Add-Row $hostInfo $(if ($isNvme) { 'vSAN NVMe' } else { 'vSAN controller' }) $data $l
                    }
                }
            }
            # --- vSAN disks (local SAS/SATA; NVMe drives are checked above by their PCI IDs) --
            if ($doVsan) {
                $disks = @($esxcli.storage.core.device.list.Invoke() | Where-Object {
                        "$($_.IsLocal)" -eq 'true' -and "$($_.IsUSB)" -ne 'true' -and "$($_.Device)$($_.DisplayName)" -notmatch 'NVMe' -and "$($_.Model)".Trim() })
                foreach ($disk in $disks) {
                    $isSsd = "$($disk.IsSSD)" -eq 'true'
                    $model = "$($disk.Model)".Trim()
                    $sizeGb = [math]::Round([double]"$($disk.Size)" / 1024)
                    $data = @{ Name = "$("$($disk.Vendor)".Trim()) $model".Trim(); Detail = "$($disk.Device), $sizeGb GB, $(if ($isSsd) { 'SSD' } else { 'HDD' })" }
                    $virtual = "$($disk.Vendor) $model" -match 'VMware|Virtual'
                    if ($virtual) { $data.Status = 'NotApplicable'; $data.Message = 'Virtual disk: not in the Compatibility Guide' }
                    $l = if ($virtual -or $SkipHclLookup) { $null } else { Find-VsanDisk $(if ($isSsd) { 'ssd' } else { 'hdd' }) $model }
                    Add-Row $hostInfo 'vSAN disk' $data $l
                }
            }
        }
        catch {
            Add-Note "$($esx.Name) : $($_.Exception.Message)"
            Add-Row $hostInfo 'Host' @{ Name = "$($esx.Manufacturer) $($esx.Model)"; Status = 'Failed'; Message = $_.Exception.Message } $null
        }
    }
}
finally {
    if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
}

# The releases in the target range that the guide knows: those listed for at least one component in this report.
$rangeReleases = @()
if ($hasRange) {
    $rangeVersions = @($hclCache.Values.Releases | Where-Object { Test-InRange $_ } | ForEach-Object { ConvertTo-EsxiVersion $_ } | Sort-Object -Unique)
    $rangeReleases = @($rangeVersions | ForEach-Object { Get-ReleaseLabel $_ })
    foreach ($edge in @($minVer, $maxVer)) {
        if ($edge -and $hclCache.Count -and $edge -notin $rangeVersions) { Add-Note "Nothing in this report is listed for $(Get-ReleaseLabel $edge) in the Compatibility Guide, so that release could not be checked. Is the version right, or is it not in the guide yet?" }
    }
    Write-Host "Releases checked: $(if ($rangeReleases) { $rangeReleases -join ', ' } else { 'none' })" -ForegroundColor Cyan
}

$report = @(foreach ($r in $rows) {
        $o = $r.Row; $l = $r.Lookup
        foreach ($k in 'HclProgram', 'HclMatch', 'HclBrand', 'HclModel', 'ReleasesInRange', 'MissingReleases', 'SupportedReleases', 'CompatibilityGuideUrl') { $o[$k] = '' }
        $msg = $o.Message; $o.Remove('Message')
        if (-not $o.Status) {
            if (-not $l) { $o.Status = 'NotChecked' }
            else {
                $o.HclProgram = $l.Program; $o.CompatibilityGuideUrl = $l.Url
                if ($l.Error) { $o.Status = 'LookupFailed'; $msg = $l.Error }
                elseif ($l.Match -eq 'None') { $o.Status = 'NotFound'; $msg = 'No matching entry in the Compatibility Guide' }
                else {
                    $o.HclMatch = $l.Match; $o.HclBrand = $l.Brand; $o.HclModel = $l.Model
                    $o.SupportedReleases = $l.Releases -join ', '
                    $msg = $l.Note
                    if (-not $hasRange) { $o.Status = 'Found' }
                    else {
                        $inRange = @($rangeReleases | Where-Object { $_ -in $l.Releases })
                        $missing = @($rangeReleases | Where-Object { $_ -notin $l.Releases })
                        $o.ReleasesInRange = $inRange -join ', '; $o.MissingReleases = $missing -join ', '
                        $o.Status = if (-not $inRange) { 'NotSupported' } elseif ($missing) { 'Partial' } else { 'Supported' }
                    }
                }
            }
        }
        $o.Message = $msg
        [pscustomobject]$o
    })

# Summary: rows per component type and status.
Write-Host "$($report.Count) rows, $(@($report | Select-Object -ExpandProperty VMHost -Unique).Count) host(s), $($hclCache.Count) Compatibility Guide lookup(s)." -ForegroundColor Cyan
foreach ($g in ($report | Group-Object Component, Status | Sort-Object Name)) { Write-Host ("  {0,-30} {1}" -f $g.Name, $g.Count) }

if ($CsvPath -and $report.Count) {
    $csvDir = Split-Path -Path $CsvPath -Parent
    if ($csvDir -and -not (Test-Path -LiteralPath $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -UseCulture -Force
    Write-Host "CSV: $CsvPath" -ForegroundColor Green
}
if ($HtmlPath -and $report.Count) {
    $info = [ordered]@{
        Environment      = $EnvironmentName
        vCenter          = $VCenter
        Generated        = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        'Target range'   = if ($hasRange) { "$(if ($minVer) { Get-ReleaseLabel $minVer } else { 'any' }) to $(if ($maxVer) { Get-ReleaseLabel $maxVer } else { 'any' })" } else { 'none (all releases listed)' }
        'Releases checked' = if ($hasRange) { if ($rangeReleases) { $rangeReleases -join ', ' } else { 'none' } } else { '-' }
        Hosts            = @($report | Select-Object -ExpandProperty VMHost -Unique).Count
        Script           = "version $script:ScriptVersion"
    }
    Export-HtmlReport $report $HtmlPath $info @($script:notes)
    Write-Host "HTML: $HtmlPath" -ForegroundColor Green
}
$report
