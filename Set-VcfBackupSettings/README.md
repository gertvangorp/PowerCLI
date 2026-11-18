# Set-VcfBackupSettings

Sets the file-based backup configuration of a VCF environment from the environment config: the SFTP backup target, schedule, retention and encryption passphrase on **SDDC Manager**, and a backup schedule on **every vCenter** (VAMI). Use it to configure a new environment the same way every time, or to change the SFTP server or schedule everywhere at once.

**This script changes configuration.** Run it with `-WhatIf` first, and run [Export-VcfBackupSettings](../Export-VcfBackupSettings/) before and after to keep a record.

Fleet management (VCF Operations) backup settings are not set yet: its API paths differ between builds. The export script can read them.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no PowerCLI modules needed)
- HTTPS (443) to SDDC Manager and every vCenter
- An SFTP server reachable from SDDC Manager and the vCenters, with its SSH host key fingerprint (`SHA256:...`)
- Accounts: SDDC Manager (`administrator@vsphere.local`, ADMIN role for `-UseSddcCredentials`), vCenter SSO administrator, the SFTP account

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-Environment` / `-ConfigFile` | Yes, one of them | The schedule and target come from the section `VcfBackupSettings` |
| `-Component` | No | `All` (default), `SddcManager`, `vCenter` |
| `-SddcManager` | For SDDC Manager or the vault | SDDC Manager FQDN. Config: `SddcManager` |
| `-SddcCredential` | No | SDDC Manager account. Config: `SddcUser` / `SddcCredentialFile` |
| `-VCenter` | For vCenter | One or more vCenter FQDNs. Config: `VCenter` |
| `-VCenterCredential` | No | vCenter account, used for every vCenter. Config: `VcUser` / `VcCredentialFile` |
| `-UseSddcCredentials` | No | Read each vCenter's SSO administrator password from the SDDC Manager vault |
| `-SftpCredential` | No | SFTP account. Config: `SftpUser` / `SftpCredentialFile` |
| `-EncryptionCredential` | No | Backup encryption passphrase as the password of a credential (user name ignored). Config: `EncryptionCredentialFile` |
| `-TaskTimeoutMinutes` | No | How long to wait for the SDDC Manager task. Default 15 |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS certificate validation |
| `-WhatIf` / `-Confirm` | No | Show the request bodies (secrets masked) without changing anything / ask per change |

## Usage

```powershell
# 1. Fill in the section VcfBackupSettings in your environment config (see below)

# 2. Record the current settings
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -Environment lab1

# 3. See what would change: prints every request body, changes nothing
.\Set-VcfBackupSettings\Set-VcfBackupSettings.ps1 -Environment lab1 -WhatIf

# 4. Apply to SDDC Manager and every vCenter
.\Set-VcfBackupSettings\Set-VcfBackupSettings.ps1 -Environment lab1

# VCF: vCenter passwords from the SDDC Manager vault
.\Set-VcfBackupSettings\Set-VcfBackupSettings.ps1 -Environment lab1 -UseSddcCredentials

# Only the vCenters, or only SDDC Manager
.\Set-VcfBackupSettings\Set-VcfBackupSettings.ps1 -Environment lab1 -Component vCenter
.\Set-VcfBackupSettings\Set-VcfBackupSettings.ps1 -ConfigFile D:\Configs\customer1.config.json -Component SddcManager

