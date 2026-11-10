<#
.SYNOPSIS
    Reports every LUN of one or more ESXi hosts with its multipath policy, NMP details and working paths.

.DESCRIPTION
    Connects to vCenter and, per host, combines Get-ScsiLun with "esxcli storage nmp device list":
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

.PARAMETER ConfigFile
    Optional JSON config file. Command line wins over the file. Passwords are refused in the file.

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
    .\Get-LunMultipathReport.ps1 -ConfigFile .\lun-report.config.json

.NOTES
    Version: 2.0 (2026-11-10)
    Requires PowerShell 7 or Windows PowerShell 5.1 and VCF.PowerCLI (or VMware.PowerCLI).
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$VMHost,
    [string]$CsvPath,
    [pscredential]$Credential,
    [string]$ConfigFile,
    [switch]$UseSddcCredentials,
    [string]$SddcManager,
    [pscredential]$SddcCredential,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$isCore = $PSVersionTable.PSEdition -eq 'Core'

#region Config file ----------------------------------------------------------------------------
# Order of precedence: command line > config file > prompt. Passwords are never read from the file.
if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    $cfgKeys = @($cfg.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
    $secretKeys = @($cfgKeys | Where-Object { $_ -match 'password|secret|token' })
    if ($secretKeys) { throw "Config file contains $($secretKeys -join ', '). Do not store passwords in it: use <X>User (prompt) or <X>CredentialFile (Export-Clixml)." }
    $settings = @{ VCenter = 'string'; VMHost = 'list'; CsvPath = 'string'; SddcManager = 'string'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
    foreach ($k in $settings.Keys) {
        if ($k -notin $cfgKeys -or $PSBoundParameters.ContainsKey($k) -or $null -eq $cfg.$k) { continue }
        $v = switch ($settings[$k]) { 'list' { [string[]]@($cfg.$k | Where-Object { $_ }) } 'switch' { [switch][bool]$cfg.$k } default { [string]$cfg.$k } }
        Set-Variable -Name $k -Value $v
    }
    $credMap = [ordered]@{ Vc = 'Credential'; Sddc = 'SddcCredential' }
    foreach ($pre in $credMap.Keys) {
        $name = $credMap[$pre]
        if ($PSBoundParameters.ContainsKey($name)) { continue }
        $file = $cfg."${pre}CredentialFile"; $user = $cfg."${pre}User"
        if ($file) { Set-Variable -Name $name -Value (Import-Clixml ([Environment]::ExpandEnvironmentVariables($file))) }
        elseif ($user -and -not ($pre -eq 'Vc' -and $UseSddcCredentials)) { Set-Variable -Name $name -Value (Get-Credential -UserName $user -Message "Password for $user ($pre)") }
    }
}
if (-not $VCenter) { throw 'No vCenter given. Use -VCenter or "VCenter" in the config file.' }
if (-not $VMHost) { throw 'No hosts given. Use -VMHost or "VMHost" in the config file.' }
if ($CsvPath) { $CsvPath = $CsvPath.Replace('{date}', (Get-Date -Format 'yyyyMMdd-HHmm')) }
#endregion

#region SDDC Manager vault (-UseSddcCredentials) ------------------------------------------------
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
            # One esxcli call per host (not per LUN), indexed by device name.
            $esxcli = Get-EsxCli -VMHost $esx -Server $vi -V2
            $nmp = @{}
            foreach ($d in $esxcli.storage.nmp.device.list.Invoke()) { $nmp[$d.Device] = $d }

            foreach ($lun in Get-ScsiLun -VmHost $esx -Server $vi) {
                $d = $nmp[$lun.CanonicalName]
                $report.Add([pscustomobject]@{
                        VMHost                                = $esx.Name
                        LUNName                               = $lun.DisplayName
                        CanonicalName                         = $lun.CanonicalName
                        LunType                               = $lun.LunType
                        CapacityGB                            = [math]::Round($lun.CapacityGB, 2)
                        MultipathPolicy                       = $lun.MultipathPolicy
                        PathSelectionPolicy                   = $d.PathSelectionPolicy
                        PathSelectionPolicyDeviceConfig       = $d.PathSelectionPolicyDeviceConfig
                        PathSelectionPolicyDeviceCustomConfig = $d.PathSelectionPolicyDeviceCustomConfig
                        StorageArrayType                      = $d.StorageArrayType
                        StorageArrayTypeDeviceConfig          = $d.StorageArrayTypeDeviceConfig
                        WorkingPathCount                      = @($d.WorkingPaths | Where-Object { $_ }).Count
                        WorkingPaths                          = @($d.WorkingPaths) -join ', '
                        IsLocalSASDevice                      = $d.IsLocalSASDevice
                        IsUSB                                 = $d.IsUSB
                        IsBootUSBDevice                       = $d.IsBootUSBDevice
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
