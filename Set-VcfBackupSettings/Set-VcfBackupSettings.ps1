#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the backup configuration (SFTP target, schedule, retention, encryption) to SDDC Manager
    and vCenter (VAMI) from the environment config file.

.DESCRIPTION
    Reads the section VcfBackupSettings of the environment config and:
      SDDC Manager   PATCH /v1/system/backup-configuration, then waits for the task
      vCenter (VAMI) POST  /api/appliance/recovery/backup/schedules/{id}   (create)
                     PATCH /api/appliance/recovery/backup/schedules/{id}   (update, when it exists)

    Every vCenter gets the same schedule. Use {vcenter} in VCenterBackup.DirectoryPath to give each
    vCenter its own folder on the SFTP server (it becomes the short host name).

    The script changes configuration. Run it with -WhatIf first: it prints each request body with
    the secrets masked, and changes nothing. Run Export-VcfBackupSettings.ps1 before and after to
    keep a record of the change.

    Credentials. Nothing secret is ever read from the config file:
      SDDC Manager     -SddcCredential, or SddcUser / SddcCredentialFile
      vCenter          -VCenterCredential, or VcUser / VcCredentialFile, or -UseSddcCredentials
                       (the SSO administrator password of each vCenter comes from the SDDC Manager
                       vault, GET /v1/credentials, needs the ADMIN role)
      SFTP account     -SftpCredential, or SftpUser / SftpCredentialFile
      Encryption       -EncryptionCredential, or EncryptionCredentialFile. Only the password of this
                       credential is used (the backup encryption passphrase); the user name is ignored.
    Anything missing is asked with Get-Credential. For a scheduled task, make the credential files once
    with Export-Clixml under the account that runs the task.

    Fleet management backup settings are not applied yet: the API paths differ between builds and
    must be confirmed first. Export-VcfBackupSettings.ps1 can read them.

.PARAMETER Component
    What to configure: All (default), SddcManager, vCenter.

.PARAMETER SddcManager
    SDDC Manager FQDN. Config: SddcManager.

.PARAMETER SddcCredential
    SDDC Manager account. Config: SddcUser (prompt) or SddcCredentialFile (Export-Clixml).

.PARAMETER VCenter
    One or more vCenter FQDNs. Config: VCenter (a list is allowed).

.PARAMETER VCenterCredential
    vCenter account, used for every vCenter. Config: VcUser (prompt) or VcCredentialFile.

.PARAMETER UseSddcCredentials
    Read the vCenter SSO administrator password of each vCenter from the SDDC Manager vault.

.PARAMETER SftpCredential
    Account on the SFTP backup server. Config: SftpUser (prompt) or SftpCredentialFile.

.PARAMETER EncryptionCredential
    Backup encryption passphrase, as the password of a credential. Config: EncryptionCredentialFile.

.PARAMETER TaskTimeoutMinutes
    How long to wait for the SDDC Manager task. Default 15.

.PARAMETER Environment
    Name of an environment config: reads config\<name>.config.json in this repository.

.PARAMETER ConfigFile
    Path to an environment config file (JSON). Command line wins over the file. Passwords are refused in the file.

.PARAMETER SkipCertificateCheck
    Lab only: do not validate the TLS certificates of SDDC Manager and vCenter.

.EXAMPLE
    # See what would change
    .\Set-VcfBackupSettings.ps1 -Environment lab1 -WhatIf

.EXAMPLE
    # Apply to SDDC Manager and every vCenter, vCenter passwords from the SDDC Manager vault
    .\Set-VcfBackupSettings.ps1 -Environment lab1 -UseSddcCredentials

.EXAMPLE
    # Only the vCenters, config file outside the repository
    .\Set-VcfBackupSettings.ps1 -ConfigFile D:\Configs\customer1.config.json -Component vCenter

