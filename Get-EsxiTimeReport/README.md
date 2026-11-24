# Get-EsxiTimeReport

Checks the clock of every ESXi host against a reference time and shows the host's NTP configuration next to it, so you can spot hosts that drift, have no NTP server, or have ntpd stopped. Handy before an upgrade, when certificates or vSAN complain about time, or after changing NTP with [Set-EsxiNtpServer](../Set-EsxiNtpServer/).

Per host: cluster, host time and reference time (UTC), offset in seconds (positive = host is ahead), time protocol (NTP or PTP), NTP servers, whether ntpd runs and its startup policy. A host gets **Status `Warning`**, with the reason in `Message`, when:

- the offset is larger than `-MaxOffsetSeconds` (default 1 second),
- no NTP server is configured,
- ntpd (or ptpd for PTP hosts) is not running, or its policy is not `on` (start and stop with host).

Hosts that are not connected or fail are reported too (`Skipped` / `Failed`), so none are silently missing. A summary with the minimum, maximum and average offset and the host that is furthest off is printed at the end.

The script only reads. It changes nothing.

## Reference time

The script picks the reference per host, in this order:

1. `-UseLocalClock`: the UTC clock of the machine that runs the script.
2. `-ReferenceNtpServer <server>`: that one NTP server for every host.
3. Default: the **host's own NTP servers**, the first one in its config that answers from this machine. So each host is checked against the server it is supposed to follow.
4. If none answers (UDP 123 blocked, or a PTP host without NTP servers), the local clock, with a warning.

For an NTP reference the script asks the server once (SNTP over UDP 123) how far the local clock is off and corrects for that, so a wrong clock on your own machine does not show up as drift. The `Reference` column shows what each host was compared with (`NTP <server>` or `Local clock`).

The local time is taken halfway the host query, so the round trip to vCenter does not count as drift. Expect a few milliseconds of noise; offsets above a second are real.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- Network access to vCenter, and UDP 123 to the NTP servers (else the local clock is the reference)
- A vCenter account with read access to the hosts

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VCenter` | Yes, or in the config file | vCenter FQDN |
| `-Cluster` | No | One or more cluster names. Leave out for all hosts in vCenter |
| `-VMHost` | No | One or more host names as known in vCenter. Wildcards work (`esx0*`). With `-Cluster`: only those hosts in those clusters |
| `-MaxOffsetSeconds` | No | Offset (absolute) above which a host gets `Warning`. Default `1` |
| `-ReferenceNtpServer` | No | Compare every host with this NTP server instead of the host's own NTP servers |
| `-UseLocalClock` | No | Compare with the clock of this machine instead of NTP |
| `-CsvPath` | No | Also export to CSV (separator from your regional settings, like Excel). `{date}` becomes `yyyyMMdd-HHmm`, `{env}` the environment name |
| `-Credential` | No | vCenter account. Config: `VcUser` / `VcCredentialFile` |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |
| `-UseSddcCredentials` | No | Read the password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |

## Usage

```powershell
.\Get-EsxiTimeReport.ps1 -VCenter vc01.corp.local | Format-Table

# One cluster, all hosts against one NTP server, only the hosts that need attention
.\Get-EsxiTimeReport.ps1 -VCenter vc01.corp.local -Cluster CL-MGMT-01 -ReferenceNtpServer ntp1.corp.local |
    Where-Object Status -ne 'OK' | Format-Table VMHost, OffsetSeconds, Message

# VCF: environment config, vCenter SSO account from the SDDC Manager vault, to CSV
.\Get-EsxiTimeReport.ps1 -Environment lab1 -UseSddcCredentials -CsvPath C:\Reports\{env}-time-{date}.csv
```

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The environment config: `VcUser` makes the script ask for that user's password, `VcCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`, the API counterpart of `lookup_passwords`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, the script uses the vCenter SSO account (credential type `SSO`).
4. Otherwise `Get-Credential` asks.

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`HostTimeReport`**. Values on the command line win over the file.

```json
"HostTimeReport": {
  "Cluster": [],
  "VMHost": [],
  "MaxOffsetSeconds": 1,
  "ReferenceNtpServer": "",
  "UseLocalClock": false,
  "CsvPath": "%USERPROFILE%\\Reports\\{env}-esxi-time-{date}.csv"
}
```

## Output

The results go to the pipeline as objects (not `Format-Table`), so you can filter, sort or export them yourself. Sorted by cluster, then host.

```
VMHost           Cluster    OffsetSeconds TimeProtocol NtpServers                           NtpServiceRunning NtpServicePolicy Status  Message
------           -------    ------------- ------------ ----------                           ----------------- ---------------- ------  -------
esx01.corp.local CL-MGMT-01         0.004 NTP          0.be.pool.ntp.org, 1.be.pool.ntp.org              True on               OK
esx02.corp.local CL-MGMT-01        76.210 NTP          0.be.pool.ntp.org, 1.be.pool.ntp.org             False off              Warning Offset 76.21 s is above 1 s; ntpd is not running; ntpd policy is 'off', not 'on'
esx03.corp.local CL-MGMT-01                                                                                                     Skipped Host is NotResponding
```

The other columns are `VMHostTimeUtc`, `ReferenceTimeUtc` (both `yyyy-MM-dd HH:mm:ss.fff`) and `Reference` (`Local clock` or `NTP <server>`).

## History

Version 2.0 is a rewrite of `Report-HostTime2NTP.ps1` (1.0, based on Get-VMHostTimeReport by Grzegorz Kulikowski). Changes: environment config and vault credentials, a Cluster column and `-Cluster` / `-VMHost` filters, a signed offset with a threshold and Status, the host's own NTP server (or `-ReferenceNtpServer` / `-UseLocalClock`) as reference instead of the earthtools.org web service (no longer online), the ntpd policy, and it disconnects only its own vCenter session.
