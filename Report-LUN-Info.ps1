
# Connect to vCenter Server
$VCServer = Read-Host "Enter the vCenter Server FQDN or IP"
Connect-VIServer -Server $VCServer

# Get the target host
$MyHostName = Read-Host "Enter the ESXi hostname"
#$MyHostName = "YourServer"
$MyHost = Get-VMHost -Name $MyHostName

if (-not $MyHost) {
    Write-Host "Host not found. Please verify the hostname." -ForegroundColor Red
    exit
}

# Retrieve LUN information
$ScsiLuns = Get-ScsiLun -VmHost $MyHost
$esxcli =  Get-EsxCli -VMHost $MyHost -v2  

# Iterate through each LUN and get details
$LunDetails = foreach ($Lun in $ScsiLuns) {
    $Paths = Get-ScsiLunPath -ScsiLun $Lun
    $MultipathPolicy = Get-ScsiLun -VmHost $MyHost | Where-Object {$_.CanonicalName -eq $Lun.CanonicalName} | Select-Object -ExpandProperty MultipathPolicy
    

    $DeviceInfo = $esxcli.storage.nmp.device.list.invoke() | Where-Object {$_.Device -eq $Lun.CanonicalName} 
    
    [PSCustomObject]@{
        LUNName           = $Lun.DisplayName
        CanonicalName     = $Lun.CanonicalName
        MultipathPolicy   = $MultipathPolicy
        Device            = $DeviceInfo.Device                 
        DeviceDisplayName = $DeviceInfo.DeviceDisplayName              
        IsBootUSBDevice   = $DeviceInfo.IsBootUSBDevice                   
        IsLocalSASDevice  = $DeviceInfo.IsLocalSASDevice                 
        IsUSB             =  $DeviceInfo.IsUSB                 
        PathSelectionPolicy =    $DeviceInfo.PathSelectionPolicy               
        PathSelectionPolicyDeviceConfig = $DeviceInfo.PathSelectionPolicyDeviceConfig     
        PathSelectionPolicyDeviceCustomConfig = $DeviceInfo.PathSelectionPolicyDeviceCustomConfig
        StorageArrayType =   $DeviceInfo.StorageArrayType                  
        StorageArrayTypeDeviceConfig =  $DeviceInfo.StorageArrayTypeDeviceConfig               
        WorkingPaths   =$DeviceInfo.WorkingPaths -join "##-##"
    }
}

# Output the results
$LunDetails | Format-Table -AutoSize

# Optionally export the results to a CSV
$Export = Read-Host "Would you like to export the results to a CSV? (Yes/No)"
if ($Export -eq "Yes") {
    $CsvPath = Read-Host "Enter the file path for the CSV (e.g., C:\\Path\\To\\LUNDetails.csv)"
    #$CsvPath = "C:\temp\LUNDetails.csv"
    $LunDetails | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    Write-Host "Results exported to $CsvPath" -ForegroundColor Green
}

# Disconnect from vCenter Server
Disconnect-VIServer -Server $VCServer -Confirm:$false
