<#
.SYNOPSIS
    VCF 9.x: list the primary (principal) datastore of every cluster via the SDDC Manager API.

.DESCRIPTION
    Requests an API token from SDDC Manager, calls GET /v1/clusters and /v1/domains and shows, per cluster,
    the workload domain name and the primary datastore name and type.

    Credentials are asked at runtime with Get-Credential (or passed with -Credential).
    Certificate validation is ON by default. Use -SkipCertificateCheck only in a lab
    with self-signed certificates.

.EXAMPLE
    .\Get-VCFPrimaryDatastore.ps1 -SddcManagerFqdn sddc-manager.yourdomain.local

.EXAMPLE
    # Lab with a self-signed certificate
    .\Get-VCFPrimaryDatastore.ps1 -SddcManagerFqdn sddc-manager.lab.local -SkipCertificateCheck
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SddcManagerFqdn,

    [System.Management.Automation.PSCredential]
    $Credential = (Get-Credential -Message "SDDC Manager credentials (e.g. administrator@vsphere.local)"),

    # Lab only: do not validate the SDDC Manager TLS certificate
    [switch]$SkipCertificateCheck
)

$isCore = $PSVersionTable.PSEdition -eq "Core"

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
$token = $authResponse.accessToken

# 3. Query clusters
$clusterParams = @{
    Uri     = "https://$SddcManagerFqdn/v1/clusters"
    Method  = "Get"
    Headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }
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
