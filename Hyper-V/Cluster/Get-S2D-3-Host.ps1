<#
.SYNOPSIS
Retrieves and displays the live migration and QoS settings on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the live migration and QoS settings on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string]$HostName
)

# clear arrays
$log_adapter = @()
$log_vm_host = @()
$log_qospols = @()
$log_qostraf = @()

# import host information
$host_list = $null
If ($HostName) {
	# process single host
	$host_list = Import-Csv -Path $HostCsv | Where-Object { $_.Host -eq $HostName }
	If ($host_list.Count -lt 1) {
		Write-Host "...could not find '$HostName' in '$HostCsv'"
	}
}
Else {
	# process all hosts
	$host_list = Import-Csv -Path $HostCsv
}

# process the cluster mapping file
$host_list | Sort-Object Host -Unique | ForEach-Object {
	# get base strings for this pass
	$host_name = $_.Host

	# declare start
	Write-Host "======================== $host_name ========================"

	# clear per-host objects
	$out_adapter = $null
	$out_vm_host = $null
	$out_qospols = $null
	$out_qostraf = $null

	# clear the DNS cache then resolve hostname
	Write-Host "$host_name - resolving host..."
	Do {
		Clear-DnsClientCache
		$dns_found = $null
		$dns_found = Resolve-DnsName -Name $host_name -ErrorAction 'SilentlyContinue'
	} Until ($dns_found)

	# verify connection to remote host
	Write-Host "$host_name - checking host..."
	Do {
		$host_alive = $false
		$host_alive = Test-NetConnection -ComputerName $host_name -CommonTCPPort 'WINRM' -InformationLevel 'Quiet'
	} Until ($host_alive)

	# close existing sessions
	Write-Host "$host_name - closing any existing sessions..."
	Get-PSSession -ComputerName $host_name | Where-Object { $_.Availability -ne 'Busy' } | Remove-PSSession

	# start session for files
	Write-Host "$host_name - starting main session..."
	$pss_main = New-PSSession -ComputerName $host_name

	# create and define remote directory
	Write-Host "$host_name - creating directory..."
	$host_path = Invoke-Command -Session $pss_main -ScriptBlock {
		$host_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		New-Item -Path $host_temp -Name 'hv-setup' -ItemType 'Directory' -Force
	}

	# run remote commands
	Write-Host "$host_name - running commands..."
	$log_adapter += $out_adapter = Invoke-Command -Session $pss_main -ScriptBlock {
		$nic_out = @()
		$nic_list = Get-NetAdapter -Physical
		ForEach ($nic in $nic_list) {
			$nic_hw = $nic | Get-NetAdapterHardwareInfo -ErrorAction 'SilentlyContinue'
			$nic_sr = $nic | Get-NetAdapterSriov -ErrorAction 'SilentlyContinue'
			$nic_out += [pscustomobject]@{
				Name        = $nic.Name;
				Description = $nic.InterfaceDescription;
				Index       = $nic.InterfaceIndex
				Status      = $nic.Status
				MacAddress  = $nic.MacAddress
				LinkSpeed   = $nic.LinkSpeed
				Slot        = $nic_hw.SlotNumber
				Port        = $nic_hw.FunctionNumber + 1
				PciLabel    = $nic_hw.PciDeviceLabelString
				NumVFs      = $nic_sr.NumVFs
				FutureName  = "Slot $($nic_hw.SlotNumber) Port $($nic_hw.FunctionNumber + 1)"
			}
		}
		$nic_out | Sort-Object Name
	}
	$log_vm_host += $out_vm_host = Invoke-Command -Session $pss_main -ScriptBlock { Get-VMHost }
	$log_qospols += $out_qospols = Invoke-Command -Session $pss_main -ScriptBlock { Get-NetQosPolicy | Sort-Object 'PriorityValue' }
	$log_qostraf += $out_qostraf = Invoke-Command -Session $pss_main -ScriptBlock { Get-NetQosTrafficClass }

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-host-' + (Get-Date -Format 'FileDateTime') + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_adapter | Format-Table Name, Description, Index, Status, MacAddress, LinkSpeed, Slot, Port, PciLabel, NumVFs, FutureName
		$file_output2 = $using:out_vm_host | Format-Table Name, @{Label = 'LiveMigrate'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LiveMigrateAuth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LiveMigrateType'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
		$file_output3 = $using:out_qospols | Format-Table Name, Owner, NetworkProfile, Template, PriorityValue, NetDirectPort
		$file_output4 = $using:out_qostraf | Format-Table Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet
		# write the file
		$file_headers | Out-File -FilePath $host_review -Append
		$file_output1 | Out-File -FilePath $host_review -Append
		$file_output2 | Out-File -FilePath $host_review -Append
		$file_output3 | Out-File -FilePath $host_review -Append
		$file_output4 | Out-File -FilePath $host_review -Append
	}

	# end session for files
	Write-Host "$host_name - ending main session..."
	Remove-PSSession -Session $pss_main
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_adapter | Format-Table PSComputerName, Name, Description, Index, Status, MacAddress, LinkSpeed, Slot, Port, PciLabel, NumVFs, FutureName
$log_vm_host | Format-Table PSComputerName, @{Label = 'LiveMigrate'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LiveMigrateAuth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LiveMigrateType'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
$log_qospols | Format-Table PSComputerName, Name, Owner, Template, PriorityValue, NetDirectPort
$log_qostraf | Format-Table PSComputerName, Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet

# declare last run time
Write-Host ''
Write-Host '======================== Time ========================'
Write-Host "Last run time: $(Get-Date -Format FileDateTime)"
