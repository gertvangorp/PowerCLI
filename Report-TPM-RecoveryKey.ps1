# This script will report the TPM Recovery Key for all ESXi hosts in a cluster.
# It requires the VMware PowerCLI module to be installed and imported.
# The script connects to a vCenter server, retrieves the ESXi hosts in a specified cluster,
# and then uses the ESXCLI command to get the TPM Recovery Key for each host.
# The output is displayed in the console and includes the host name, Recovery ID, and Key.


$vCenterServer = "Your Server"
$MyCluster = "Your Cluster"

Connect-VIServer $vCenterServer -User "vCenterUser" -Password "Password" -WarningAction SilentlyContinue
$VMHosts = get-cluster   $MyCluster  | get-vmhost | Sort-Object
foreach ($VMHost in $VMHosts) {
   $esxcli = Get-EsxCli -VMHost $VMHost
   try {
       $key = $esxcli.system.settings.encryption.recovery.list()
       Write-Host "$VMHost;$($key.RecoveryID);$($key.Key)"
   }
   catch { 
   }
}
Disconnect-VIServer -Server $vCenterServer  -Confirm:$false
