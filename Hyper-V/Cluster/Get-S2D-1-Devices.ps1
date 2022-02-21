<#
.SYNOPSIS
Retrieves and displays the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files. 

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(  
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string]$HostName
)

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
		Get-Disk | Where-Object { $_.Number -ne $null } | Where-Object { $_.IsBoot -ne $true } | Where-Object { $_.IsSystem -ne $true } | Where-Object { $_.PartitionStyle -eq 'RAW' } | Group-Object -NoElement -Property 'Model' | Sort-Object -Property 'Count'
	} 

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-devices-' + (Get-Date -Format FileDateTime) + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_devices | Format-Table 'Name', 'Count'
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
$log_devices | Sort-Object -Property 'PSComputerName', 'Count' | Format-Table 'PSComputerName', 'Name', 'Count'