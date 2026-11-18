#Requires -Version 5.1
<#
.SYNOPSIS
    Exports the backup configuration settings (not the backups themselves) of SDDC Manager,
    vCenter (VAMI) and VCF fleet management to JSON files.

.DESCRIPTION
    Read-only. The script only sends GET requests (plus the login calls) and writes one JSON file
    per endpoint into a timestamped folder, together with a summary.json. It does NOT start a
    backup and does NOT change any setting. Run it before and after Set-VcfBackupSettings.ps1 to
    keep a record of the change.

    Components and endpoints:
      SDDC Manager   POST /v1/tokens                                  (login)
                     GET  /v1/system/backup-configuration
      vCenter (VAMI) POST /api/session                                (login)
                     GET  /api/appliance/recovery/backup/schedules
                     GET  /api/appliance/recovery/backup/job/details  (recent jobs, -IncludeJobHistory)
      Fleet mgmt     Basic auth (admin@local) against the VCF Operations fleet management appliance
                     (the former Aria Suite Lifecycle). The endpoint paths differ between builds, so
                     they are a parameter (-FleetEndpoints). Check them in the Swagger UI of the
                     appliance (https://<fleet-fqdn>/api/swagger-ui.html) if a call returns 404.

    A component without a server name is skipped. A failing endpoint is logged in summary.json
    and does not stop the run.

    Credentials, per component, in this order:
      the -<X>Credential parameter, or <X>User / <X>CredentialFile in the config file,
      -UseSddcCredentials (vCenter only): the SSO administrator password is read from the
                           SDDC Manager vault (GET /v1/credentials, needs the ADMIN role),
      otherwise Get-Credential asks.

    The APIs normally mask passwords and passphrases. The script also replaces every property whose
    name looks like a secret with ***REDACTED*** before it writes a file, unless -NoRedact is given.

.PARAMETER SddcManager
    SDDC Manager FQDN. Config: SddcManager.

.PARAMETER SddcCredential
    SDDC Manager account. Config: SddcUser (prompt) or SddcCredentialFile (Export-Clixml).
    With -UseSddcCredentials this account needs the ADMIN role.

.PARAMETER VCenter
    One or more vCenter FQDNs. Config: VCenter (a list is allowed).

.PARAMETER VCenterCredential
    vCenter account, used for every vCenter. Config: VcUser (prompt) or VcCredentialFile.

.PARAMETER UseSddcCredentials
    Read the vCenter SSO administrator password of each vCenter from the SDDC Manager vault.

.PARAMETER FleetManager
    FQDN of the VCF Operations fleet management appliance. Config: FleetManager.

.PARAMETER FleetCredential
    Fleet management account (admin@local). Config: FleetUser (prompt) or FleetCredentialFile.

.PARAMETER FleetEndpoints
    API paths read on the fleet management appliance. Config: FleetEndpoints.

.PARAMETER OutputPath
    Folder for the export. A timestamped subfolder is made per run. Can use {env}, {date} and
    %VARIABLES%. Config: OutputPath. Default: .\vcf-backup-settings

.PARAMETER IncludeJobHistory
    Also export the recent backup jobs of every vCenter. Config: IncludeJobHistory.

.PARAMETER NoRedact
    Do not mask secret-looking properties in the output files.

.PARAMETER Environment
    Name of an environment config: reads config\<name>.config.json in this repository.

.PARAMETER ConfigFile
    Path to an environment config file (JSON). Command line wins over the file. Passwords are refused in the file.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the TLS certificates of SDDC Manager, vCenter and fleet management.

.EXAMPLE
    # Everything from the environment config (config\lab1.config.json, section VcfBackupSettings)
    .\Export-VcfBackupSettings.ps1 -Environment lab1

.EXAMPLE
    # VCF: vCenter passwords from the SDDC Manager vault, only the SDDC Manager login is asked
    .\Export-VcfBackupSettings.ps1 -Environment lab1 -UseSddcCredentials

.EXAMPLE
    $cred = Get-Credential administrator@vsphere.local
    .\Export-VcfBackupSettings.ps1 -SddcManager sddc01.corp.local -SddcCredential $cred `
        -VCenter vc01.corp.local, vc02.corp.local -VCenterCredential $cred `
        -FleetManager fleet01.corp.local -OutputPath D:\Exports\vcf-backup-settings

.NOTES
    Name        : Export-VcfBackupSettings.ps1
    Version     : 1.0
    Date        : 2026-11-18
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : Windows PowerShell 5.1 or PowerShell 7+. No PowerCLI modules needed.
    Config      : one file per environment, see config\environment.config.sample.json (section VcfBackupSettings)
    License     : provided as is, without warranty. Test in a lab first.

    Version history
    1.0  2026-11-18  First public version: shared environment config, -UseSddcCredentials, standard header.

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Export-VcfBackupSettings
#>
[CmdletBinding()]
param(
    [string]$SddcManager,
    [pscredential]$SddcCredential,

    [string[]]$VCenter,
    [pscredential]$VCenterCredential,
    [switch]$UseSddcCredentials,

    [string]$FleetManager,
    [pscredential]$FleetCredential,
    [string[]]$FleetEndpoints = @(
        '/lcm/lcops/api/v2/settings/backup',
        '/lcm/lcops/api/v2/settings/system-details'
    ),

    [string]$OutputPath = '.\vcf-backup-settings',
    [switch]$IncludeJobHistory,
    [switch]$NoRedact,

    [string]$Environment,
    [string]$ConfigFile,

    # Lab only: do not validate TLS certificates
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.0 (2026-11-18)'
Write-Host "Export-VcfBackupSettings.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'VcfBackupSettings'
$ConfigSettings = @{ SddcManager = 'first'; VCenter = 'list'; FleetManager = 'first'; FleetEndpoints = 'list'; OutputPath = 'string'; IncludeJobHistory = 'switch'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
$ConfigCredentials = [ordered]@{ Sddc = 'SddcCredential'; Vc = 'VCenterCredential'; Fleet = 'FleetCredential' }

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

#region Helpers ------------------------------------------------------------------------------
function Invoke-RestCall {
    param([string]$Method = 'Get', [string]$Uri, [hashtable]$Headers = @{}, $Body)
    $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $p.Body = $Body | ConvertTo-Json -Depth 10 }
    if ($isCore -and $SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
    Invoke-RestMethod @p
}

function Get-BasicAuthHeader([pscredential]$Cred) {
    $pair = '{0}:{1}' -f $Cred.UserName, $Cred.GetNetworkCredential().Password
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }
}

function Read-Credential([string]$UserName, [string]$Message) {
    $p = @{ Message = $Message }
    if ($UserName) { $p.UserName = $UserName }
    Get-Credential @p
}

$secretPattern = '(?i)(password|passphrase|secret|privatekey|private_key|token)'
function Protect-SecretValue($obj) {
    # Masks every string property whose name looks like a secret, at any depth.
    if ($NoRedact -or $null -eq $obj) { return $obj }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string] -and $obj -isnot [System.Collections.IDictionary]) {
        return @($obj | ForEach-Object { Protect-SecretValue $_ })
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $obj.PSObject.Properties) {
            if ($prop.Name -match $secretPattern -and $prop.Value -is [string] -and $prop.Value) { $prop.Value = '***REDACTED***' }
            else { $prop.Value = Protect-SecretValue $prop.Value }
        }
    }
    return $obj
}

