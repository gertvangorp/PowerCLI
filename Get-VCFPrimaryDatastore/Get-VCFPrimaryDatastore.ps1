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

.PARAMETER SddcManagerFqdn
    FQDN of SDDC Manager. Config: SddcManagerFqdn (or SddcManager).

.PARAMETER Credential
    SDDC Manager account. Config: SddcUser (prompt) or SddcCredentialFile.

.PARAMETER ConfigFile
    Optional JSON config file. Command line wins over the file. Passwords are refused in the file.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the SDDC Manager TLS certificate.

.EXAMPLE
    .\Get-VCFPrimaryDatastore.ps1 -SddcManagerFqdn sddc-manager.yourdomain.local

.EXAMPLE
    # Lab with a self-signed certificate
    .\Get-VCFPrimaryDatastore.ps1 -SddcManagerFqdn sddc-manager.lab.local -SkipCertificateCheck

.EXAMPLE
    .\Get-VCFPrimaryDatastore.ps1 -ConfigFile .\primary-datastore.config.json

.NOTES
    Version: 1.1 (2026-11-10)
    Requires Windows PowerShell 5.1 or PowerShell 7+. No PowerCLI modules needed.
#>
[CmdletBinding()]
param(
    [string]$SddcManagerFqdn,

    [System.Management.Automation.PSCredential]
    $Credential,

    [string]$ConfigFile,

    # Lab only: do not validate the SDDC Manager TLS certificate
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$isCore = $PSVersionTable.PSEdition -eq "Core"

#region Config file ----------------------------------------------------------------------------
# Order of precedence: command line > config file > prompt. Passwords are never read from the file.
if ($ConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
    $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    $cfgKeys = @($cfg.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
    $secretKeys = @($cfgKeys | Where-Object { $_ -match 'password|secret|token' })
    if ($secretKeys) { throw "Config file contains $($secretKeys -join ', '). Do not store passwords in it: use SddcUser (prompt) or SddcCredentialFile (Export-Clixml)." }
    $cfgFqdn = if ($cfg.SddcManagerFqdn) { $cfg.SddcManagerFqdn } else { $cfg.SddcManager }
    if (-not $PSBoundParameters.ContainsKey('SddcManagerFqdn') -and $cfgFqdn) { $SddcManagerFqdn = [string]@($cfgFqdn)[0] }
    if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck') -and $null -ne $cfg.SkipCertificateCheck) { $SkipCertificateCheck = [switch][bool]$cfg.SkipCertificateCheck }
    if (-not $PSBoundParameters.ContainsKey('Credential')) {
        if ($cfg.SddcCredentialFile) { $Credential = Import-Clixml ([Environment]::ExpandEnvironmentVariables($cfg.SddcCredentialFile)) }
        elseif ($cfg.SddcUser) { $Credential = Get-Credential -UserName $cfg.SddcUser -Message "Password for $($cfg.SddcUser) (SDDC Manager)" }
    }
}
if (-not $SddcManagerFqdn) { throw 'No SDDC Manager given. Use -SddcManagerFqdn or "SddcManagerFqdn" in the config file.' }
if (-not $Credential) { $Credential = Get-Credential -Message "SDDC Manager credentials (e.g. administrator@vsphere.local)" }
#endregion

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
    Uri         = "https://$SddcManagerFqdn/v1/tokens"
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
    Uri     = "https://$SddcManagerFqdn/v1/clusters"
    Method  = "Get"
    Headers = @{ "Authorization" = "Bearer $token" }
}
if ($isCore -and $SkipCertificateCheck) { $clusterParams["SkipCertificateCheck"] = $true }

$clusterData = Invoke-RestMethod @clusterParams

# 4. Query domains: /v1/clusters only returns the domain ID, so look up the names
$domainParams = $clusterParams.Clone()
$domainParams["Uri"] = "https://$SddcManagerFqdn/v1/domains"
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
