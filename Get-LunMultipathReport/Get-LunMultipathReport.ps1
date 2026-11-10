#Requires -Version 5.1
<#
.SYNOPSIS
    Reports every LUN of one or more ESXi hosts with its multipath policy, NMP details and working paths.

.DESCRIPTION
    Connects to vCenter and, per host, combines Get-ScsiLun with esxcli (storage core device/path list,
    storage nmp device list and storage hpp device list). Devices claimed by NMP (typically SAN LUNs) and
    by HPP (local NVMe/SAS/SATA by default since ESXi 7) are both reported, with MultipathPlugin showing which:
    display name, canonical name, multipath policy, path selection policy (and its config), storage
    array type (SATP), working paths and whether the device is local, USB or the boot device.

    Results are written to the pipeline as objects, so you can sort, filter or pipe them. With
    -CsvPath they are also exported to CSV.

    The script only reads. It changes nothing in vCenter or on the hosts.

    Credentials (vCenter SSO account), in this order:
      -Credential, or VcUser / VcCredentialFile in the config file,
      -UseSddcCredentials: the vCenter SSO account is read from the SDDC Manager vault
                           (GET /v1/credentials, needs the SDDC Manager ADMIN role),
      otherwise Get-Credential asks.

.PARAMETER VCenter
    vCenter FQDN. Config: VCenter.

.PARAMETER VMHost
    One or more ESXi host names as known in vCenter. Wildcards work. Config: VMHost.

.PARAMETER CsvPath
    Optional CSV export path. "{date}" is replaced with yyyyMMdd-HHmm. Config: CsvPath.

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
    .\Get-LunMultipathReport.ps1 -VCenter vc01.corp.local -VMHost esx01.corp.local | Format-Table

.EXAMPLE
    .\Get-LunMultipathReport.ps1 -VCenter vc01.corp.local -VMHost esx0* -CsvPath C:\Temp\luns-{date}.csv

.EXAMPLE
    .\Get-LunMultipathReport.ps1 -ConfigFile D:\Configs\customer1.config.json

.EXAMPLE
    # Environment config: reads config\lab1.config.json
    .\Get-LunMultipathReport.ps1 -Environment lab1 | Format-Table

.NOTES
    Name        : Get-LunMultipathReport.ps1
    Version     : 2.1
    Date        : 2026-11-10
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : PowerShell 7 or Windows PowerShell 5.1, VCF.PowerCLI (or VMware.PowerCLI).
    Config      : one file per environment, see config\environment.config.sample.json
    License     : provided as is, without warranty. Test in a lab first.

    Version history
    2.1  2026-11-10  Shared environment config (-Environment), standard header, {env} in -CsvPath.
    2.0.1 2026-11-10 HPP-claimed devices (local NVMe/vSAN) reported, MultipathPlugin and PathCount.
    2.0  2026-11-10  Rewrite: parameters, -ConfigFile, one esxcli call per host, object output.
    1.0              First version (Report-LUN-Info.ps1).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-LunMultipathReport
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$VMHost,
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
$script:ScriptVersion = '2.1 (2026-11-10)'
Write-Host "Get-LunMultipathReport.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'LunMultipathReport'
$ConfigSettings = @{ VCenter = 'first'; VMHost = 'list'; CsvPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
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
if (-not $VMHost) { throw 'No hosts given. Use -VMHost or "VMHost" in the config file.' }
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

$vi = $null
$report = [System.Collections.Generic.List[object]]::new()
try {
    Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $VCenter -Credential $Credential -NotDefault -WarningAction SilentlyContinue

    $esxHosts = @(Get-VMHost -Server $vi -Name $VMHost -ErrorAction SilentlyContinue)
    foreach ($name in $VMHost) {
        if (-not ($esxHosts | Where-Object { $_.Name -like $name })) { Write-Warning "Host not found in $VCenter : $name" }
    }

    foreach ($esx in $esxHosts) {
        Write-Host "Reading LUNs of $($esx.Name) ..." -ForegroundColor Cyan
        try {
            # esxcli once per host (not per LUN), indexed by device name.
            $esxcli = Get-EsxCli -VMHost $esx -Server $vi -V2
            $core = @{}; foreach ($c in $esxcli.storage.core.device.list.Invoke()) { $core[$c.Device] = $c }
            $nmp = @{}; foreach ($n in $esxcli.storage.nmp.device.list.Invoke()) { $nmp[$n.Device] = $n }
            # HPP (High-Performance Plug-in) claims local NVMe/SAS/SATA by default; NMP does not list those devices.
            $hpp = @{}; try { foreach ($h in $esxcli.storage.hpp.device.list.Invoke()) { $hpp[$h.Device] = $h } } catch { Write-Verbose "No HPP on $($esx.Name): $($_.Exception.Message)" }
            $paths = @{}
            foreach ($pa in $esxcli.storage.core.path.list.Invoke()) {
                if (-not $paths.ContainsKey($pa.Device)) { $paths[$pa.Device] = [System.Collections.Generic.List[object]]::new() }
                $paths[$pa.Device].Add($pa)
            }

            foreach ($lun in Get-ScsiLun -VmHost $esx -Server $vi) {
                $c = $core[$lun.CanonicalName]; $d = $nmp[$lun.CanonicalName]; $h = $hpp[$lun.CanonicalName]
                $devPaths = @($paths[$lun.CanonicalName] | Where-Object { $_ })
                $active = @($devPaths | Where-Object { "$($_.State)" -eq 'active' })
                $report.Add([pscustomobject]@{
                        VMHost                                = $esx.Name
                        LUNName                               = $lun.DisplayName
                        CanonicalName                         = $lun.CanonicalName
                        LunType                               = $lun.LunType
                        CapacityGB                            = [math]::Round($lun.CapacityGB, 2)
                        MultipathPolicy                       = $lun.MultipathPolicy
                        MultipathPlugin                       = $(if ($c.MultipathPlugin) { $c.MultipathPlugin } elseif ($d) { 'NMP' } elseif ($h) { 'HPP' })
                        # NMP: path selection policy (PSP). HPP: path selection scheme (PSS).
                        PathSelectionPolicy                   = $(if ($d) { $d.PathSelectionPolicy } else { $h.PathSelectionScheme })
                        PathSelectionPolicyDeviceConfig       = $(if ($d) { $d.PathSelectionPolicyDeviceConfig } elseif ($h.PathSelectionSchemeConfig) { $h.PathSelectionSchemeConfig } else { $h.PathSelectionSchemeConfiguration })
                        PathSelectionPolicyDeviceCustomConfig = $d.PathSelectionPolicyDeviceCustomConfig
                        StorageArrayType                      = $d.StorageArrayType
                        StorageArrayTypeDeviceConfig          = $d.StorageArrayTypeDeviceConfig
                        PathCount                             = $devPaths.Count
                        WorkingPathCount                      = $active.Count
                        WorkingPaths                          = ($active | ForEach-Object { $_.RuntimeName }) -join ', '
                        IsLocal                               = $c.IsLocal
                        IsUSB                                 = $c.IsUSB
                        IsBootDevice                          = $c.IsBootDevice
                    })
            }
        }
        catch { Write-Warning "$($esx.Name) : $($_.Exception.Message)" }
    }
}
finally {
    if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
}

if ($CsvPath -and $report.Count) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force
    Write-Host "Results exported to $CsvPath" -ForegroundColor Green
}
$report
