# Environment config

One JSON file per environment (your labs, each customer, ...), shared by **all** scripts in this repository. Set the SDDC Manager, vCenter and accounts once per environment, and switch environments with one parameter.

## Quick start

```powershell
# 1. One file per environment, next to the sample (config\*.config.json is in .gitignore)
Copy-Item .\config\environment.config.sample.json .\config\lab1.config.json
Copy-Item .\config\environment.config.sample.json .\config\customer1.config.json

# 2. Run any script against an environment
.\Get-TpmRecoveryKey\Get-TpmRecoveryKey.ps1 -Environment lab1
.\Get-LunMultipathReport\Get-LunMultipathReport.ps1 -Environment customer1

# Or keep the files somewhere else (for example outside the repository) and give the path
.\Get-VCFPrimaryDatastore\Get-VCFPrimaryDatastore.ps1 -ConfigFile D:\Configs\customer1.config.json
```

`-Environment <name>` reads `config\<name>.config.json` in this repository. `-ConfigFile <path>` reads any file.

## Layout

```json
{
  "Environment": "lab1",
  "Common":             { "SddcManager": "...", "VCenter": "...", "SddcUser": "...", "VcUser": "...", "SkipCertificateCheck": true },
  "PrimaryDatastore":   { },
  "LunMultipathReport": { "VMHost": ["..."], "CsvPath": "..." },
  "TpmRecoveryKey":     { "Cluster": ["..."] },
  "EsxiNtpServer":      { "VMHost": ["..."], "NtpServer": ["..."] },
  "VcfBackupSettings":  { "VCenter": ["..."], "SftpUser": "...", "BackupTarget": { }, "SddcManagerBackup": { }, "VCenterBackup": { } }
}
```

Each script reads the top-level keys, then `Common`, then its own section; a later one wins. Sections of other scripts are ignored, so one file serves every script. Values on the command line always win over the file. Keys that start with `_` are comments (handy to switch a key off, like `_SddcCredentialFile` in the sample).

| Section | Script |
|---|---|
| `PrimaryDatastore` | [Get-VCFPrimaryDatastore](../Get-VCFPrimaryDatastore/) |
| `LunMultipathReport` | [Get-LunMultipathReport](../Get-LunMultipathReport/) |
| `TpmRecoveryKey` | [Get-TpmRecoveryKey](../Get-TpmRecoveryKey/) |
| `EsxiNtpServer` | [Set-EsxiNtpServer](../Set-EsxiNtpServer/) |
| `VcfBackupSettings` | [Export-VcfBackupSettings](../Export-VcfBackupSettings/) and [Set-VcfBackupSettings](../Set-VcfBackupSettings/) (one section for both) |

A new script adds its own section here and in the sample. Most sections are flat; `VcfBackupSettings` also has nested blocks (`BackupTarget`, `SddcManagerBackup`, `VCenterBackup`) that only the backup scripts read.

## Keys

| Key | Used by | Meaning |
|---|---|---|
| `Environment` | all | Name shown in the console and used for `{env}` in paths. Default: the file name |
| `SddcManager` | all | SDDC Manager FQDN (a list is allowed; these scripts take the first) |
| `VCenter` | LUN, TPM, backup | vCenter FQDN (the backup scripts take a list) |
| `SddcUser` / `SddcCredentialFile` | all | SDDC Manager account |
| `VcUser` / `VcCredentialFile` | LUN, TPM | vCenter account |
| `EsxiUser` / `EsxiCredentialFile` | NTP | ESXi account (root) |
| `UseSddcCredentials` | LUN, TPM, NTP, backup | Read vCenter / ESXi passwords from the SDDC Manager vault |
| `SkipCertificateCheck` | all | **Lab only.** Skip TLS validation of SDDC Manager |
| `SftpUser` / `SftpCredentialFile` | backup | Account on the SFTP backup server |
| `EncryptionCredentialFile` | backup | Backup encryption passphrase, stored as the password of a credential file |
| `FleetManager`, `FleetUser` / `FleetCredentialFile` | backup export | VCF Operations fleet management appliance and account (admin@local) |
| `VMHost`, `NtpServer`, `Cluster`, `CsvPath`, `OutputPath` | per script | See the script's README |

Paths can use `{date}` (yyyyMMdd-HHmm), `{env}` (environment name) and `%VARIABLES%`, for example `%USERPROFILE%\Reports\{env}-lun-report-{date}.csv`.

## Passwords

Never in the file. A key with `password`, `secret` or `token` in its name, anywhere in the file, stops every script. Per account use one of:

- `<X>User`: the script asks for that user's password.
- `<X>CredentialFile`: a file made once with `Get-Credential | Export-Clixml %USERPROFILE%\creds\lab1-sddc.xml`. It is encrypted for your Windows account on that machine (DPAPI), so it is useless on another machine or account.
- `UseSddcCredentials: true` (VCF): only the SDDC Manager login is needed; the vCenter and ESXi passwords come from the SDDC Manager vault (needs the ADMIN role).