# 5. Record the new settings
.\Export-VcfBackupSettings\Export-VcfBackupSettings.ps1 -Environment lab1
```

### Unattended (scheduled task or pipeline)

Make the credential files once, as the account that runs the task, on the machine that runs it. They are encrypted for that Windows account (DPAPI) and useless anywhere else.

```powershell
New-Item -ItemType Directory $env:USERPROFILE\creds -Force | Out-Null
Get-Credential administrator@vsphere.local | Export-Clixml $env:USERPROFILE\creds\lab1-sddc.xml
Get-Credential svc-vcfbackup               | Export-Clixml $env:USERPROFILE\creds\lab1-sftp.xml
# Only the password is used: type the encryption passphrase as the password
Get-Credential -UserName encryption -Message 'Backup encryption passphrase' | Export-Clixml $env:USERPROFILE\creds\lab1-backup-encryption.xml
```

Then set `SddcCredentialFile`, `SftpCredentialFile` and `EncryptionCredentialFile` in the config (drop the leading `_` of the sample keys), and run with `-UseSddcCredentials -Confirm:$false`.

## Config file

This script uses the shared **environment config**, see [config/README.md](../config/README.md). It reads the top-level keys, then `Common`, then the section **`VcfBackupSettings`**, which it shares with [Export-VcfBackupSettings](../Export-VcfBackupSettings/). From [the sample](../config/environment.config.sample.json):

```json
"VcfBackupSettings": {
  "VCenter": ["vc01.lab1.local"],
  "SftpUser": "svc-vcfbackup",
  "_SftpCredentialFile": "%USERPROFILE%\\creds\\lab1-sftp.xml",
  "_EncryptionCredentialFile": "%USERPROFILE%\\creds\\lab1-backup-encryption.xml",
  "BackupTarget": {
    "Server": "sftp01.lab1.local",
    "Port": 22,
    "SshFingerprint": "SHA256:REPLACE_WITH_SFTP_HOST_KEY_FINGERPRINT"
  },
  "SddcManagerBackup": {
    "Enabled": true,
    "DirectoryPath": "/backups/sddc",
    "Frequency": "WEEKLY",
    "DaysOfWeek": ["SUNDAY", "WEDNESDAY"],
    "HourOfTheDay": 2,
    "MinuteOfTheHour": 0,
    "TakeBackupOnStateChange": true,
    "RetainMostRecent": 5,
    "RetainHourlyDays": 1,
    "RetainDailyDays": 7
  },
  "VCenterBackup": {
    "Enabled": true,
    "ScheduleId": "default",
    "DirectoryPath": "/backups/vcenter/{vcenter}",
    "IncludeStatsEventsTasks": false,
    "Days": ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"],
    "Hour": 23,
    "Minute": 0,
    "MaxCount": 7
  }
}
```

| Key | Meaning |
|---|---|
| `BackupTarget.Server`, `Port` | SFTP server used by SDDC Manager and the vCenters |
| `BackupTarget.SshFingerprint` | SSH host key fingerprint of the SFTP server, for SDDC Manager. Get it with `ssh-keyscan sftp01.corp.local | ssh-keygen -lf -` |
| `SddcManagerBackup.Enabled` | `false` skips SDDC Manager |
| `SddcManagerBackup.Frequency` | `WEEKLY` (with `DaysOfWeek`) or `HOURLY` |
| `SddcManagerBackup.Retain*` | Retention: most recent backups, days of hourly backups, days of daily backups |
| `VCenterBackup.Enabled` | `false` skips the vCenters |
| `VCenterBackup.ScheduleId` | VAMI schedule name; created when missing, updated when it exists |
| `VCenterBackup.DirectoryPath` | Folder on the SFTP server. `{vcenter}` becomes the vCenter short name |
| `VCenterBackup.IncludeStatsEventsTasks` | Also back up statistics, events and tasks (larger backups) |
| `VCenterBackup.Days`, `Hour`, `Minute`, `MaxCount` | Schedule and number of backups to keep |

Every vCenter in `VCenter` gets the same schedule.

## Credentials

The script never stores or prints a password; `-WhatIf` and `-Verbose` show `***`. A key with `password`, `secret` or `token` in its name stops the script. Per account it takes the first of: the parameter, `<X>CredentialFile`, `<X>User` (asks for the password), and otherwise asks with `Get-Credential`. With `-UseSddcCredentials` the vCenter SSO administrator password comes from the SDDC Manager vault (`GET /v1/credentials`, the API counterpart of `lookup_passwords`; the SDDC Manager account needs the **ADMIN** role). An account set with `<X>User` is asked for when the script starts, also with `-WhatIf`. The encryption passphrase, and the SFTP password when `SftpUser` is not set, are only asked when a change is really made.

## Output

One line per component; the exit code is 1 when something failed.

```
Component Server            Status Detail
--------- ------            ------ ------
sddc      sddc01.corp.local OK     SUCCESSFUL
vcenter   vc01.corp.local   OK     updated schedule default
vcenter   vc02.corp.local   OK     created schedule default
```

## How it works

| Component | Calls |
|---|---|
| SDDC Manager | `POST /v1/tokens`, `PATCH /v1/system/backup-configuration` (SFTP location, schedule, retention, encryption passphrase), then polls `GET /v1/tasks/{id}` |
| vCenter (VAMI) | `POST /api/session`, `GET /api/appliance/recovery/backup/schedules`, then `PATCH` (exists) or `POST` (new) `/api/appliance/recovery/backup/schedules/{id}` |
