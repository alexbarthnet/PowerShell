<#
.SYNOPSIS
Retrieves and displays the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string[]]$HostName
)

# define required roles
$features = @()
$features += 'BitLocker' # storage encryption of cluster shared volumes
$features += 'Data-Center-Bridging' # enable network qos in cooperation with switches
$features += 'Failover-Clustering' # enable failover clustering
$features += 'FS-FileServer' # base feature for dedupe and bandwidth limits
$features += 'FS-Data-Deduplication' # deduplicate cluster shared volumes
$features += 'FS-SMBBW' # limit live migration bandwidth
$features += 'Hyper-V' # enable virtualization
$features += 'Hyper-V-PowerShell' # powershell for hyper-v
$features += 'RSAT-AD-Powershell' # powershell for AD
$features += 'RSAT-Clustering-PowerShell' # powershell for failover clustering
$features += 'Storage-Replica' # enable stretch clusters

# clear arrays
$log_feature = @()

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
	$out_feature = $null

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
	$log_feature += $out_feature = Invoke-Command -Session $pss_main -ScriptBlock {
		# define local object
		$features = $using:features

		# get Windows edition
		$WindowsEdition = Get-WindowsEdition -Online | Select-Object -ExpandProperty Edition

		# define edition-specific roles
		If ($WindowsEdition -like 'ServerAzure*') {
			$features += 'NetworkATC' # network ATC for Azure Stack HCI
			$features += 'NetworkHUD' # network HUD for Azure Stack HCI
		}
		Else {
			$features += 'GPMC' # console for handling group policy
		}

		# get features
		Get-WindowsFeature -Name $features | Sort-Object 'Name'
	}

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-feature-' + (Get-Date -Format FileDateTime) + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_feature | Format-Table 'Name', 'InstallState'
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
$log_feature | Format-Table 'PSComputerName', 'Name', 'InstallState'

# declare last run time
Write-Host ''
Write-Host '======================== Time ========================'
Write-Host "Last run time: $(Get-Date -Format FileDateTime)"
