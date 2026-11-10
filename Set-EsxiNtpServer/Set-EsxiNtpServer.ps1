<#
.SYNOPSIS
    Sets the NTP servers on one or more ESXi hosts, by connecting to each host directly.

.DESCRIPTION
    For every host: connects directly to the ESXi host (not through vCenter), replaces the NTP server
    list with -NtpServer, sets the ntpd service policy to "on" (start and stop with host) and
    restarts (or starts) the service. Hosts that already have exactly the requested list are only
    checked for the service state.

    One host failing does not stop the others: the result object shows Status = Failed with the reason.

    The script changes configuration. Use -WhatIf to see what it would do.

    Credentials (ESXi root account), in this order:
      -Credential, or EsxiUser / EsxiCredentialFile in the config file,
      -UseSddcCredentials: the root password of each host is read from the SDDC Manager vault
                           (GET /v1/credentials, needs the SDDC Manager ADMIN role),
      otherwise Get-Credential asks once and the same account is used for every host.

    On VCF-managed hosts, NTP is normally set through SDDC Manager. Use this script for hosts
    outside VCF, during bring-up preparation, or to repair a host.

.PARAMETER VMHost
    ESXi host names (FQDN). Config: VMHost.

.PARAMETER NtpServer
    NTP servers to configure, in order. Config: NtpServer.

.PARAMETER Credential
    ESXi account (root). Config: EsxiUser (prompt) or EsxiCredentialFile (Export-Clixml).

.PARAMETER ConfigFile
    Optional JSON config file. Command line wins over the file. Passwords are refused in the file.

.PARAMETER UseSddcCredentials
    Read the root password of each host from the SDDC Manager vault. Needs -SddcManager.

.PARAMETER SddcManager
    SDDC Manager FQDN, only for -UseSddcCredentials. Config: SddcManager.

.PARAMETER SddcCredential
    SDDC Manager account with the ADMIN role. Config: SddcUser (prompt) or SddcCredentialFile.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the SDDC Manager TLS certificate. For the ESXi connection itself,
    PowerCLI's own setting applies (Set-PowerCLIConfiguration -InvalidCertificateAction).

.EXAMPLE
    .\Set-EsxiNtpServer.ps1 -VMHost esx01.corp.local, esx02.corp.local -NtpServer 0.be.pool.ntp.org, 1.be.pool.ntp.org -WhatIf

.EXAMPLE
    .\Set-EsxiNtpServer.ps1 -ConfigFile .\ntp.config.json

.EXAMPLE
    .\Set-EsxiNtpServer.ps1 -ConfigFile .\ntp.config.json -UseSddcCredentials -SddcManager sddc01.corp.local

.NOTES
    Version: 2.0.1 (2026-11-10)
    Requires PowerShell 7 or Windows PowerShell 5.1 and VCF.PowerCLI (or VMware.PowerCLI).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$VMHost,
    [string[]]$NtpServer,
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
    $settings = @{ VMHost = 'list'; NtpServer = 'list'; SddcManager = 'string'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
    foreach ($k in $settings.Keys) {
        if ($k -notin $cfgKeys -or $PSBoundParameters.ContainsKey($k) -or $null -eq $cfg.$k) { continue }
        $v = switch ($settings[$k]) { 'list' { [string[]]@($cfg.$k | Where-Object { $_ }) } 'switch' { [switch][bool]$cfg.$k } default { [string]$cfg.$k } }
        Set-Variable -Name $k -Value $v
    }
    $credMap = [ordered]@{ Esxi = 'Credential'; Sddc = 'SddcCredential' }
    foreach ($pre in $credMap.Keys) {
        $name = $credMap[$pre]
        if ($PSBoundParameters.ContainsKey($name)) { continue }
        $file = $cfg."${pre}CredentialFile"; $user = $cfg."${pre}User"
        if ($file) { Set-Variable -Name $name -Value (Import-Clixml ([Environment]::ExpandEnvironmentVariables($file))) }
        elseif ($user -and -not ($pre -eq 'Esxi' -and $UseSddcCredentials)) { Set-Variable -Name $name -Value (Get-Credential -UserName $user -Message "Password for $user ($pre)") }
    }
}
if (-not $VMHost) { throw 'No hosts given. Use -VMHost or "VMHost" in the config file.' }
if (-not $NtpServer) { throw 'No NTP servers given. Use -NtpServer or "NtpServer" in the config file.' }
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

