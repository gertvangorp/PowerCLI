#Requires -Version 5.1
<#
.SYNOPSIS
    VCF 9.x: list the primary (principal) datastore of every cluster via the SDDC Manager API.

.DESCRIPTION
    Requests an API token from SDDC Manager, calls GET /v1/clusters and /v1/domains and shows, per cluster,
    the workload domain name and the primary datastore name and type.

    Credentials are asked at runtime with Get-Credential, passed with -Credential, or taken from the
    config file (SddcUser = prompt for the password, SddcCredentialFile = Export-Clixml file).
    Certificate validation is ON by default. Use -SkipCertificateCheck only in a lab
    with self-signed certificates.

    The script only reads. It changes nothing in SDDC Manager or vCenter.

.PARAMETER SddcManager
    FQDN of SDDC Manager. Config: SddcManager. The old name -SddcManagerFqdn still works.

.PARAMETER Credential
    SDDC Manager account. Config: SddcUser (prompt) or SddcCredentialFile.

.PARAMETER Environment
    Name of an environment config: reads config\<name>.config.json in this repository.

.PARAMETER ConfigFile
    Path to an environment config file (JSON). Command line wins over the file. Passwords are refused in the file.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the SDDC Manager TLS certificate.

.EXAMPLE
    .\Get-VCFPrimaryDatastore.ps1 -SddcManager sddc-manager.yourdomain.local

.EXAMPLE
    # Lab with a self-signed certificate
    .\Get-VCFPrimaryDatastore.ps1 -SddcManager sddc-manager.lab.local -SkipCertificateCheck

.EXAMPLE
    .\Get-VCFPrimaryDatastore.ps1 -ConfigFile D:\Configs\customer1.config.json

.EXAMPLE
    # Environment config: reads config\lab1.config.json
    .\Get-VCFPrimaryDatastore.ps1 -Environment lab1

.NOTES
    Name        : Get-VCFPrimaryDatastore.ps1
    Version     : 2.1
    Date        : 2026-11-10
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : Windows PowerShell 5.1 or PowerShell 7+. No PowerCLI modules needed.
    Config      : one file per environment, see config\environment.config.sample.json
    License     : provided as is, without warranty. Test in a lab first.

    Version history
    2.1  2026-11-10  Shared environment config (-Environment), standard header, -SddcManager (alias -SddcManagerFqdn).
    2.0  2026-11-10  Moved to its own folder, -ConfigFile.
    1.0              First version (SDDC Manager API, -SkipCertificateCheck).

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Get-VCFPrimaryDatastore
#>
[CmdletBinding()]
param(
    [Alias('SddcManagerFqdn')]
    [string]$SddcManager,

    [System.Management.Automation.PSCredential]
    $Credential,

    [string]$Environment,
    [string]$ConfigFile,

    # Lab only: do not validate the SDDC Manager TLS certificate
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '2.1 (2026-11-10)'
Write-Host "Get-VCFPrimaryDatastore.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq "Core"

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'PrimaryDatastore'
$ConfigSettings = @{ SddcManager = 'first'; SkipCertificateCheck = 'switch' }
$ConfigCredentials = [ordered]@{ Sddc = 'Credential' }

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
if (-not $SddcManager) { throw 'No SDDC Manager given. Use -SddcManager or "SddcManager" in the config file.' }
if (-not $Credential) { $Credential = Get-Credential -Message "SDDC Manager credentials (e.g. administrator@vsphere.local)" }

# 1. Optional certificate bypass (lab only)
if ($SkipCertificateCheck) {
    Write-Warning "Certificate validation is disabled. Use this in a lab only."
    if (-not $isCore) {
        # Windows PowerShell 5.1
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}
if (-not $isCore) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# 2. Acquire token
$authBody = @{
    username = $Credential.UserName
    password = $Credential.GetNetworkCredential().Password
} | ConvertTo-Json

$tokenParams = @{
    Uri         = "https://$SddcManager/v1/tokens"
    Method      = "Post"
    Body        = $authBody
    ContentType = "application/json"
}
if ($isCore -and $SkipCertificateCheck) { $tokenParams["SkipCertificateCheck"] = $true }

$authResponse = Invoke-RestMethod @tokenParams
$authBody = $null
$tokenParams = $null
$token = $authResponse.accessToken

# 3. Query clusters
$clusterParams = @{
    Uri     = "https://$SddcManager/v1/clusters"
    Method  = "Get"
    Headers = @{ "Authorization" = "Bearer $token" }
}
if ($isCore -and $SkipCertificateCheck) { $clusterParams["SkipCertificateCheck"] = $true }

$clusterData = Invoke-RestMethod @clusterParams

# 4. Query domains: /v1/clusters only returns the domain ID, so look up the names
$domainParams = $clusterParams.Clone()
$domainParams["Uri"] = "https://$SddcManager/v1/domains"
$domainNames = @{}
(Invoke-RestMethod @domainParams).elements | ForEach-Object { $domainNames[$_.id] = $_.name }

# 5. Output primary datastore per cluster
$clusterData.elements | ForEach-Object {
    [PSCustomObject]@{
        "Domain Name"            = $domainNames[$_.domain.id]
        "Cluster Name"           = $_.name
        "Primary Datastore Name" = $_.primaryDatastoreName
        "Primary Datastore Type" = $_.primaryDatastoreType
    }
} | Sort-Object "Domain Name", "Cluster Name" | Format-Table -AutoSize