$summary = New-Object System.Collections.Generic.List[object]
function Save-Endpoint {
    param([string]$Component, [string]$Server, [string]$Name, [scriptblock]$Call)
    $file = Join-Path $runDir ('{0}_{1}_{2}.json' -f $Component, ($Server -replace '[^\w\.-]', '_'), $Name)
    try {
        $data = & $Call
        Protect-SecretValue $data | ConvertTo-Json -Depth 20 | Set-Content -Path $file -Encoding UTF8
        Write-Host "  [OK]   $Component $Server $Name -> $(Split-Path $file -Leaf)" -ForegroundColor Green
        $summary.Add([pscustomobject]@{ component = $Component; server = $Server; item = $Name; status = 'ok'; file = (Split-Path $file -Leaf) })
    }
    catch {
        Write-Warning "  [FAIL] $Component $Server $Name : $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{ component = $Component; server = $Server; item = $Name; status = 'failed'; error = $_.Exception.Message })
    }
}
#endregion

#region Setup --------------------------------------------------------------------------------
if (-not ($SddcManager -or $VCenter -or $FleetManager)) {
    throw 'Nothing to export. Give -SddcManager, -VCenter and/or -FleetManager, or set them in the config file.'
}
if ($SkipCertificateCheck) {
    Write-Warning 'Certificate validation is disabled. Use this in a lab only.'
    if (-not $isCore) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
}
if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }

