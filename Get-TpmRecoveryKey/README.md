# Get-TpmRecoveryKey

Reports the TPM recovery key (ESXi configuration encryption) of every host in one or more clusters. You need this key when a host's TPM or motherboard is replaced; without it the host can't decrypt its configuration. Run it after enabling TPM mode and keep the result in a safe place.

Per host: cluster, encryption mode (`TPM` or `NONE`), recovery ID and key. Hosts that are disconnected, have no key, or fail are reported too, with the reason, so none are silently missing.

> **The output contains secrets.** Store the keys in your password manager or vault and delete any CSV from disk afterwards. `*.csv` is in `.gitignore`.

The script only reads. It changes nothing.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- Network access to vCenter
- A vCenter account with host configuration privileges (an administrator is simplest)

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VCenter` | Yes, or in the config file | vCenter FQDN |
| `-Cluster` | No | One or more cluster names. Leave out for all hosts in vCenter |
| `-CsvPath` | No | Also export to CSV. `{date}` becomes `yyyyMMdd-HHmm` |
| `-Credential` | No | vCenter account. Config: `VcUser` / `VcCredentialFile` |
| `-ConfigFile` | No | JSON config file, see below |
| `-UseSddcCredentials` | No | Read the password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |

## Usage

```powershell
.\Get-TpmRecoveryKey.ps1 -VCenter vc01.corp.local -Cluster CL-MGMT-01 | Format-Table

# VCF: vCenter SSO account from the SDDC Manager vault
.\Get-TpmRecoveryKey.ps1 -ConfigFile .\tpm.config.json -UseSddcCredentials
```

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The config file: `VcUser` makes the script ask for that user's password, `VcCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`, the API counterpart of `lookup_passwords`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, the script uses the vCenter SSO account (credential type `SSO`).
4. Otherwise `Get-Credential` asks.

## Config file

Copy [tpm.config.sample.json](tpm.config.sample.json) to `tpm.config.json` (all `*.config.json` files are in `.gitignore`) and run with `-ConfigFile .\tpm.config.json`. Values on the command line win over the file. A key with `password`, `secret` or `token` in its name stops the script, so a password can't end up in the file by accident. Keys that start with `_` are comments.

## Output

```
VMHost           Cluster    EncryptionMode RecoveryId                             Key          Status  Message
------           -------    -------------- ----------                             ---          ------  -------
esx01.corp.local CL-MGMT-01 TPM            {3B5C...}                              2290-...     OK
esx02.corp.local CL-MGMT-01 NONE                                                               NoKey   No recovery key (TPM configuration encryption not active?)
esx03.corp.local CL-MGMT-01                                                                    Skipped Host is NotResponding
```
