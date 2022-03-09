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
	[string]$HostName
)

Function Format-FileSize {
	Param (
		[int64]$Size
	)
	Switch ($Size) {
		{ $_ -ge 1PB } { [string]::Format('{0:0.00} PB', $Size / 1PB); Break }
		{ $_ -ge 1TB } { [string]::Format('{0:0.00} TB', $Size / 1TB); Break }
		{ $_ -ge 1GB } { [string]::Format('{0:0.00} GB', $Size / 1GB); Break }
		{ $_ -ge 1MB } { [string]::Format('{0:0.00} MB', $Size / 1MB); Break }
		{ $_ -ge 1KB } { [string]::Format('{0:0.00} KB', $Size / 1KB); Break }
		Default { [string]::Format('{0:0.00} B', $Size) }
	}
}

# clear arrays
$log_devices = @()

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
$host_list | Sort-Object 'Host' -Unique | ForEach-Object {
	# get base strings for this pass
	$host_name = $_.Host

	# declare start
	Write-Host "======================== $host_name ========================"

	# clear per-host objects
	$out_devices = $null

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
	Get-PSSession -ComputerName $host_name | Remove-PSSession

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
	$log_devices += $out_devices = Invoke-Command -Session $pss_main -ScriptBlock {
		Get-Disk | Where-Object { $_.Number -ne $null } | Where-Object { $_.IsBoot -ne $true } | Where-Object { $_.IsSystem -ne $true } | Sort-Object -Property 'Model'
	}

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-devices-' + (Get-Date -Format FileDateTime) + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_devices | Format-Table 'DiskNumber', 'Model', 'BusType', 'Size', 'PartitionStyle', 'FirmwareVersion'
		$file_output1 = $using:out_devices | Sort-Object -Property 'DiskNumber', 'Model' | Format-Table 'DiskNumber', 'Model', 'BusType', 'PartitionStyle', 'Size'
		# write the file
		$file_headers | Out-File -FilePath $host_review -Append
		$file_output1 | Out-File -FilePath $host_review -Append
	}

	# end session for files
	Write-Host "$host_name - ending main session..."
	Remove-PSSession -Session $pss_main
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_devices | Sort-Object -Property 'PSComputerName', 'DiskNumber', 'Model' | Format-Table 'PSComputerName', 'DiskNumber', 'Model', 'BusType', 'PartitionStyle', @{Label = 'Size'; Expression = { Format-FileSize -Size $_.Size } }
