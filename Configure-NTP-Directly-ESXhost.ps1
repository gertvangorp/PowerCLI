# Define hosts and NTP servers
$esxiHosts = @('VCF-ESX01.v-lab.local', 'VCF-ESX02.v-lab.local', 'VCF-ESX03.v-lab.local', 'VCF-ESX04.v-lab.local')
$ntpServers = @('0.be.pool.ntp.org', '1.be.pool.ntp.org', '2.be.pool.ntp.org')


# Optional: Get credentials for each host, if needed
$credential = Get-Credential -Message "Enter credentials"


# Loop Through all ESXi Hosts
foreach ($ESXiHost in $ESXiHosts) {

    Write-Host "Connecting to $host ..." -ForegroundColor Cyan
    Connect-VIServer -Server $ESXiHost -Credential $credential
    $VMhost = Get-VMHost -Server  $ESXiHost  -ErrorAction SilentlyContinue
    if ($VMhost) {
        #Remove existing NTP servers 
        Write-Host "Removing all NTP Servers from $vmhost" 
        $allNTPList = Get-VMHostNtpServer -VMHost $vmhost 
        Remove-VMHostNtpServer -VMHost $vmhost -NtpServer $allNTPList -Confirm:$false | out-null 
        Write-Host "All NTP Servers from $vmhost have been removed" 
        Write-Host ""

        #Setting NTP servers 
        Write-Host "Adding NTP servers to $vmhost" 
        foreach ($ntpServer in $ntpServers) {
            Add-VmHostNtpServer -NtpServer $ntpServer -VMHost $vmhost -Confirm:$false | out-null 
            Write-Host "The following NTP servers have been added to $vmhost : $ntpServer" 
            Write-Host ""
        }


        #Checking NTP Service on the ESXi host 
        $ntp = Get-VMHostService -vmhost $vmhost| ? {$_.Key -eq 'ntpd'} 
        Set-VMHostService $ntp -Policy on | out-null 
        if ($ntp.Running ){ 
            Restart-VMHostService $ntp -confirm:$false 
            Write-Host "$ntp Service on $vmhost was On and was restarted" 
        } 
        Else{ 
            Start-VMHostService $ntp -confirm:$false 
            Write-Host "$ntp Service on $vmhost was Off and has been started"
        }
        Write-Host ""
    }        
    Disconnect-VIServer -Server $ESXiHost -Confirm:$false
}

