# Get-PciDeviceCompatibility

Lists the network and storage PCI devices (NICs, FC HBAs, ...) of every ESXi host and checks each one against the [Broadcom Compatibility Guide](https://compatibilityguide.broadcom.com/) (IO devices). Give it a target ESXi version range, for example `-MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1`, and every device gets a status for that range, so you see before an upgrade which cards are not (yet) supported.

Per device per host: cluster, host and its ESXi version, PCI address, class, vendor, device name, driver, NUMA node, the four PCI IDs (VID, DID, SVID, SSID as 4 hex digits), the matching guide entry, the status, the releases in range it is listed for, the releases in range it is missing, all listed releases, and a link to the device in the guide. Hosts that are disconnected or fail are reported too, with the reason.

The script only reads. It changes nothing. It needs internet access to `compatibilityguide.broadcom.com` from the machine that runs it.

> The Compatibility Guide stays the source of truth. A device can be listed for a release only with a specific driver and firmware: open `CompatibilityGuideUrl` and check those before you upgrade.

## Status

| Status | Meaning |
|---|---|
| `Supported` | Listed for every ESXi release in the range |
| `Partial` | Listed for some releases in the range; `MissingReleases` says which |
| `NotSupported` | In the guide, but for no release in the range |
| `NotFound` | No guide entry for these IDs |
| `LookupFailed` | The guide could not be reached (see `Message`) |
| `Found` | No range given: the device is in the guide, `SupportedReleases` lists the releases |
| `NotChecked` | `-SkipHclLookup` was used |
| `Skipped` / `Failed` | The host is not connected, or esxcli failed |

"Every release in the range" means every release in the range that the guide lists for at least one device in the report (the guide has no separate list of releases). When the lowest or highest version of the range is listed for no device at all, the script warns: the version may be mistyped or not in the guide yet. Releases are compared as numbers: `ESXi 8.0 U3` counts as 8.0.3 and `ESXi 9.0.1` as 9.0.1.

The lookup first matches all four IDs. Many guide entries leave the subdevice ID empty, so when that finds nothing it tries again without it; `HclMatch` then says `WithoutSSID` and you should check the model in the guide. Identical devices are looked up once, however many hosts have them.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1
- `Install-Module VCF.PowerCLI -Scope CurrentUser` (VMware.PowerCLI also works)
- Network access to vCenter, and internet access to `compatibilityguide.broadcom.com`
- A vCenter account with read access to the hosts

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VCenter` | Yes, or in the config file | vCenter FQDN |
| `-Cluster` | No | One or more cluster names. Leave out for all hosts in vCenter |
| `-MinEsxiVersion` | No | Lowest ESXi release of the target range, for example `9.0` |
| `-MaxEsxiVersion` | No | Highest ESXi release of the target range, for example `9.1.1` |
| `-DeviceClass` | No | Regular expressions for the PCI class name. Default `Ethernet`, `Fibre`. Add for example `Mass storage`, `RAID`, `NVM` for storage controllers |
| `-SkipHclLookup` | No | Only list the devices and their IDs, no guide lookup |
| `-CsvPath` | No | Also export to CSV, with the list separator of your Windows region (so Excel opens it in columns). `{date}` becomes `yyyyMMdd-HHmm`, `{env}` the environment name |
| `-Credential` | No | vCenter account. Config: `VcUser` / `VcCredentialFile` |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |
| `-UseSddcCredentials` | No | Read the password from the SDDC Manager vault |
| `-SddcManager` | With `-UseSddcCredentials` | SDDC Manager FQDN |
| `-SddcCredential` | No | SDDC Manager account (ADMIN role). Config: `SddcUser` / `SddcCredentialFile` |
| `-SkipCertificateCheck` | No | **Lab only.** Skips TLS validation of SDDC Manager. For vCenter/ESXi, PowerCLI's own `Set-PowerCLIConfiguration -InvalidCertificateAction` applies |

## Usage

```powershell
# Which NICs and HBAs are supported on ESXi 9.0 up to 9.1.1?
.\Get-PciDeviceCompatibility.ps1 -VCenter vc01.corp.local -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 |
    Format-Table VMHost, DeviceName, Driver, Status, MissingReleases

# VCF: vCenter SSO account from the SDDC Manager vault, range and CSV path from the environment config
.\Get-PciDeviceCompatibility.ps1 -Environment lab1 -UseSddcCredentials

# Only the devices that are not fully supported, one line per unique device
.\Get-PciDeviceCompatibility.ps1 -Environment lab1 -MinEsxiVersion 9.0 -MaxEsxiVersion 9.1.1 |
    Where-Object Status -ne 'Supported' | Sort-Object VID, DID, SVID, SSID -Unique |
    Format-Table DeviceName, VID, DID, SVID, SSID, Status, MissingReleases
```

## Credentials

The script never stores or prints a password. It takes the account from the first of these that is set:

1. `-Credential` on the command line.
2. The environment config: `VcUser` makes the script ask for that user's password, `VcCredentialFile` points to a file made with `Get-Credential | Export-Clixml <file>` (encrypted for your Windows account, on that machine).
3. `-UseSddcCredentials` with `-SddcManager`: the password is read from the SDDC Manager vault (`GET /v1/credentials`). Only the SDDC Manager login needs a password; that account needs the SDDC Manager **ADMIN** role. With the vault, the script uses the vCenter SSO account (credential type `SSO`).
4. Otherwise `Get-Credential` asks.

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`PciDeviceCompatibility`**. Values on the command line win over the file.

```json
"PciDeviceCompatibility": {
  "Cluster": [],
  "MinEsxiVersion": "9.0",
  "MaxEsxiVersion": "9.1.1",
  "DeviceClass": ["Ethernet", "Fibre"],
  "CsvPath": "%USERPROFILE%\\Reports\\{env}-pci-devices-{date}.csv"
}
```

## Output

At the end the script prints a summary per unique device:

```
12 rows, 3 unique device(s), 4 Compatibility Guide lookup(s).
  NotFound      1
  Partial       1
  Supported     1
```

```
VMHost           DeviceName                         Driver Status    MissingReleases
------           ----------                         ------ ------    ---------------
esx01.corp.local Ethernet Controller E810-XXV       icen   Supported
esx01.corp.local Emulex LPe35000/LPe36000 FC HBA    lpfc   Partial   ESXi 9.0.1, ESXi 9.1
esx01.corp.local Some old NIC                       xyz    NotFound
```

## History

Version 1.0 was `Report-PCIDevices.ps1`. Version 2.0 adds the environment config and the version range, and fixes the subdevice ID filter (it sent the subvendor ID), the IDs (now always 4 hex digits, as the guide expects), devices without a guide entry, the CSV that was named `.txt` and written once per cluster, and looks up each unique device only once.
