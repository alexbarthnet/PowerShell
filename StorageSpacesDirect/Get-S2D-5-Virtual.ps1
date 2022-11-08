<#
.SYNOPSIS
Retrieves and displays the virtual NICs, VM switches, and VM storage on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Retrieves and displays the virtual NICs, VM switches, and VM storage on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$NicCsv,
	[string[]]$HostName
)

# clear arrays
$log_vswitch = @()
$log_virtual = @()

# import file
$host_list = @()
$host_list += Import-Csv -Path $NicCsv

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
$host_list | Sort-Object Host -Unique | ForEach-Object {
	# get base strings for this pass
	$host_name = $_.Host

	# declare start
	Write-Host "======================== $host_name ========================"

	# clear per-host objects
	$out_vswitch = $null
	$out_virtual = $null

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
	$log_vswitch += $out_vswitch = Invoke-Command -Session $pss_main -ScriptBlock { Get-VMSwitch | Sort-Object Name | Select-Object Name, BandwidthReservationMode, EmbeddedTeamingEnabled, IOVEnabled, IOVSupport, IOVSupportReasons }
	$log_virtual += $out_virtual = Invoke-Command -Session $pss_main -ScriptBlock {
		$vnic_out = @()
		$vnic_client = Get-DnsClient
		$vnic_route = Get-NetRoute -AddressFamily IPv4
		$vnic_addr = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.SkipAsSource -eq $false }
		$vnic_list = Get-VMNetworkAdapter -ManagementOS | Sort-Object Name
		$vnic_prop = Get-NetAdapterAdvancedProperty
		$vnic_list | ForEach-Object {
			$vnic = $_;
			$vnic_iso = $vnic | Get-VMNetworkAdapterIsolation
			$vnic_out += [pscustomobject]@{
				Adapter      = $vnic.Name;
				SwitchName   = $vnic.SwitchName
				MacAddress   = $vnic.MacAddress
				VLAN         = $vnic_iso.DefaultIsolationID
				Isolation    = $vnic_iso.IsolationMode
				IPAddress    = ($vnic_addr | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).IPv4Address
				Mask         = ($vnic_addr | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).PrefixLength
				Gateway      = ($vnic_route | Where-Object { $_.InterfaceAlias -eq $vnic.Name -and $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
				Register     = ($vnic_client | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).RegisterThisConnectionsAddress
				Jumbo        = ($vnic_prop | Where-Object { $_.Name -eq $vnic.Name -and $_.RegistryKeyword -eq '*JumboPacket' }).DisplayValue
				Rdma         = ($vnic_prop | Where-Object { $_.Name -eq $vnic.Name -and $_.RegistryKeyword -eq '*NetworkDirect' }).DisplayValue
				IeeePriority = $vnic.IeeePriorityTag
			}
		}
		$vnic_out | Sort-Object Adapter
	}

	# save output to host
	Write-Host "$host_name - saving output to host..."
	Invoke-Command -Session $pss_main -ScriptBlock {
		# define the file
		$host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-virtual-' + (Get-Date -Format 'FileDateTime') + '.txt')
		# build the file
		$file_headers = "======================== $(Get-Date -Format 'FileDateTime') ========================"
		$file_output1 = $using:out_vswitch | Format-Table Name, @{Label = 'BandwidthMode'; Expression = { $_.BandwidthReservationMode } }, @{Label = 'SET'; Expression = { $_.EmbeddedTeamingEnabled } }, IOVEnabled, IOVSupport, IOVSupportReasons
		$file_output2 = $using:out_virtual | Format-Table Adapter, SwitchName, MacAddress, VLAN, Isolation, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, IeeePriority
		# write the file
		$file_headers | Out-File -FilePath $host_review -Append
		$file_output1 | Out-File -FilePath $host_review -Append
		$file_output2 | Out-File -FilePath $host_review -Append
	}

	# end session for files
	Write-Host "$host_name - ending main session..."
	Remove-PSSession -Session $pss_main
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_vswitch | Format-Table PSComputerName, Name, @{Label = 'BandwidthMode'; Expression = { $_.BandwidthReservationMode } }, @{Label = 'SET'; Expression = { $_.EmbeddedTeamingEnabled } }, IOVEnabled, IOVSupport, IOVSupportReasons
$log_virtual | Format-Table PSComputerName, Adapter, SwitchName, MacAddress, VLAN, Isolation, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, IeeePriority

# declare last run time
Write-Host ''
Write-Host '======================== Time ========================'
Write-Host "Last run time: $(Get-Date -Format FileDateTime)"