.NOTES
    Name        : Set-VcfBackupSettings.ps1
    Version     : 1.0
    Date        : 2026-11-18
    Author      : Gert (https://www.v-consult.be)
    Repository  : https://github.com/gertvangorp/PowerCLI
    Requires    : Windows PowerShell 5.1 or PowerShell 7+. No PowerCLI modules needed.
    Config      : one file per environment, see config\environment.config.sample.json (section VcfBackupSettings)
    License     : provided as is, without warranty. Test in a lab first.
    Exit code   : 0 = all ok, 1 = something failed.

    Version history
    1.0  2026-11-18  First public version: shared environment config, credential files instead of
                     secret references, standard header.

.LINK
    https://github.com/gertvangorp/PowerCLI/tree/main/Set-VcfBackupSettings
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('All', 'SddcManager', 'vCenter')]
    [string[]]$Component = 'All',

    [string]$SddcManager,
    [pscredential]$SddcCredential,

    [string[]]$VCenter,
    [pscredential]$VCenterCredential,
    [switch]$UseSddcCredentials,

    [pscredential]$SftpCredential,
    [pscredential]$EncryptionCredential,

    [int]$TaskTimeoutMinutes = 15,

    [string]$Environment,
    [string]$ConfigFile,

    # Lab only: do not validate TLS certificates
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.0 (2026-11-18)'
Write-Host "Set-VcfBackupSettings.ps1 version $script:ScriptVersion" -ForegroundColor Cyan
$isCore = $PSVersionTable.PSEdition -eq 'Core'

# Settings this script reads from the environment config (key = parameter name).
$ConfigSection = 'VcfBackupSettings'
$ConfigSettings = @{ SddcManager = 'first'; VCenter = 'list'; UseSddcCredentials = 'switch'; SkipCertificateCheck = 'switch' }
$ConfigCredentials = [ordered]@{ Sddc = 'SddcCredential'; Vc = 'VCenterCredential'; Sftp = 'SftpCredential'; Encryption = 'EncryptionCredential' }

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

#region Settings from the config file ---------------------------------------------------------
if (-not $ConfigFile) {
    throw 'This script needs an environment config: -Environment <name> or -ConfigFile <path>. See config\environment.config.sample.json, section VcfBackupSettings.'
}
$section = $cfgRaw.$ConfigSection
if (-not $section) { throw "Section '$ConfigSection' is missing in $ConfigFile. Copy it from config\environment.config.sample.json." }
$target = $section.BackupTarget
if (-not $target -or -not $target.Server) { throw "$ConfigSection.BackupTarget.Server is missing in $ConfigFile." }
$port = if ($target.Port) { [int]$target.Port } else { 22 }
$sddcBackup = $section.SddcManagerBackup
$vcBackup = $section.VCenterBackup
#endregion

#region Helpers ------------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
function Add-Result($Comp, $Server, $Status, $Detail) {
    $results.Add([pscustomobject]@{ Component = $Comp; Server = $Server; Status = $Status; Detail = $Detail })
}
function Test-Selected([string]$Name) { $Component -contains 'All' -or $Component -contains $Name }

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

function Get-PlainText([pscredential]$Cred) {
    # Without a credential (-WhatIf) the body shows *** instead of the secret.
    if ($Cred) { $Cred.GetNetworkCredential().Password } else { '***' }
}

function Show-Body($Body) {
    # A copy of the request body with secrets masked, for -WhatIf and -Verbose.
    $json = $Body | ConvertTo-Json -Depth 10
    $json -replace '("(?i:[a-z_]*(password|passphrase))"\s*:\s*)"[^"]*"', '$1"***"'
}

function Get-TargetSecret {
    # The SFTP account and the encryption passphrase are only asked when a change is really made.
    if (-not $script:SftpCredential) {
        $u = if ($cfg['SftpUser']) { [string]$cfg['SftpUser'] } else { $null }
        $script:SftpCredential = Read-Credential -UserName $u -Message "SFTP account on $($target.Server)"
    }
    if (-not $script:EncryptionCredential) {
        $script:EncryptionCredential = Read-Credential -UserName 'encryption' -Message 'Backup encryption passphrase (the user name is ignored)'
    }
}

function Get-SddcToken {
    if (-not $script:sddcToken) {
        if (-not $script:SddcCredential) { $script:SddcCredential = Get-Credential -Message "SDDC Manager account ($SddcManager)" }
        $body = @{ username = $SddcCredential.UserName; password = $SddcCredential.GetNetworkCredential().Password }
        $script:sddcToken = (Invoke-SddcApi -Method Post -Path '/v1/tokens' -Body $body).accessToken
    }
    $script:sddcToken
}

