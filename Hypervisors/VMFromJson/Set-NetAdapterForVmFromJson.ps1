#requires -Modules 'NetAdapter'

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

# retrieve all network adapters
try {
	$NetAdapters = Get-NetAdapter -Physical -ErrorAction 'Stop'
}
catch {
	# warn and continue
	Write-Warning -Message ("$Hostname - could not retrieve NetAdapters: $($_.Exception.Message)")
	throw $_
}

# if Json is not an absolute path...
if (![System.IO.Path]::IsPathRooted($Json)) {
	# get unresolved absolute path
	try {
		$Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
	}
	catch {
		Write-Warning -Message "could not create absolute path from the provided Json parameter: $Json"
		return
	}

	# report absolute path
	Write-Warning -Message "converted relative path in provided Json parameter to absolute path: $Json"
}

# import JSON data
try {
	$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
}
catch {
	Write-Warning -Message "could not read configuration file: '$Json'"
	throw $_
}

# if VM not found in JSON...
if ($null -eq $JsonData.$Hostname) {
	# report and return
	Write-Host ("$Hostname - VM not found in Json")
	return
}

# if VM has network adapters...
if ($null -eq $JsonData.$Name.VMNetworkAdapters) {
	# report and return
	Write-Host ("$Hostname - Network Adapters not found for VM in Json")
	return
}

# retrieve all VM network adapters
$VMNetworkAdapters = $JsonData.$Name.VMNetworkAdapters

# exclude base VM network adapters
$VMNetworkAdapters = $VMNetworkAdapters | Where-Object { $null -ne $_.SkipDuringProvisioning -and $_.SkipDuringProvisioning -eq $true }

# if VM network adapters found after filtering...
if ($null -eq $VMNetworkAdapters) {
	Write-Host ("$Hostname - no additional Network Adapters not found for VM in Json")
}

# loop through VM network adapters
:NextVMNetworkAdapterEntry foreach ($VMNetworkAdapterEntry in $VMNetworkAdapters) {
	# if network adapter name is missing...
	if ($null -eq $VMNetworkAdapterEntry.NetworkAdapterName) {
		# report state and continue
		Write-Host ("$Hostname - skipping VMNetworkAdapter with missing NetworkAdapterName")
		continue NextVMNetworkAdapterEntry
	}

	# if network adapter IP address is missing...
	if ($null -eq $VMNetworkAdapterEntry.IPAddress) {
		# report state and continue
		Write-Host ("$Hostname - skipping VMNetworkAdapter with missing IPAddress")
		continue NextVMNetworkAdapterEntry
	}

	# if network adapter prefix length is missing...
	if ($null -eq $VMNetworkAdapterEntry.PrefixLength) {
		# report state and continue
		Write-Host ("$Hostname - skipping VMNetworkAdapter with missing PrefixLength")
		continue NextVMNetworkAdapterEntry
	}

	# define network adapter name
	$NetAdapterName = $VMNetworkAdapterEntry.NetworkAdapterName

	# report state
	Write-Host ("$Hostname,$NetAdapterName - checking for NetAdapter by name...")

	# filter network adapters
	$NetAdapter = $NetAdapters | Where-Object { $_.InterfaceAlias -eq $VMNetworkAdapterEntry.NetworkAdapterName }

	# if network adapter not found...
	if ($null -eq $NetAdapter) {
		# warn and continue
		Write-Warning -Message ("$Hostname,$NetAdapterName - NetAdapter not found with name: '$($VMNetworkAdapterEntry.NetworkAdapterName)'")
		continue NextVMNetworkAdapterEntry
	}

	# report state
	Write-Host ("$Hostname,$NetAdapterName - ...found VMNetworkAdapter by name; disabling DNS client registration...")

	# disable DNS registration for network adapter
	try {
		$NetAdapter | Set-DnsClient -RegisterThisConnectionsAddress $false
	}
	catch {
		# warn and continue
		Write-Warning -Message ("$Hostname,$NetAdapterName - could not disable DNS client registration: $($_.Exception.Message)")
		continue NextVMNetworkAdapterEntry
	}

	# report state
	Write-Host ("$Hostname,$NetAdapterName - ...disabled DNS client registration; configuring IP address...")

	# configure IP address and prefix on network adapter
	try {
		$NetAdapter | New-NetIPAddress -IPAddress $VMNetworkAdapterEntry.IPAddress -PrefixLength $VMNetworkAdapterEntry.PrefixLength
	}
	catch {
		# warn and continue
		Write-Warning -Message ("$Hostname,$NetAdapterName - could not configure IP address: $($_.Exception.Message)")
		continue NextVMNetworkAdapterEntry
	}

	# report state
	Write-Host ("$Hostname,$NetAdapterName - ...configured IP address")
	{
	}
}
