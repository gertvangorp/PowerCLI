#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the TPM (configuration encryption) recovery key of every ESXi host in one or more clusters.

.DESCRIPTION
    Connects to vCenter and runs, per host, "esxcli system settings encryption get" (encryption mode)
    and "esxcli system settings encryption recovery list" (recovery ID and key). Keep these keys in a
    safe place: you need them when a host's TPM or motherboard is replaced.

    Results are written to the pipeline as objects, one per recovery key. Hosts that fail or are not
    connected are reported too, with Status and the reason, instead of being skipped silently.
    With -CsvPath the results are also exported to CSV.

    THE OUTPUT CONTAINS SECRETS. Store the CSV encrypted (for example in your password manager or a
    vault) and remove it from disk afterwards.

    The script only reads. It changes nothing in vCenter or on the hosts.

    Credentials (vCenter SSO account), in this order:
      -Credential, or VcUser / VcCredentialFile in the config file,
      -UseSddcCredentials: the vCenter SSO account is read from the SDDC Manager vault
                           (GET /v1/credentials, needs the SDDC Manager ADMIN role),
      otherwise Get-Credential asks.

.PARAMETER VCenter
    vCenter FQDN. Config: VCenter.

.PARAMETER Cluster
    One or more cluster names. Leave empty for all hosts in vCenter. Config: Cluster.

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
    .\Get-TpmRecoveryKey.ps1 -VCenter vc01.corp.local -Cluster CL-MGMT-01 | Format-Table

.EXAMPLE
    .\Get-TpmRecoveryKey.ps1 -ConfigFile D:\Configs\customer1.config.json -UseSddcCredentials

.EXAMPLE
    # Environment config: reads config\lab1.config.json
    .\Get-TpmRecoveryKey.ps1 -Environment lab1 | Format-Table

.NOTES
    Name        : Get-TpmRecoveryKey.ps1
    Version     : 2.1
    Date        : 2026-11-10
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : PowerShell 7 or Windows PowerShell 5.1, VCF.PowerCLI (or VMware.PowerCLI).
    Config      : one file per environment, see config\environment.config.sample.json
    License     : provided as is, without warranty. Test in a lab first.

    Version history
    2.1  2026-11-10  Shared environment config (-Environment), standard header, {env} in -CsvPath.
    2.0  2026-11-10  Rewrite: no hardcoded credentials, esxcli -V2, failed hosts reported, -ConfigFile.
    1.0              First version (Report-TPM-RecoveryKey.ps1).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-TpmRecoveryKey
#>
[CmdletBinding()]
param(
    [string]$VCenter,
    [string[]]$Cluster,
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
Write-Host "Get-TpmRecoveryKey.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'TpmRecoveryKey'
$ConfigSettings = @{ VCenter = 'first'; Cluster = 'list'; CsvPath = 'string'; SddcManager = 'first'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
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

$vi = $null
$report = [System.Collections.Generic.List[object]]::new()
try {
    Write-Host "Connecting to $VCenter ..." -ForegroundColor Cyan
    $vi = Connect-VIServer -Server $VCenter -Credential $Credential -NotDefault -WarningAction SilentlyContinue

    $esxHosts = if ($Cluster) { Get-Cluster -Server $vi -Name $Cluster | Get-VMHost -Server $vi } else { Get-VMHost -Server $vi }
    foreach ($esx in @($esxHosts | Sort-Object Name)) {
        $base = [ordered]@{ VMHost = $esx.Name; Cluster = "$($esx.Parent)"; EncryptionMode = $null; RecoveryId = $null; Key = $null; Status = 'OK'; Message = '' }
        if ("$($esx.ConnectionState)" -notin 'Connected', 'Maintenance') {
            $base.Status = 'Skipped'; $base.Message = "Host is $($esx.ConnectionState)"
            $report.Add([pscustomobject]$base); continue
        }
        try {
            $esxcli = Get-EsxCli -VMHost $esx -Server $vi -V2
            $base.EncryptionMode = $esxcli.system.settings.encryption.get.Invoke().Mode
            $keys = @($esxcli.system.settings.encryption.recovery.list.Invoke())
            if (-not $keys) {
                $base.Status = 'NoKey'; $base.Message = 'No recovery key (TPM configuration encryption not active?)'
                $report.Add([pscustomobject]$base); continue
            }
            foreach ($k in $keys) {
                $row = [ordered]@{}
                foreach ($kv in $base.GetEnumerator()) { $row[$kv.Key] = $kv.Value }
                $row.RecoveryId = $k.RecoveryID
                $row.Key = $k.Key
                $report.Add([pscustomobject]$row)
            }
        }
        catch {
            $base.Status = 'Failed'; $base.Message = $_.Exception.Message
            Write-Warning "$($esx.Name) : $($_.Exception.Message)"
            $report.Add([pscustomobject]$base)
        }
    }
}
finally {
    if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue }
}

if ($CsvPath -and $report.Count) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force
    Write-Warning "Recovery keys written to $CsvPath. Store this file encrypted and delete it from disk afterwards."
}
$report