function New-SddcBackupBody([pscredential]$Sftp, [pscredential]$Encryption) {
    $s = $sddcBackup
    $user = if ($Sftp) { $Sftp.UserName } else { [string]$cfg['SftpUser'] }
    [ordered]@{
        backupLocations = @(@{
                server         = $target.Server
                port           = $port
                protocol       = 'SFTP'
                username       = $user
                password       = (Get-PlainText $Sftp)
                directoryPath  = $s.DirectoryPath
                sshFingerprint = $target.SshFingerprint
            })
        backupSchedules = @(@{
                resourceType            = 'SDDC_MANAGER'
                frequency               = $s.Frequency
                daysOfWeek              = @($s.DaysOfWeek)
                hourOfTheDay            = [int]$s.HourOfTheDay
                minuteOfTheHour         = [int]$s.MinuteOfTheHour
                takeBackupOnStateChange = [bool]$s.TakeBackupOnStateChange
                retentionPolicy         = @{
                    numberOfMostRecentBackups   = [int]$s.RetainMostRecent
                    numberOfDaysOfHourlyBackups = [int]$s.RetainHourlyDays
                    numberOfDaysOfDailyBackups  = [int]$s.RetainDailyDays
                }
            })
        encryption      = @{ passphrase = (Get-PlainText $Encryption) }
    }
}

function New-VCenterBackupSpec([string]$Server, [pscredential]$Sftp, [pscredential]$Encryption) {
    $b = $vcBackup
    $user = if ($Sftp) { $Sftp.UserName } else { [string]$cfg['SftpUser'] }
    $dir = ([string]$b.DirectoryPath).Replace('{vcenter}', ($Server -split '\.')[0])
    # 'seat' = stats, events and tasks; the core inventory and configuration are always included.
    $parts = if ($b.IncludeStatsEventsTasks) { @('seat') } else { @() }
    [ordered]@{
        parts             = $parts
        location          = 'sftp://{0}:{1}{2}' -f $target.Server, $port, $dir
        location_user     = $user
        location_password = (Get-PlainText $Sftp)
        backup_password   = (Get-PlainText $Encryption)
        enable            = $true
        recurrence_info   = @{ days = @($b.Days); hour = [int]$b.Hour; minute = [int]$b.Minute }
        retention_info    = @{ max_count = [int]$b.MaxCount }
    }
}
#endregion

#region Setup --------------------------------------------------------------------------------
if ($SkipCertificateCheck) {
    Write-Warning 'Certificate validation is disabled. Use this in a lab only.'
    if (-not $isCore) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
}
if (-not $isCore) { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 }
#endregion

#region SDDC Manager -------------------------------------------------------------------------
if ((Test-Selected 'SddcManager') -and $sddcBackup -and $sddcBackup.Enabled) {
    if (-not $SddcManager) { throw 'No SDDC Manager given. Use -SddcManager or "SddcManager" in the config file.' }
    Write-Host "SDDC Manager: $SddcManager" -ForegroundColor Cyan
    try {
        $preview = New-SddcBackupBody
        Write-Verbose (Show-Body $preview)
        if ($PSCmdlet.ShouldProcess($SddcManager, "PATCH backup-configuration`n$(Show-Body $preview)")) {
            Get-TargetSecret
            $body = New-SddcBackupBody -Sftp $SftpCredential -Encryption $EncryptionCredential
            $token = Get-SddcToken
            # Invoke-RestCall, not Invoke-SddcApi: the body is nested deeper than ConvertTo-Json's default depth.
            $task = Invoke-RestCall -Method Patch -Uri "https://$SddcManager/v1/system/backup-configuration" -Headers @{ Authorization = "Bearer $token" } -Body $body
            $body = $null

            $status = 'SUBMITTED'
            if ($task -and $task.PSObject.Properties['id']) {
                $deadline = (Get-Date).AddMinutes($TaskTimeoutMinutes)
                do {
                    Start-Sleep -Seconds 10
                    $status = (Invoke-SddcApi -Path "/v1/tasks/$($task.id)" -Token $token).status
                    Write-Host "  task $($task.id): $status"
                } while ($status -match '(?i)^(IN_PROGRESS|PENDING|SUBMITTED)$' -and (Get-Date) -lt $deadline)
            }
            if ($status -match '(?i)^(SUCCESSFUL|SUBMITTED)$') { Add-Result 'sddc' $SddcManager 'OK' $status }
            else { Add-Result 'sddc' $SddcManager 'Failed' "task status $status" }
        }
        else { Add-Result 'sddc' $SddcManager 'WhatIf' 'not applied' }
    }
    catch {
        Write-Warning "  $($_.Exception.Message)"
        Add-Result 'sddc' $SddcManager 'Failed' $_.Exception.Message
    }
}
#endregion

