#Requires -Version 5.1
<#
.SYNOPSIS
    Lists the network and storage PCI devices of every ESXi host and checks them against the
    Broadcom Compatibility Guide, optionally for a target ESXi version range (for example 9.0 to 9.1.1).

.DESCRIPTION
    Connects to vCenter and runs "esxcli hardware pci list" on every host. Devices whose class
    matches -DeviceClass (default: Ethernet and Fibre Channel) are looked up in the Broadcom
    Compatibility Guide (IO devices) by vendor ID, device ID, subvendor ID and subdevice ID.
    When no entry matches all four IDs, the lookup is repeated without the subdevice ID and the
    row says so in HclMatch.

    Without a version range, each row lists the ESXi releases the guide supports for the device.
    With -MinEsxiVersion and/or -MaxEsxiVersion, each row also gets a Status for that range:
      Supported     the device is listed for every ESXi release in the range
      Partial       listed for some releases in the range; MissingReleases says which
      NotSupported  the device is in the guide, but for no release in the range
      NotFound      no Compatibility Guide entry for these IDs
      LookupFailed  the Compatibility Guide could not be reached (see Message)
    "Every release in the range" means every release in that range that the guide lists for at
    least one of the devices in this report. A release that no device lists yet (for example a
    version that has only just come out) cannot be checked; the script warns about that.

    Identical devices (same four IDs) are looked up once and the result is reused for every host.
    Results are written to the pipeline as objects, one per device per host. Hosts that are not
    connected or fail are reported too, with Status and the reason. With -CsvPath the results
    are also exported to CSV (with the list separator of your Windows region, for Excel).

    The script only reads. It changes nothing in vCenter or on the hosts. It needs internet
    access to https://compatibilityguide.broadcom.com (unless -SkipHclLookup).

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
    Releases are compared as numbers: "ESXi 8.0 U3" counts as 8.0.3, "ESXi 9.0.1" as 9.0.1.

.PARAMETER DeviceClass
    Regular expressions matched against the PCI device class name. Default: Ethernet, Fibre.
    Config: DeviceClass. Use for example 'Ethernet','Fibre','Mass storage','RAID','NVM' to
    include storage controllers.

.PARAMETER SkipHclLookup
    Only list the devices and their IDs; do not query the Compatibility Guide. Config: SkipHclLookup.

.PARAMETER CsvPath
    Optional CSV export path. "{date}" is replaced with yyyyMMdd-HHmm, "{env}" with the
    environment name. Config: CsvPath.

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
    # Which NICs and HBAs are supported on ESXi 9.0 up to 9.1.1?
    .\Get-PciDeviceCompatibility.ps1 -VCenter vc01.corp.local -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 |
        Format-Table VMHost, DeviceName, Driver, Status, MissingReleases

.EXAMPLE
    # Environment config (config\lab1.config.json), vCenter password from the SDDC Manager vault, CSV export
    .\Get-PciDeviceCompatibility.ps1 -Environment lab1 -UseSddcCredentials -CsvPath '%USERPROFILE%\Reports\{env}-pci-{date}.csv'

.EXAMPLE
    # Only the devices that are not fully supported, one line per unique device
    .\Get-PciDeviceCompatibility.ps1 -Environment lab1 -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 |
        Where-Object Status -ne 'Supported' | Sort-Object VID, DID, SVID, SSID -Unique |
        Format-Table DeviceName, VID, DID, SVID, SSID, Status, MissingReleases

