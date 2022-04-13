<#
.SYNOPSIS
Retrieves and displays the available storage devices on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the available storage devices on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string[]]$HostName,
	[byte]$RoundTo
)

Function Format-Bytes {
	Param (
		[Parameter(Position = 0,Mandatory = $true)]
		[uint64]$Size,
		[Parameter(Position = 1)]
		[byte]$RoundTo = 2
	)
	Switch ($Size) {
		{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; Break }
		{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; Break }
		{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; Break }
		{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; Break }
		{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; Break }
		Default { "$([math]::Round($Size,$RoundTo)) B" }
	}
}

# clear arrays
$log_disks_base = @()
$log_disks_phys = @()
$log_disks_virt = @()

# import file
$host_list = @()
$host_list += Import-Csv -Path $HostCsv

# filter host information
If ($HostName) {
	# process hostnames
	$host_temp = @()
	ForEach ($host_name in $HostName) {
		$host_temp += $host_list | Where-Object { $_.Host -eq $host_name } 
	}
	$host_list = $host_temp
}

# process the cluster mapping file
$host_list | Sort-Object 'Host' -Unique | ForEach-Object {
	# get base strings for this pass
	$host_name = $_.Host

	# declare start
	Write-Host "======================== $host_name ========================"

	# clear per-host objects
	$out_disks_base = $null
	$out_disks_phys = $null
	$out_disks_virt = $null

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

	# check if host is clustered
	$log_disks_base += $out_disks_base = Invoke-Command -Session $pss_main -ScriptBlock {
		Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and -not $_.IsClustered }
	}
	$log_disks_phys += $out_disks_phys = Invoke-Command -Session $pss_main -ScriptBlock {
		Get-PhysicalDisk | Where-Object { [int]$_.DeviceId -ge 1000 } | Sort-Object { [int]$_.DeviceId }
	}
	$log_disks_virt += $out_disks_virt = Invoke-Command -Session $pss_main -ScriptBlock {
		Get-VirtualDisk
	}

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-devices-' + (Get-Date -Format FileDateTime) + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_disks_base | Sort-Object -Property 'Number' | Format-Table 'Number', 'FriendlyName', 'Model', 'FirmwareVersion', 'PartitionStyle', 'PhysicalSectorSize', 'LogicalSectorSize', 'AllocatedSize'
		$file_output2 = $using:out_disks_phys | Sort-Object -Property 'DeviceId' | Format-Table 'DeviceId', 'FriendlyName', 'Model', 'FirmwareVersion', 'BusType', 'Size'
		$file_output3 = $using:out_disks_virt | Sort-Object -Property 'FriendlyName'
		# write the file
		$file_headers | Out-File -FilePath $host_review -Append
		$file_output1 | Out-File -FilePath $host_review -Append
		$file_output2 | Out-File -FilePath $host_review -Append
		$file_output3 | Out-File -FilePath $host_review -Append
	}

	# end session for files
	Write-Host "$host_name - ending main session..."
	Remove-PSSession -Session $pss_main
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
If ($log_disks_base.Count -gt 0) { $log_disks_base | Sort-Object -Property 'PSComputerName', 'Number' | Format-Table 'PSComputerName', 'Number', 'FriendlyName', 'Model', 'FirmwareVersion', 'PartitionStyle', 'PhysicalSectorSize', 'LogicalSectorSize', @{Label = 'Size'; Expression = { Format-Bytes -Size $_.Size }; Alignment = 'Right' }, @{Label = 'AllocatedSize'; Expression = { Format-Bytes -Size $_.AllocatedSize }; Alignment = 'Right' } }
If ($log_disks_phys.Count -gt 0) { $log_disks_phys | Sort-Object -Property 'PSComputerName', 'DeviceId' | Format-Table 'PSComputerName', 'DeviceId', 'FriendlyName', 'Model', 'FirmwareVersion', 'BusType', @{Label = 'Size'; Expression = { Format-Bytes -Size $_.Size }; Alignment = 'Right' } }
If ($log_disks_virt.Count -gt 0) { $log_disks_virt | Sort-Object -Property 'PSComputerName', 'FriendlyName' | Format-Table 'PSComputerName', 'FriendlyName', @{Label = 'Size'; Expression = { Format-Bytes -Size $_.Size }; Alignment = 'Right' }, @{Label = 'FootprintOnPool'; Expression = { Format-Bytes -Size $_.FootprintOnPool }; Alignment = 'Right' } }

# declare last run time
Write-Host ''
Write-Host '======================== Time ========================'
Write-Host "Last run time: $(Get-Date -Format FileDateTime)"
