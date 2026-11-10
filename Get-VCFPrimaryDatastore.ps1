<#
.SYNOPSIS
    VCF 9.x: list the primary (principal) datastore of every cluster via the SDDC Manager API.

.DESCRIPTION
    Requests an API token from SDDC Manager, calls GET /v1/clusters and shows, per cluster,
    the primary datastore name, type and native ID, and the workload domain name and ID.

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

# 4. Output primary datastore per cluster
$clusterData.elements | ForEach-Object {
    [PSCustomObject]@{
        "Cluster Name"           = $_.name
        "Primary Datastore Name" = $_.primaryDatastoreName
        "Primary Datastore Type" = $_.primaryDatastoreType
        "Datastore Native ID"    = $_.primaryDatastoreNativeId
        "Domain Name"            = $_.domain.name
        "Domain ID"              = $_.domain.id
    }
} | Format-Table -AutoSize
