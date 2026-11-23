# Get-EsxiHardwareCompatibility

Checks the hardware of every ESXi host against the [Broadcom Compatibility Guide](https://compatibilityguide.broadcom.com/) (BCG), before an upgrade or when you take over an environment. Give it a target version range, for example `-MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1`, and every component gets a status for that range: is the server, its CPU, every NIC, HBA, storage controller and (for vSAN) every disk supported on the versions you want to go to?

The script only reads. It changes nothing in vCenter or on the hosts. It needs internet access to `compatibilityguide.broadcom.com` from the machine that runs it.

For every network card, storage controller and vSAN disk it also compares the **driver and firmware** the host runs with the versions the guide lists for each release in your range, and says which driver you need (see [Driver and firmware](#driver-and-firmware)).

> **The guide stays the source of truth.** A device is often only supported with a specific driver and firmware. Open the `CompatibilityGuideUrl` of every row you depend on and check the driver and firmware versions before you upgrade, certainly where the script says `Check` or `Unknown`.

## Contents

- [What is checked](#what-is-checked)
- [Status](#status)
- [Driver and firmware](#driver-and-firmware)
- [Requirements](#requirements)
- [Parameters](#parameters)
- [Usage](#usage)
- [Output columns](#output-columns)
- [HTML report](#html-report)
- [How the lookups work](#how-the-lookups-work)
- [Not checked](#not-checked)
- [Credentials](#credentials)
- [Config file](#config-file)
- [Troubleshooting](#troubleshooting)
- [History](#history)

## What is checked

One row per component per host. The `Component` column says what the row is:

| Component | What | Guide section | Matched on |
|---|---|---|---|
| `Server` | Server model of the host | Systems / Servers | Exact model name (`PowerEdge R650`), narrowed to the entries with the host's CPU series |
| `CPU` | Processor | CPU Series | Exact CPUID signature (family, model, stepping) of the host's CPU |
| `PCI` | Network and storage controllers: Ethernet, Fibre Channel, InfiniBand, RAID, SAS, SATA, SCSI, NVMe | IO Devices | Vendor, device, subvendor and subdevice ID (VID/DID/SVID/SSID) |
| `vSAN controller` | Storage controllers of vSAN hosts | vSAN I/O Controller | VID/DID/SVID/SSID |
| `vSAN NVMe` | NVMe drives of vSAN hosts | vSAN SSD | VID/DID/SVID/SSID |
| `vSAN disk` | Local SAS/SATA SSDs and HDDs of vSAN hosts | vSAN SSD / vSAN HDD | Model number |

vSAN rows are added only for hosts in a cluster with vSAN enabled (`-VsanCheck Auto`); a disk outside vSAN does not need to be in the guide. Use `-VsanCheck Always` to check them anyway, for example before you enable vSAN.

Virtual hardware (nested ESXi in a lab, VMware virtual NICs and disks) is reported as `NotApplicable`: it is never in the guide. The CPU of a nested host is still checked, because the physical CPU's CPUID passes through.

## Status

| Status | Meaning |
|---|---|
| `Supported` | Listed for every ESXi release in the range |
| `Partial` | Listed for some releases in the range; `MissingReleases` says which |
| `NotSupported` | In the guide, but for no release in the range |
| `Found` | No range given: the component is in the guide, `SupportedReleases` lists the releases |
| `NotFound` | No matching entry in the guide. Open the link and search by hand: the device may be listed under other IDs or another model name |
| `NotApplicable` | Virtual hardware: not in the guide |
| `NotChecked` | `-SkipHclLookup` was used |
| `LookupFailed` | The guide could not be reached; `Message` has the error |
| `Skipped` / `Failed` | The host is not connected in vCenter, or reading its hardware failed |

**Which releases count.** The guide has no list of ESXi releases, so "every release in the range" means every release in the range that the guide lists for at least one component in this report. If the lowest or highest version of your range is listed for nothing at all, the script warns: the version may be mistyped, or not in the guide yet (on 2026-11-23 the guide listed ESXi 9.0 and 9.1, not 9.1.1). Releases are compared as numbers: `ESXi 8.0 U3` is 8.0.3, and the vSAN sections' `ESXi 9.0 (vSAN 9.0)` is 9.0.

**Check the `Message` and `HclMatch` columns.** They say when a match is less certain than an exact one (see [How the lookups work](#how-the-lookups-work)).

## Driver and firmware

For `PCI`, `vSAN controller`, `vSAN NVMe` and `vSAN disk` rows that are in the guide, the script reads from the host:

- the **driver version**: the version of the loaded VMkernel module (`esxcli system module get`), for example `icen 2.5.2.0-1OEM.800.1.0.20613240`;
- the **firmware**, where ESXi reports it: NICs (`esxcli network nic get`), Fibre Channel HBAs (`esxcli storage san fc list`), NVMe drives (`esxcli nvme device get`) and SAS/SATA disks (the disk revision).

It then opens the guide's detail page of the matching entry and compares them with the driver and firmware the guide lists **for each release in your range** that the device is supported on. Without a range, it compares with the release the host runs now.

| DriverStatus | Meaning |
|---|---|
| `OK` | The running driver is listed for every release checked |
| `Update` | For at least one release another driver version is needed. `DriverCheck` says which, per release: `ESXi 9.0: needs icen 2.3.3.0-1OEM; ESXi 9.1: OK`. When several are listed, it shows the newest |
| `Unknown` | The host did not report its driver version, or the guide page could not be read |
| `NoData` | The guide lists no driver for that release |

| FirmwareStatus | Meaning |
|---|---|
| `OK` | The running firmware is one the guide lists, or at least the listed minimum (vSAN disks) |
| `Check` | The running firmware is not one the guide lists. Compare on the guide page: vendors often write firmware versions differently than ESXi reports them (Intel NICs report the NVM version, the guide may list the package version) |
| `Unknown` | ESXi does not report the firmware. This is normal for RAID and SAS controllers: check it in the server's management (iDRAC, iLO, XClarity) |
| `NoData` | The guide lists no firmware for that release |

Driver and firmware never change `Status`: a device can be `Supported` on 9.0 and still need another driver. Upgrading from 8.0 to 9.x almost always gives `Update`, because 9.x has its own driver builds; `DriverCheck` then tells you which driver to put in your image (vLCM). The comparison is a prefix match: the host reports the full build (`2.5.2.0-1OEM.800.1.0.20613240`), the guide the version (`2.5.2.0-1OEM`).

`-SkipDriverCheck` turns all of this off (no extra esxcli calls, no detail pages).

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- Network access to vCenter, and internet access (HTTPS) to `compatibilityguide.broadcom.com`
- A vCenter account with read access to the hosts

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VCenter` | Yes, or in the config file | vCenter FQDN |
| `-Cluster` | No | One or more cluster names. Leave out for all hosts in vCenter |
| `-MinEsxiVersion` | No | Lowest ESXi release of the target range, for example `9.0` |
| `-MaxEsxiVersion` | No | Highest ESXi release of the target range, for example `9.1.1` |
| `-Component` | No | `Server`, `CPU`, `PCI`, `Vsan`. Default: all four |
| `-DeviceClass` | No | Regular expressions for the PCI class names to check. Default: `Ethernet`, `Network`, `Fibre`, `InfiniBand`, `Mass storage`, `RAID`, `SCSI`, `Serial Attached`, `SATA`, `Non-Volatile memory` |
| `-VsanCheck` | No | `Auto` (default): vSAN rows for hosts in vSAN clusters. `Always`: for every host. `Never`: none |
| `-SkipHclLookup` | No | Only inventory the hardware, without querying the guide (offline, or to get the IDs quickly) |
| `-SkipDriverCheck` | No | Do not read driver and firmware versions and do not compare them (faster) |
| `-CsvPath` | No | Also export to CSV, with the list separator of your Windows region (so Excel opens it in columns). The folder is created when needed. `{date}` becomes `yyyyMMdd-HHmm`, `{env}` the environment name |
| `-HtmlPath` | No | Also write an HTML report (see [HTML report](#html-report)). The folder is created when needed. `{date}` and `{env}` as for `-CsvPath` |
| `-Credential` | No | vCenter account. Config: `VcUser` / `VcCredentialFile` |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json`. Give only the name (`lab1`), not the file name |
| `-ConfigFile` | No | Path to an environment config file |
| `-UseSddcCredentials` | No | Read the vCenter password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |

## Usage

```powershell
# Is all hardware supported on ESXi 9.0 up to 9.1.1?
$r = .\Get-EsxiHardwareCompatibility.ps1 -VCenter vc01.corp.local -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1
$r | Format-Table VMHost, Component, Name, Status, MissingReleases

# VCF: vCenter SSO account from the SDDC Manager vault, settings from the environment config, CSV for Excel
.\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -UseSddcCredentials -CsvPath '%USERPROFILE%\Reports\{env}-hardware-{date}.csv'

# Only what needs attention, one line per unique component, with the link to the guide
$r | Where-Object Status -notin 'Supported', 'NotApplicable' |
    Sort-Object Component, Name, VID, DID, SVID, SSID -Unique |
    Format-Table Component, Name, Status, MissingReleases, Message, CompatibilityGuideUrl -Wrap

# Which drivers do I need, and which firmware should I look at? One line per device and running version
$r | Where-Object { $_.DriverStatus -eq 'Update' -or $_.FirmwareStatus -in 'Check', 'Unknown' } |
    Sort-Object Name, DriverVersion, Firmware -Unique |
    Format-Table Name, DriverVersion, DriverCheck, Firmware, FirmwareStatus, FirmwareCheck -Wrap

# Everything about one row
$r | Where-Object Component -eq 'Server' | Select-Object -First 1 | Format-List *

# Only the network cards, the old behaviour
.\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -Component PCI -DeviceClass Ethernet, Fibre

# Inventory only, no internet needed
.\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -SkipHclLookup | Format-Table VMHost, Component, Name, Detail, VID, DID, SVID, SSID
```

At the end the script prints a summary per component and status, for example:

```
Target ESXi range: ESXi 9.0 to ESXi 9.1.1
WARNING: Nothing in this report is listed for ESXi 9.1.1 in the Compatibility Guide, so that release could not be checked. ...
Releases checked: ESXi 9.0, ESXi 9.1
21 rows, 4 host(s), 8 Compatibility Guide lookup(s).
  CPU, Supported                 3
  PCI, Supported                 4
  PCI, NotFound                  2
  Server, Partial                2
  vSAN controller, Supported     2
  vSAN disk, Supported           3
```

## Output columns

| Column | Content |
|---|---|
| `Cluster`, `VMHost`, `EsxiVersion` | The host and its current ESXi version and build |
| `Component` | `Server`, `CPU`, `PCI`, `vSAN controller`, `vSAN NVMe`, `vSAN disk` (or `Host` for a skipped/failed host) |
| `Name` | What the host reports: server vendor and model, CPU model, PCI vendor and device name, disk vendor and model |
| `Detail` | BIOS version (server); CPUID, sockets and cores (CPU); PCI address and class (PCI); device name, size and type (disk) |
| `Driver` | ESXi driver (module) in use for a PCI device |
| `DriverVersion` | Version of that driver module on the host |
| `Firmware` | Firmware the host reports for the device (NIC, FC HBA, NVMe drive, disk revision); empty when ESXi does not report it |
| `VID`, `DID`, `SVID`, `SSID` | PCI vendor, device, subvendor and subdevice ID, 4 hex digits, as the guide uses them |
| `Status` | See [Status](#status) |
| `HclProgram` | Guide section queried: `server`, `cpu`, `io`, `vsanio`, `ssd`, `hdd` |
| `HclMatch` | How the entry was found: `Exact`, `WithoutSSID`, `CPUID`, `Model`, `Keyword` |
| `HclBrand`, `HclModel` | Brand/partner and model (or CPU series) of the matching guide entries (several are joined with ` \| `) |
| `ReleasesInRange` | Releases in your range the component is listed for |
| `MissingReleases` | Releases in your range the component is not listed for |
| `SupportedReleases` | All releases the guide lists, newest first |
| `DriverStatus`, `DriverCheck` | Running driver compared with the guide, per release; see [Driver and firmware](#driver-and-firmware) |
| `FirmwareStatus`, `FirmwareCheck` | Running firmware compared with the guide, per release |
| `CompatibilityGuideUrl` | The guide page of the entry (or the search page when several entries match) |
| `Message` | Why a match is uncertain, why a row is not checked, or the error |

## HTML report

`-HtmlPath` writes one self-contained HTML file (no external scripts, styles or fonts), so you can open it offline, mail it or attach it to a change:

- the environment, vCenter, target range, releases checked and the warnings of the run;
- summary cards per status (click a card to hide or show those rows);
- **Needs attention**: one line per unique component that is not Supported (the same NIC on ten hosts is one line), with the reason, the hosts that have it and the guide link;
- **Driver and firmware**: one line per device (and running driver/firmware) that needs another driver or a firmware check, with what the guide lists per release and the hosts;
- a table of components by status with a total. The numbers count rows (one per component per host); every row is in exactly one status, so "12 Supported, 4 NotFound" means 16 different rows;
- one section per host with every component, a coloured status, the PCI IDs and driver, releases in range and missing, the driver and firmware check, and a link to the guide page. Hosts with a problem are expanded; the others are collapsed;
- a filter box that searches host, device name, IDs, driver, firmware, model and releases.

It follows the light or dark setting of your browser and prints cleanly.

```powershell
.\Get-EsxiHardwareCompatibility.ps1 -Environment lab1 -UseSddcCredentials -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 `
    -HtmlPath '%USERPROFILE%\Reports\{env}-hardware-{date}.html' -CsvPath '%USERPROFILE%\Reports\{env}-hardware-{date}.csv'
```

## How the lookups work

The script uses the same web API as the guide's own web pages (`POST /compguide/programs/viewResults`, credits to [William Lam](https://williamlam.com/2025/05/programmatically-accessing-the-broadcom-compatibility-guide-bcg.html) for documenting it). It is not an official, documented API, so Broadcom can change it; if lookups start failing with `LookupFailed` or everything becomes `NotFound`, the API has probably changed.

- **PCI devices** are searched on all four IDs first. Many entries leave the subdevice ID empty (meaning any), so when that finds nothing the script searches again without it: `HclMatch` is then `WithoutSSID` and you should check on the guide page that the model is right. IO Devices uses the filter `maxSsid` for the subdevice ID, the vSAN sections use `ssid` (the guide ignores a filter it doesn't know, which would silently match everything; version 1.0 had that problem).
- **CPU**: the script reads the CPUID signature (leaf 1, for example `0x000606A6`) from the host and finds the CPU series that list exactly that signature. Several series can share one signature (Xeon Gold 6300 and Platinum 8300 are both Ice Lake); the script then narrows down on the model number (`Gold 6338` → series with `6300`). If that fails, all matching series are kept and `Message` says so.
- **Server**: the guide lists a server once per CPU series. The script searches the model name, keeps only entries with exactly that model name, and of those only the ones with the host's CPU series. So a server can be `Partial` when the model is supported on 9.1 with one CPU generation but not with yours.
- **vSAN disks** are searched by model number. ESXi often reports an OEM suffix (`MZILT960HBHQ0D3` where the guide says `MZILT960HBHQ-00007`); when the full number finds nothing, the script searches again without the last 3 characters and `HclMatch` is `Keyword`.
- **Driver and firmware** come from the entry's detail page (`POST /compguide/programs/viewDetails?programId=<section>&id=<entry>`), which lists per release the driver name and version and the firmware (IO Devices), the driver and firmware (vSAN I/O Controller) or the minimum firmware (vSAN SSD/HDD). When a device matches several entries, the script uses the first 5 together. IO entries list every driver of a card (an Intel E810 has `icen` and `irdman`); the script compares only the rows of the driver the host uses. The detail page returns at most 100 rows; for devices with a very long history, the oldest releases may be missing (`NoData`).
- **Cache**: every unique component is looked up once per run, however many hosts have it, so a large cluster costs few requests.

## Not checked

- **Firmware of RAID/SAS controllers, BIOS and server firmware.** ESXi does not report the controller firmware (`FirmwareStatus Unknown`); the server BIOS is shown in `Detail` but not compared. Use the server vendor's tools or the hardware support manager in vLCM.
- **Driver features and restrictions.** The guide page can limit a driver to some features (for example RDMA, or a vSAN tier) or add notes. The script compares versions only.
- **GPUs and accelerators**: they have their own guide sections (GPUs, DirectPath) and are not included. Add `-DeviceClass Display, 3D` to at least list them; they will mostly show `NotFound` in IO Devices.
- **Disks outside vSAN, SAN LUNs, USB and SD boot devices.** Local disks and arrays are not in the IO guide; arrays are in the Storage/SAN section, per array model and firmware.
- **vSAN ReadyNode, ESA/OSA tier and memory tiering.** `HclModel` and the guide page show the tier of a vSAN disk, but the script does not check that it fits your vSAN architecture.

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The environment config: `VcUser` makes the script ask for that user's password, `VcCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, the script uses the vCenter SSO account (credential type `SSO`).
4. Otherwise `Get-Credential` asks.

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`HardwareCompatibility`**. Values on the command line win over the file.

```json
"HardwareCompatibility": {
  "Cluster": [],
  "MinEsxiVersion": "9.0",
  "MaxEsxiVersion": "9.1.1",
  "Component": ["Server", "CPU", "PCI", "Vsan"],
  "VsanCheck": "Auto",
  "CsvPath": "%USERPROFILE%\\Reports\\{env}-hardware-{date}.csv",
  "HtmlPath": "%USERPROFILE%\\Reports\\{env}-hardware-{date}.html"
}
```

`DeviceClass`, `SkipHclLookup` and `SkipDriverCheck` can be set there too.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Config file not found: ...\x.json.config.json` | `-Environment` takes the name only: `-Environment lab1` for `config\lab1.config.json`. For another file name use `-ConfigFile <path>` |
| Every host `Skipped` | vCenter reports the hosts as not connected (for example right after a vCenter restart). The warning and `Message` show the state |
| `Too many outstanding operations` at `Connect-VIServer` | vCenter is overloaded or has too many sessions, not a script problem. Retry later, check Monitor > Sessions, restart `vmware-vpxd` if it persists |
| `LookupFailed` on every row | No internet access to `compatibilityguide.broadcom.com`, a proxy that needs configuration, or the guide's API has changed |
| Release in your range "could not be checked" | Nothing is listed for it yet (or the version is mistyped). The status covers only the releases in `Releases checked` |
| Every driver `Update` after a range of 9.x | Expected when the hosts run 8.0: ESXi 9.x uses its own driver builds. `DriverCheck` lists the driver to add to your vLCM image |
| Firmware `Check` on a NIC that is up to date | ESXi may report the firmware differently from the guide (NVM version against package version). Compare on the guide page |
| Excel shows everything in one column | The CSV uses your Windows list separator; open it on a machine with the same regional settings, or import it with Data > From Text/CSV |

## History

Version 1.0 was `Report-PCIDevices.ps1` and checked NICs and FC HBAs only. Version 2.0 adds the environment config, the version range, server, CPU, storage controller and vSAN checks, and fixes the subdevice ID filter (1.0 sent the subvendor ID under a key the guide ignores), the IDs (now always 4 hex digits), devices without a guide entry, the CSV that was named `.txt` and written once per cluster, and looks up each unique component only once. Version 2.1 adds the driver and firmware check.