$runDir = Join-Path (Expand-PathTemplate $OutputPath) (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
#endregion

#region SDDC Manager -------------------------------------------------------------------------
if ($SddcManager) {
    if (-not $SddcCredential) { $SddcCredential = Get-Credential -Message "SDDC Manager account ($SddcManager)" }
    Write-Host "SDDC Manager: $SddcManager" -ForegroundColor Cyan
    try {
        $body = @{ username = $SddcCredential.UserName; password = $SddcCredential.GetNetworkCredential().Password }
        $sddcToken = (Invoke-SddcApi -Method Post -Path '/v1/tokens' -Body $body).accessToken
        $body = $null
        Save-Endpoint 'sddc' $SddcManager 'backup-configuration' {
            Invoke-SddcApi -Path '/v1/system/backup-configuration' -Token $sddcToken
        }
    }
    catch {
        Write-Warning "  SDDC Manager login failed: $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{ component = 'sddc'; server = $SddcManager; item = 'login'; status = 'failed'; error = $_.Exception.Message })
    }
}
#endregion

#region vCenter (VAMI) -----------------------------------------------------------------------
$vault = $null
if ($VCenter -and $UseSddcCredentials -and -not $VCenterCredential) {
    if (-not $SddcManager) { throw '-UseSddcCredentials needs -SddcManager (or "SddcManager" in the config file).' }
    Write-Host "Reading the vCenter SSO accounts from the SDDC Manager vault on $SddcManager ..." -ForegroundColor Cyan
    try { $vault = Get-SddcVault }
    catch { Write-Warning "Could not read the SDDC Manager vault: $($_.Exception.Message). Asking instead." }
}
$askedVcCredential = $null
foreach ($vc in @($VCenter | Where-Object { $_ })) {
    Write-Host "vCenter: $vc" -ForegroundColor Cyan
    $cred = $VCenterCredential
    if (-not $cred -and $vault) {
        # The SSO administrator is stored as credentialType SSO, under resourceType PSC (or VCENTER).
        $cred = Get-VaultCredential -Vault $vault -ResourceType 'PSC', 'VCENTER' -Name $vc -CredentialType 'SSO'
        if (-not $cred) { Write-Warning "  No SSO account for $vc in the SDDC Manager vault (needs the ADMIN role). Asking instead." }
    }
    if (-not $cred) {
        if (-not $askedVcCredential) { $askedVcCredential = Get-Credential -Message 'vCenter account (e.g. administrator@vsphere.local)' }
        $cred = $askedVcCredential
    }
    try {
        $sid = Invoke-RestCall -Method Post -Uri "https://$vc/api/session" -Headers (Get-BasicAuthHeader $cred)
        $h = @{ 'vmware-api-session-id' = "$sid" }
        Save-Endpoint 'vcenter' $vc 'backup-schedules' {
            Invoke-RestCall -Uri "https://$vc/api/appliance/recovery/backup/schedules" -Headers $h
        }
        if ($IncludeJobHistory) {
            Save-Endpoint 'vcenter' $vc 'backup-job-details' {
                Invoke-RestCall -Uri "https://$vc/api/appliance/recovery/backup/job/details" -Headers $h
            }
        }
        try { Invoke-RestCall -Method Delete -Uri "https://$vc/api/session" -Headers $h | Out-Null } catch { Write-Verbose "Logout from $vc failed: $($_.Exception.Message)" }
    }
    catch {
        Write-Warning "  vCenter login failed: $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{ component = 'vcenter'; server = $vc; item = 'login'; status = 'failed'; error = $_.Exception.Message })
    }
}
#endregion

#region Fleet management ---------------------------------------------------------------------
if ($FleetManager) {
    if (-not $FleetCredential) {
        $u = if ($ConfigFile -and $cfg['FleetUser']) { [string]$cfg['FleetUser'] } else { 'admin@local' }
        $FleetCredential = Read-Credential -UserName $u -Message "Fleet management account ($FleetManager)"
    }
    Write-Host "Fleet management: $FleetManager" -ForegroundColor Cyan
    $h = Get-BasicAuthHeader $FleetCredential
    foreach ($ep in $FleetEndpoints) {
        $name = ($ep.TrimEnd('/') -split '/')[-1]
        Save-Endpoint 'fleet' $FleetManager $name {
            Invoke-RestCall -Uri ("https://$FleetManager" + $ep) -Headers $h
        }
    }
}
#endregion

#region Summary ------------------------------------------------------------------------------
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $runDir 'summary.json') -Encoding UTF8
$failed = @($summary | Where-Object status -ne 'ok').Count
Write-Host ''
Write-Host "Done. $($summary.Count - $failed) ok, $failed failed. Output: $runDir"
if ($failed) { exit 1 }
#endregion
