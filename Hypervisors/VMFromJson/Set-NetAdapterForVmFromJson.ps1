#requires -Modules 'NetAdapter'

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1)]
	[string]$SkipLocalJson,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

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
if ($null -eq $JsonData.$Hostname.VMNetworkAdapters) {
	# report and return
	Write-Host ("$Hostname - no VMNetworkAdapter entries found for VM in Json")
	return
}

# define array of local JSON data of VM network adapters
$LocalJsonData = @()

# retrieve all VM network adapters
$VMNetworkAdapters = $JsonData.$Hostname.VMNetworkAdapters

# exclude base VM network adapters
$VMNetworkAdapters = $VMNetworkAdapters | Where-Object { $null -ne $_.SkipDuringProvisioning -and $_.SkipDuringProvisioning -eq $true }

# if VM network adapters found after filtering...
if ($null -eq $VMNetworkAdapters) {
	Write-Host ("$Hostname - no additional VMNetworkAdapter entries found for VM in Json")
}

# retrieve network adapter advanced property sets
try {
	$NetAdapterAdvancedPropertySets = Get-NetAdapterAdvancedProperty -RegistryKeyword 'HyperVNetworkAdapterName' -ErrorAction 'Stop' | Where-Object { -not [string]::IsNullOrEmpty($_.DisplayValue) }
}
catch {
	Write-Warning -Message 'could not retrieve NetAdapterAdavancedProperty sets'
	throw $_
}

# loop through network adapter advanced property sets
:NextNetAdapterAdvancedPropertySet foreach ($NetAdapterAdvancedPropertySet in $NetAdapterAdvancedPropertySets) {
	# define network adapter names
	$NetAdapterOldName = $NetAdapterAdvancedPropertySet.Name
	$NetAdapterNewName = $NetAdapterAdvancedPropertySet.DisplayValue
	
	# if network adapter names match...
	if ($NetAdapterOldName -eq $NetAdapterNewName) {
		# report state and continue
		Write-Host ("$Hostname - found '$NetAdapterOldName' NetAdapter matches HyperVNetworkAdapterName value")
		continue NextNetAdapterAdvancedPropertySet
	}

	# rename network adapter from old name to Hyper-V network adapter name
	try {
		Rename-NetAdapter -Name $NetAdapterOldName -NewName $NetAdapterNewName -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not rename '$NetAdapterOldName' NetAdapter to '$NetAdapterNewName' name from HyperVNetworkAdapterName"
		throw $_
	}

	# report state and sleep
	Write-Host ("$Hostname - renamed '$NetAdapterOldName' NetAdapter to '$NetAdapterNewName' name from HyperVNetworkAdapterName")
}

# retrieve all network adapters AFTER renaming
try {
	$NetAdapters = Get-NetAdapter -Physical -ErrorAction 'Stop'
}
catch {
	Write-Warning -Message 'could not retrieve NetAdapters'
	throw $_
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
		Set-DnsClient -InterfaceIndex $NetAdapter.InterfaceIndex -RegisterThisConnectionsAddress $false
	}
	catch {
		Write-Warning -Message ("$Hostname,$NetAdapterName - could not disable DNS client registration: $($_.Exception.Message)")
		continue NextVMNetworkAdapterEntry
	}

	# report state
	Write-Host ("$Hostname,$NetAdapterName - ...disabled DNS client registration; configuring IP address...")

	# retrieve current IP address and prefix on network adapter
	try {
		$NetIPAddress = Get-NetIPAddress -InterfaceIndex $NetAdapter.InterfaceIndex -AddressFamily 'IPv4' -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message ("$Hostname,$NetAdapterName - could not retrieve current IP addresses: $($_.Exception.Message)")
		continue NextVMNetworkAdapterEntry
	}

	# if BOTH current IP address and prefix length match defined values...
	if ($NetIPAddress.IPAddress -eq $VMNetworkAdapterEntry.IPAddress -and $NetIPAddress.PrefixLength -eq $VMNetworkAdapterEntry.PrefixLength) {
		# report state
		Write-Host ("$Hostname,$NetAdapterName - ...found current IP address and prefix length match defined values")
	}
	else {
		# remove current IP address
		try {
			$null = Remove-NetIPAddress -InterfaceIndex $NetAdapter.InterfaceIndex -AddressFamily 'IPv4' -Confirm:$false -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message ("$Hostname,$NetAdapterName - could not remove existing IP address: $($_.Exception.Message)")
			continue NextVMNetworkAdapterEntry
		}

		# configure IP address and prefix on network adapter
		try {
			$null = New-NetIPAddress -InterfaceIndex $NetAdapter.InterfaceIndex -IPAddress $VMNetworkAdapterEntry.IPAddress -PrefixLength $VMNetworkAdapterEntry.PrefixLength -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message ("$Hostname,$NetAdapterName - could not add defined IP address: $($_.Exception.Message)")
			continue NextVMNetworkAdapterEntry
		}

		# report state
		Write-Host ("$Hostname,$NetAdapterName - ...configured IP address")
	}

	# add network adapter configuration to local JSON data
	$LocalJsonData += $VMNetworkAdapterEntry
}

# if no local JSON data defined...
if ($LocalJsonData.Count -eq 0) {
	Write-Host ("$Hostname - no Network Adapters configured for VM in Json")
}

# if skip local JSON not requested...
if (!$SkipLocalJson.IsPresent) {
	# convert local JSON data to JSON
	try {
		$LocalJson = ConvertTo-Json -InputObject $LocalJsonData -Depth 100 -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not convert '`$LocalJsonData' object to JSON"
		throw $_
	}

	# retrieve ProgramData directory
	try {
		$CommonApplicationDataFolderPath = [System.Environment]::GetFolderPath('CommonApplicationData')
	}
	catch {
		Write-Warning -Message "could not retrieve 'CommonApplicationData' folder path from environment"
		throw $_
	}

	# define folder path in ProgramData directory
	$Path = Join-Path -Path $CommonApplicationDataFolderPath -ChildPath 'VmFromJson'

	# if path not found...
	if (![System.IO.Directory]::Exists($Path)) {
		try {
			$null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not create directory: $Path"
			throw $_
		}
	}

	# define file path in VmFromJson directory
	$FilePath = Join-Path -Path $Path -ChildPath "$Hostname.json"

	# if file path not found...
	if (![System.IO.File]::Exists($FilePath)) {
		try {
			$null = New-Item -Path $FilePath -ItemType File -Force -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not create file: $FilePath"
			throw $_
		}
	}

	# write JSON to file path
	try {
		$LocalJson | Set-Content -Path $FilePath -NoNewline -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not write JSON to file: $FilePath"
		throw $_
	}
}