$vault = $null
if ($UseSddcCredentials -and -not $Credential) {
    if (-not $SddcManager) { throw '-UseSddcCredentials needs -SddcManager (or "SddcManager" in the config file).' }
    if ($SkipCertificateCheck) {
        Write-Warning 'SDDC Manager certificate validation is disabled. Use this in a lab only.'
        if (-not $isCore) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
    if (-not $SddcCredential) { $SddcCredential = Get-Credential -Message 'SDDC Manager account with the ADMIN role' }
    Write-Host "Reading ESXi root passwords from the SDDC Manager vault on $SddcManager ..." -ForegroundColor Cyan
    $vault = Get-SddcVault
    if (-not $vault) { Write-Warning 'GET /v1/credentials returned nothing. The account needs the SDDC Manager ADMIN role.' }
}
#endregion

if (-not $Credential -and -not $vault) { $Credential = Get-Credential -UserName root -Message 'ESXi account (used for every host)' }

foreach ($esxiName in $VMHost) {
    $result = [ordered]@{ VMHost = $esxiName; NtpServers = $null; ServicePolicy = $null; ServiceRunning = $null; Status = 'OK'; Message = '' }
    $vi = $null
    try {
        $cred = $Credential
        if (-not $cred) {
            $cred = Get-VaultCredential -Vault $vault -ResourceType 'ESXI' -Name $esxiName -UserName 'root'
            if (-not $cred) { throw "No root password for $esxiName in the SDDC Manager vault. Use -Credential." }
        }

        Write-Host "Connecting to $esxiName ..." -ForegroundColor Cyan
        $vi = Connect-VIServer -Server $esxiName -Credential $cred -NotDefault -WarningAction SilentlyContinue
        $esx = Get-VMHost -Server $vi

        # NTP server list: only change it when it differs from the requested list.
        $current = @(Get-VMHostNtpServer -VMHost $esx -Server $vi)
        if (($current -join ',') -ne ($NtpServer -join ',')) {
            if ($PSCmdlet.ShouldProcess($esxiName, "Set NTP servers to $($NtpServer -join ', ') (now: $(if ($current) { $current -join ', ' } else { 'none' }))")) {
                if ($current) { Remove-VMHostNtpServer -VMHost $esx -NtpServer $current -Server $vi -Confirm:$false | Out-Null }
                foreach ($ntp in $NtpServer) { Add-VMHostNtpServer -VMHost $esx -NtpServer $ntp -Server $vi -Confirm:$false | Out-Null }
                $result.Message = "NTP servers changed (were: $(if ($current) { $current -join ', ' } else { 'none' }))"
            }
            else { $result.Message = "WhatIf: NTP servers would change (now: $(if ($current) { $current -join ', ' } else { 'none' }))" }
        }
        else { $result.Message = 'NTP servers already correct' }

        # ntpd: start and stop with the host, and (re)start so the new list is used.
        $svc = Get-VMHostService -VMHost $esx -Server $vi | Where-Object { $_.Key -eq 'ntpd' }
        if ($svc.Policy -ne 'on' -and $PSCmdlet.ShouldProcess($esxiName, 'Set ntpd policy to "on"')) {
            $svc = Set-VMHostService -HostService $svc -Policy On -Confirm:$false
        }
        if ($PSCmdlet.ShouldProcess($esxiName, $(if ($svc.Running) { 'Restart ntpd' } else { 'Start ntpd' }))) {
            $svc = if ($svc.Running) { Restart-VMHostService -HostService $svc -Confirm:$false } else { Start-VMHostService -HostService $svc -Confirm:$false }
        }

        $result.NtpServers = (Get-VMHostNtpServer -VMHost $esx -Server $vi) -join ', '
        $result.ServicePolicy = $svc.Policy
        $result.ServiceRunning = $svc.Running
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        Write-Warning "$esxiName : $($_.Exception.Message)"
    }
    finally {
        # -WhatIf:$false: also close the session in a -WhatIf run.
        if ($vi) { Disconnect-VIServer -Server $vi -Confirm:$false -WhatIf:$false -ErrorAction SilentlyContinue }
    }
    [pscustomobject]$result
}
