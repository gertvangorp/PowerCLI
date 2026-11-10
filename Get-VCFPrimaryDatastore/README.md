# Get-VCFPrimaryDatastore

Lists the primary (principal) datastore of every cluster in VCF 9.x, using the SDDC Manager API. Run it before you retire or delete a principal LUN or NFS export: SDDC Manager keeps referencing that datastore, and Day-N workflows such as adding hosts fail if it disappears.

Background: [Why the principal datastore matters in VCF (especially with FC and NFS)](https://www.v-consult.be/vcf-principal-datastore-fc-nfs/)

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (no PowerCLI modules needed)
- Network access to SDDC Manager on HTTPS (443)
- An SDDC Manager account that can read clusters and domains, for example `administrator@vsphere.local`

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-SddcManager` | Yes, or in the config file | FQDN of SDDC Manager. The old name `-SddcManagerFqdn` still works |
| `-Credential` | No | A `PSCredential`. If you leave it out, the script asks with `Get-Credential` |
| `-SkipCertificateCheck` | No | Skips TLS certificate validation. **Lab use only**, for self-signed certificates |
| `-Environment` | No | Environment config name: reads `config\<name>.config.json` |
| `-ConfigFile` | No | Path to an environment config file |

## Usage

```powershell
# Asks for credentials, validates the certificate
.\Get-VCFPrimaryDatastore.ps1 -SddcManager sddc-manager.yourdomain.local

# Reuse a credential
$cred = Get-Credential
.\Get-VCFPrimaryDatastore.ps1 -SddcManager sddc-manager.yourdomain.local -Credential $cred

# Lab with a self-signed certificate
.\Get-VCFPrimaryDatastore.ps1 -SddcManager sddc-manager.lab.local -SkipCertificateCheck

# With a config file
.\Get-VCFPrimaryDatastore.ps1 -Environment lab1
```

## Config file

This script uses the shared **environment config**: one JSON file per environment (lab, customer, ...) for all scripts in this repository. See [config/README.md](../config/README.md). Run with `-Environment lab1` (reads `config\lab1.config.json`) or `-ConfigFile <path>`. The script reads the top-level keys, then `Common`, then its own section **`PrimaryDatastore`**. Values on the command line win over the file.

## Example output

Names are anonymised.

```
Domain Name  Cluster Name Primary Datastore Name Primary Datastore Type
-----------  ------------ ---------------------- ----------------------
wld-dr       CL-DR-01     ds-db-fc-01            FC
wld-prod     CL-APP-01    ds-app-fc-01           FC
wld-prod     CL-DB-01     ds-db-fc-01            FC
wld-prod     CL-MGMT-01   ds-mgmt-fc-01          FC
```

## How it works

1. Requests an API token with `POST /v1/tokens`.
2. Reads all clusters with `GET /v1/clusters` (`primaryDatastoreName`, `primaryDatastoreType`, `domain.id`).
3. Reads all domains with `GET /v1/domains`, because `/v1/clusters` only returns the domain ID.
4. Prints one line per cluster, sorted by domain and cluster name.

The script only reads. It changes nothing in SDDC Manager or vCenter.
