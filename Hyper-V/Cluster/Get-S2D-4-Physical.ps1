<#
.SYNOPSIS
Retrieves and displays the physical NICs on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the physical NICs on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string]$HostName
)

# clear arrays
$log_physical = @()

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
	$out_physical = $null

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
	$log_physical += $out_physical = Invoke-Command -Session $pss_main -ScriptBlock {
		$nic_out = @()
		$nic_list = Get-NetAdapter -Physical
		ForEach ($nic in $nic_list) {
			$nic_client = $nic | Get-DnsClient
			$nic_route = $nic | Get-NetRoute -AddressFamily 'IPv4'
			$nic_addr = $nic | Get-NetIPAddress -AddressFamily 'IPv4' -SkipAsSource $false -ErrorAction 'SilentlyContinue'
			$nic_prop = $nic | Get-NetAdapterAdvancedProperty
			$nic_rdma = $nic | Get-NetAdapterRdma -ErrorAction 'SilentlyContinue'
			$nic_out += [pscustomobject]@{
				Name   = $nic.Name;
				IPAddress = $nic_addr.IPv4Address
				Mask      = $nic_addr.PrefixLength
				Register  = $nic_client.RegisterThisConnectionsAddress
				Gateway   = $nic_route | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } | Select-Object -ExpandProperty 'NextHop'
				VLAN      = $nic_prop | Where-Object { $_.RegistryKeyword -eq 'VlanID' } | Select-Object -ExpandProperty 'DisplayValue'
				Jumbo     = $nic_prop | Where-Object { $_.RegistryKeyword -eq '*JumboPacket' } | Select-Object -ExpandProperty 'DisplayValue'
				Rdma      = $nic_prop | Where-Object { $_.RegistryKeyword -eq '*NetworkDirect' } | Select-Object -ExpandProperty 'DisplayValue'
				RdmaType  = $nic_prop | Where-Object { $_.RegistryKeyword -eq '*NetworkDirectTechnology' } | Select-Object -ExpandProperty 'DisplayValue'
				PFC       = $nic_rdma.PFC
				ETS       = $nic_rdma.ETS
			}
		}
		$nic_out | Sort-Object Name
	}

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-physical-' + (Get-Date -Format 'FileDateTime') + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_physical | Format-Table Name, VLAN, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, RdmaType, PFC, ETS
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
$log_physical | Format-Table PSComputerName, Name, VLAN, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, RdmaType, PFC, ETS

# declare last run time
Write-Host ''
Write-Host '======================== Time ========================'
Write-Host "Last run time: $(Get-Date -Format FileDateTime)"