#region vCenter (VAMI) -----------------------------------------------------------------------
if ((Test-Selected 'vCenter') -and $vcBackup -and $vcBackup.Enabled) {
    if (-not $VCenter) { Write-Warning 'No vCenter given. Use -VCenter or "VCenter" in the config file.' }
    $scheduleId = if ($vcBackup.ScheduleId) { [string]$vcBackup.ScheduleId } else { 'default' }
    $vault = $null
    $askedVcCredential = $null
    foreach ($vc in @($VCenter | Where-Object { $_ })) {
        Write-Host "vCenter: $vc" -ForegroundColor Cyan
        try {
            $preview = New-VCenterBackupSpec -Server $vc
            Write-Verbose (Show-Body $preview)
            if ($PSCmdlet.ShouldProcess($vc, "set backup schedule '$scheduleId'`n$(Show-Body $preview)")) {
                Get-TargetSecret
                $cred = $VCenterCredential
                if (-not $cred -and $UseSddcCredentials) {
                    if (-not $SddcManager) { throw '-UseSddcCredentials needs -SddcManager (or "SddcManager" in the config file).' }
                    if (-not $vault) {
                        if (-not $SddcCredential) { $SddcCredential = Get-Credential -Message 'SDDC Manager account with the ADMIN role' }
                        Write-Host "  Reading the vCenter SSO accounts from the SDDC Manager vault on $SddcManager ..." -ForegroundColor Cyan
                        $vault = Get-SddcVault
                    }
                    # The SSO administrator is stored as credentialType SSO, under resourceType PSC (or VCENTER).
                    $cred = Get-VaultCredential -Vault $vault -ResourceType 'PSC', 'VCENTER' -Name $vc -CredentialType 'SSO'
                    if (-not $cred) { Write-Warning "  No SSO account for $vc in the SDDC Manager vault (needs the ADMIN role). Asking instead." }
                }
                if (-not $cred) {
                    if (-not $askedVcCredential) { $askedVcCredential = Get-Credential -Message 'vCenter account (e.g. administrator@vsphere.local)' }
                    $cred = $askedVcCredential
                }

                $spec = New-VCenterBackupSpec -Server $vc -Sftp $SftpCredential -Encryption $EncryptionCredential
                $sid = Invoke-RestCall -Method Post -Uri "https://$vc/api/session" -Headers (Get-BasicAuthHeader $cred)
                $h = @{ 'vmware-api-session-id' = "$sid" }
                try {
                    $existing = Invoke-RestCall -Uri "https://$vc/api/appliance/recovery/backup/schedules" -Headers $h
                    $exists = $existing -and $existing.PSObject.Properties[$scheduleId]
                    $uri = "https://$vc/api/appliance/recovery/backup/schedules/$scheduleId"
                    if ($exists) {
                        Invoke-RestCall -Method Patch -Uri $uri -Headers $h -Body $spec | Out-Null
                        Add-Result 'vcenter' $vc 'OK' "updated schedule $scheduleId"
                    }
                    else {
                        Invoke-RestCall -Method Post -Uri $uri -Headers $h -Body $spec | Out-Null
                        Add-Result 'vcenter' $vc 'OK' "created schedule $scheduleId"
                    }
                }
                finally {
                    $spec = $null
                    try { Invoke-RestCall -Method Delete -Uri "https://$vc/api/session" -Headers $h | Out-Null } catch { Write-Verbose "Logout from $vc failed: $($_.Exception.Message)" }
                }
            }
            else { Add-Result 'vcenter' $vc 'WhatIf' 'not applied' }
        }
        catch {
            Write-Warning "  $($_.Exception.Message)"
            Add-Result 'vcenter' $vc 'Failed' $_.Exception.Message
        }
    }
}
#endregion

#region Summary ------------------------------------------------------------------------------
if (-not $results.Count) { Write-Warning 'Nothing done: check -Component and the Enabled keys in the config section.' }
$results | Format-Table -AutoSize | Out-String | Write-Host
if (@($results | Where-Object Status -eq 'Failed').Count) { exit 1 }
#endregion