.NOTES
    Name        : Get-PciDeviceCompatibility.ps1
    Version     : 2.0
    Date        : 2026-11-23
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : PowerShell 7 or Windows PowerShell 5.1, VCF.PowerCLI (or VMware.PowerCLI),
                  internet access to compatibilityguide.broadcom.com.
    Config      : one file per environment, see config\environment.config.sample.json
    Credits     : Compatibility Guide query based on Check-BroadcomCompatIoDevice by William Lam
                  (https://williamlam.com).
    License     : provided as is, without warranty. Test in a lab first. The Compatibility Guide
                  is the source of truth: check the device and its driver/firmware there before an upgrade.

    Version history
    2.0  2026-11-23  Rewrite (was Report-PCIDevices.ps1): environment config, standard header, ESXi
                     version range with Status per device, lookup cache, subdevice ID filter fixed,
                     IDs zero-padded to 4 hex digits, no-match handling, one CSV export at the end.
    1.0  2025-10-17  First version (Report-PCIDevices.ps1).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-PciDeviceCompatibility
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$Cluster,
    [string]$MinEsxiVersion,
    [string]$MaxEsxiVersion,
    [string[]]$DeviceClass = @('Ethernet', 'Fibre'),
    [switch]$SkipHclLookup,
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
$script:ScriptVersion = '2.0 (2026-11-23)'
Write-Host "Get-PciDeviceCompatibility.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'PciDeviceCompatibility'
$ConfigSettings = @{ VCenter = 'first'; Cluster = 'list'; MinEsxiVersion = 'string'; MaxEsxiVersion = 'string'; DeviceClass = 'list'; SkipHclLookup = 'switch'; CsvPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
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
function ConvertTo-EsxiVersion([string]$Text) {
    # "9.0" -> 9.0.0, "9.1.1" -> 9.1.1, "ESXi 8.0 U3" -> 8.0.3, "ESXi 7.0 Update 2" -> 7.0.2. $null when there is no version.
    if ($Text -notmatch '(\d+)\.(\d+)(?:\.(\d+))?(?:\s*(?:U|Update\s*)(\d+))?') { return $null }
    $third = if ($Matches[3]) { $Matches[3] } elseif ($Matches[4]) { $Matches[4] } else { '0' }
    [version]::new([int]$Matches[1], [int]$Matches[2], [int]$third)
}
function Format-PciId($Value) {
    # esxcli returns the IDs as decimal numbers (sometimes as 0x... hex); the guide wants 4 hex digits.
    $s = "$Value".Trim()
    $n = if ($s -match '^0x([0-9a-f]+)$') { [Convert]::ToInt32($Matches[1], 16) } else { [int]$s }
    '{0:x4}' -f $n
}
function Find-HclIoDevice([string]$VID, [string]$DID, [string]$SVID, [string]$SSID) {
    # POST to the Compatibility Guide search API (IO devices). Returns the matching entries.
    $filters = @(
        @{ displayKey = 'vid'; filterValues = @($VID) }
        @{ displayKey = 'did'; filterValues = @($DID) }
        @{ displayKey = 'svid'; filterValues = @($SVID) }
    )
    if ($SSID) { $filters += @{ displayKey = 'ssid'; filterValues = @($SSID) } }
    $body = [ordered]@{ programId = 'io'; filters = $filters; keyword = @(); date = @{ startDate = $null; endDate = $null } } | ConvertTo-Json -Depth 5
    $uri = 'https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=50&page=1&sortBy=&sortType=ASC'
    $result = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body
    foreach ($item in @($result.data.fieldValues)) {
        if ($null -eq $item) { continue }
        [pscustomobject]@{
            Brand      = "$($item.brandName)"
            Model      = "$($item.model.name)"
            DeviceType = "$($item.deviceType)"
            Releases   = @($item.supportedReleases.name | Where-Object { $_ })
        }
    }
}
function Get-HclLookup([string]$VID, [string]$DID, [string]$SVID, [string]$SSID) {
    # Cached: identical devices on many hosts are looked up once.
    $key = "$VID|$DID|$SVID|$SSID"
    if ($hclCache.ContainsKey($key)) { return $hclCache[$key] }
    $lookup = [pscustomobject]@{ Match = 'None'; Brand = ''; Model = ''; Releases = @(); Error = '' }
    try {
        $entries = @(Find-HclIoDevice $VID $DID $SVID $SSID)
        if ($entries) { $lookup.Match = 'Exact' }
        else {
            # Many entries leave the subdevice ID empty (any): try again without it.
            $entries = @(Find-HclIoDevice $VID $DID $SVID $null)
            if ($entries) { $lookup.Match = 'WithoutSSID' }
        }
        if ($entries) {
            $lookup.Brand = (@($entries.Brand | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
            $lookup.Model = (@($entries.Model | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
            # One device can match several entries (models): it is supported on the union of their releases.
            $lookup.Releases = @($entries.Releases | Sort-Object -Unique | Sort-Object { ConvertTo-EsxiVersion $_ } -Descending)
        }
    }
    catch { $lookup.Error = $_.Exception.Message; Write-Warning "Compatibility Guide lookup $key failed: $($lookup.Error)" }
    $hclCache[$key] = $lookup
    $lookup
}
function Test-InRange([string]$Release) {
    $v = ConvertTo-EsxiVersion $Release
    $null -ne $v -and (-not $minVer -or $v -ge $minVer) -and (-not $maxVer -or $v -le $maxVer)
}
#endregion

$minVer = $null; $maxVer = $null
if ($MinEsxiVersion) { $minVer = ConvertTo-EsxiVersion $MinEsxiVersion; if (-not $minVer) { throw "MinEsxiVersion '$MinEsxiVersion' is not a version (use for example 9.0)." } }
if ($MaxEsxiVersion) { $maxVer = ConvertTo-EsxiVersion $MaxEsxiVersion; if (-not $maxVer) { throw "MaxEsxiVersion '$MaxEsxiVersion' is not a version (use for example 9.1.1)." } }
if ($minVer -and $maxVer -and $minVer -gt $maxVer) { throw "MinEsxiVersion ($MinEsxiVersion) is higher than MaxEsxiVersion ($MaxEsxiVersion)." }
$hasRange = [bool]($minVer -or $maxVer)
if ($hasRange) { Write-Host "Target ESXi range: $(if ($minVer) { $minVer } else { 'any' }) to $(if ($maxVer) { $maxVer } else { 'any' })" -ForegroundColor Cyan }
if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
$classPattern = ($DeviceClass | Where-Object { $_ }) -join '|'
Write-Host "Device classes: $classPattern" -ForegroundColor Cyan

$hclCache = @{}
$rows = [System.Collections.Generic.List[object]]::new()
$vi = $null
try {
    Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $VCenter -Credential $Credential -NotDefault -WarningAction SilentlyContinue

    $esxHosts = if ($Cluster) { Get-Cluster -Server $vi -Name $Cluster | Get-VMHost -Server $vi } else { Get-VMHost -Server $vi }
    foreach ($esx in @($esxHosts | Sort-Object Name)) {
        $hostInfo = [ordered]@{ Cluster = "$($esx.Parent)"; VMHost = $esx.Name; EsxiVersion = "$($esx.Version) ($($esx.Build))" }
        if ("$($esx.ConnectionState)" -notin 'Connected', 'Maintenance') {
            Write-Warning "$($esx.Name) skipped: host is $($esx.ConnectionState) in vCenter"
            $rows.Add([ordered]@{ Host = $hostInfo; Status = 'Skipped'; Message = "Host is $($esx.ConnectionState)" }); continue
        }
        Write-Host "  $($esx.Name)" -ForegroundColor Green
        try {
            $esxcli = Get-EsxCli -VMHost $esx -Server $vi -V2
            $devices = @($esxcli.hardware.pci.list.Invoke() | Where-Object { "$($_.DeviceClassName)" -match $classPattern })
            foreach ($d in $devices) {
                $ids = [ordered]@{ VID = Format-PciId $d.VendorID; DID = Format-PciId $d.DeviceID; SVID = Format-PciId $d.SubVendorID; SSID = Format-PciId $d.SubDeviceID }
                $lookup = if ($SkipHclLookup) { $null } else { Get-HclLookup $ids.VID $ids.DID $ids.SVID $ids.SSID }
                $rows.Add([ordered]@{ Host = $hostInfo; Device = $d; Ids = $ids; Lookup = $lookup })
            }
        }
        catch {
            Write-Warning "$($esx.Name) : $($_.Exception.Message)"
            $rows.Add([ordered]@{ Host = $hostInfo; Status = 'Failed'; Message = $_.Exception.Message })
        }
    }
}
finally {
    if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
}

# The releases in the target range that the guide knows: those listed for at least one device in this report.
$rangeReleases = @()
if ($hasRange) {
    $rangeReleases = @($hclCache.Values.Releases | Where-Object { Test-InRange $_ } | Sort-Object -Unique | Sort-Object { ConvertTo-EsxiVersion $_ })
    $known = @($rangeReleases | ForEach-Object { ConvertTo-EsxiVersion $_ })
    foreach ($edge in @($minVer, $maxVer)) {
        if ($edge -and $hclCache.Count -and $edge -notin $known) { Write-Warning "No device in this report is listed for ESXi $edge in the Compatibility Guide, so that release could not be checked. Is the version right, or is it not in the guide yet?" }
    }
    Write-Host "Releases checked: $(if ($rangeReleases) { $rangeReleases -join ', ' } else { 'none' })" -ForegroundColor Cyan
}

$report = foreach ($r in $rows) {
    $o = [ordered]@{}
    foreach ($kv in $r.Host.GetEnumerator()) { $o[$kv.Key] = $kv.Value }
    $d = $r.Device; $ids = $r.Ids; $l = $r.Lookup
    $o.PciAddress = "$($d.Address)"; $o.DeviceClass = "$($d.DeviceClassName)"; $o.VendorName = "$($d.VendorName)"
    $o.DeviceName = "$($d.DeviceName)"; $o.Driver = "$($d.ModuleName)"; $o.NUMANode = "$($d.NUMANode)"
    $o.VID = $ids.VID; $o.DID = $ids.DID; $o.SVID = $ids.SVID; $o.SSID = $ids.SSID
    $o.HclMatch = ''; $o.HclBrand = ''; $o.HclModel = ''
    $o.Status = $r.Status; $o.ReleasesInRange = ''; $o.MissingReleases = ''; $o.SupportedReleases = ''
    $o.CompatibilityGuideUrl = ''; $o.Message = "$($r.Message)"
    if ($ids) {
        $o.CompatibilityGuideUrl = "https://compatibilityguide.broadcom.com/search?program=io&persona=live&column=brandName&order=asc&vid=%5B$($ids.VID)%5D&did=%5B$($ids.DID)%5D&svid=%5B$($ids.SVID)%5D&maxSsid=%5B$($ids.SSID)%5D&activePage=1&activeDelta=20"
        if (-not $l) { $o.Status = 'NotChecked' }
        elseif ($l.Error) { $o.Status = 'LookupFailed'; $o.Message = $l.Error }
        elseif ($l.Match -eq 'None') { $o.Status = 'NotFound'; $o.Message = 'No Compatibility Guide entry for these IDs' }
        else {
            $o.HclMatch = $l.Match; $o.HclBrand = $l.Brand; $o.HclModel = $l.Model
            $o.SupportedReleases = $l.Releases -join ', '
            if ($l.Match -eq 'WithoutSSID') { $o.Message = 'Matched on VID/DID/SVID only (the entry has no subdevice ID): check the model' }
            if (-not $hasRange) { $o.Status = 'Found' }
            else {
                $inRange = @($rangeReleases | Where-Object { $_ -in $l.Releases })
                $missing = @($rangeReleases | Where-Object { $_ -notin $l.Releases })
                $o.ReleasesInRange = $inRange -join ', '; $o.MissingReleases = $missing -join ', '
                $o.Status = if (-not $inRange) { 'NotSupported' } elseif ($missing) { 'Partial' } else { 'Supported' }
            }
        }
    }
    [pscustomobject]$o
}
$report = @($report)

# Summary per unique device (same four IDs), not per host.
$unique = @($report | Where-Object VID | Sort-Object VID, DID, SVID, SSID -Unique)
Write-Host "$($report.Count) rows, $($unique.Count) unique device(s), $($hclCache.Count) Compatibility Guide lookup(s)." -ForegroundColor Cyan
foreach ($g in ($unique | Group-Object Status | Sort-Object Name)) { Write-Host ("  {0,-13} {1}" -f $g.Name, $g.Count) }

if ($CsvPath -and $report.Count) {
    $csvDir = Split-Path -Path $CsvPath -Parent
    if ($csvDir -and -not (Test-Path -LiteralPath $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -UseCulture -Force
    Write-Host "CSV: $CsvPath" -ForegroundColor Green
}
$report
