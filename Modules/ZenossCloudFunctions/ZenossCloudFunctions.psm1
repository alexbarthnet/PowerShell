# references
# https://help.zenoss.com/dev/collection-zone-and-resource-manager-apis/codebase/routers/router-reference/devicerouter

Function Add-ZenossCloudDevice {
	<#
	.SYNOPSIS
	Add a device to Zenoss Cloud.

	.DESCRIPTION
	Add a device to Zenoss Cloud via the REST interface.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Name
	Specifies the name of a device in Zenoss Cloud.

	.PARAMETER State
	Specifies the state for the device

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Add-ZenossCloudDevice -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Device 'test-device-1.department.example.com' -State 'Production'

	#>

	# DRAFT FUNCTION; NOT COMPLETE

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter(Mandatory = $true)]
		[string]$Name,
		[Parameter(Mandatory = $true)]
		[string]$State
	)

	# WIP function, return immediately
	Return

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# get zenoss cloud production states
	$ZenossProductionStates = Get-ZenossCloudProductionStates -Uri $Uri -Key $Key

	# check zenoss cloud production state
	$ZenossProductionState = $null
	$ZenossProductionState = ($ZenossProductionStates.result.data | Where-Object { $_.Name -eq $State }).Value
	If ($null -eq $ZenossProductionState) {
		Return "ERROR: ProductionState '$State' not found in Zenoss Cloud"
	}

	# retrieve device uid
	$ZenossCloudDevice = $null
	$ZenossCloudDevice = Get-ZenossCloudDevice -Uri $Uri -Key $Key -Device $Device
	If ($null -eq $ZenossCloudDevice.uid) {
		Return "ERROR: Device '$Device' not found in Zenoss Cloud"
	}

	# create hashtable for HTML headers
	$Headers = @{
		'z-api-key'    = $Key
		'Content-Type' = 'application/json'
	}

	<#
	addDevice(
		deviceName
		deviceClass
		**serialNumber
		**zWinPassword
		**osProductName
		**zWinUser
		**tag
		**rackSlot
		**hwManufacturer
		**hwProductName
		**collector
		**zCommandPassword
		**title
		**manageIp
		**comments
		**priority
		**snmpCommunity
		**zCommandUsername
		**groupPaths
		**snmpPort
		**cProperties
		**zProperties
		**productionState
		**systemPaths
		**osManufacturer
		**model
		**locationPath
	)
	#>

	# create array for zenoss body entry
	$zenoss_data = [array][PSCustomObject]@{
		deviceName = $Name
		prodState  = $ZenossProductionState
		hashcheck  = 'no'
	}

	# create hashtable for HTML body
	$zenoss_body = @{
		'action' = 'DeviceRouter'
		'method' = 'addDevice'
		'data'   = $zenoss_data
		'tid'    = 1
	}

	# create device-specific URI
	$uri_device = $Uri.Replace('/zport/dmd', $ZenossCloudDevice.uid)

	# invoke rest method
	Invoke-RestMethod -Method 'Post' -Uri $uri_device -Headers $Headers -Body ($zenoss_body | ConvertTo-Json)
}

Function Get-ZenossCloudDevices {
	<#
	.SYNOPSIS
	Retrieve devices from Zenoss Cloud.

	.DESCRIPTION
	Retrieve devices from Zenoss Cloud via the REST interface.

	.PARAMETER Credential
	Specifies a PSCredential object where the Username is the URI for a specific Zenoss Cloud instance and the Password is the API key.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Reset
	Specifies that a fresh copy of the devices should be retrieved.

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Get-ZenossCloudDevices -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef'

	.EXAMPLE
	PS> Get-ZenossCloudDevices -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Reset

	#>

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter()]
		[switch]$Reset
	)

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# if device collection exists and reset not requested...
	If ($null -ne $global:ZenossCloudDevices -and -not $PSBoundParameters.ContainsKey('Reset')) {
		# ...return device collection
		Return $global:ZenossCloudDevices
	}
	Else {
		# ...create or reset global devices collection
		New-Variable -Name 'ZenossCloudDevices' -Scope 'Global' -Force
	}

	# create hashtable for headers
	$HeadersHashtable = @{
		'z-api-key'    = $Key
		'Content-Type' = 'application/json'
	}

	# create hashtable for body data
	$Data = @{
		limit = 300
	}

	# create hashtable for body
	$BodyHashtable = @{
		'action' = 'DeviceRouter'
		'method' = 'getDevices'
		'data'   = $Data
		'tid'    = 1
	}

	# create headers from hashtable
	$Headers = $HeadersHashtable | ConvertTo-Json -Compress

	# create body from hashtable
	$Body = $BodyHashtable | ConvertTo-Json -Compress

	# invoke rest method to retrieve devices
	$global:ZenossCloudDevices = Invoke-RestMethod -Method 'Post' -Uri $Uri -Headers $Headers -Body $Body

	# return array of devices
	Return $global:ZenossCloudDevices
}

Function Get-ZenossCloudDevice {
	<#
	.SYNOPSIS
	Retrieve a device from Zenoss Cloud.

	.DESCRIPTION
	Retrieve a device from Zenoss Cloud via the REST interface.

	.PARAMETER Credential
	Specifies a PSCredential object where the Username is the URI for a specific Zenoss Cloud instance and the Password is the API key.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Name
	Specifies the name of a device in Zenoss Cloud.

	.PARAMETER Reset
	Specifies that a fresh copy of the device should be retrieved.

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Get-ZenossCloudDevices -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Device 'test-device-1.department.example.com'

	#>

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter(Mandatory = $true)]
		[string]$Name,
		[Parameter()]
		[switch]$Reset
	)

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# if device collection not found or reset requested...
	If ($null -eq $global:ZenossCloudDevices -or $PSBoundParameters.ContainsKey('Reset')) {
		# retrieve device collection
		Try {
			$ZenossCloudDevices = Get-ZenossCloudDevices -Uri $Uri -Key $Key -Reset
		}
		Catch {

		}
	}

	# retrieve device from device collection
	$ZenossCloudDevice = $global:ZenossCloudDevices.result.devices | Where-Object { $_.Name -eq $Name }

	# if device not found...
	If ($null -eq $ZenossCloudDevice) {
		# warn and return null
		Write-Warning -Message "Device '$Device' not found in Zenoss Cloud"
		Return $null
	}
	Else {
		# report and return object
		Write-Verbose -Message "Device '$Device' found in Zenoss Cloud"
		Return $ZenossCloudDevice
	}
}

Function Get-ZenossCloudProductionStates {
	<#
	.SYNOPSIS
	Retrieves available device states from Zenoss Cloud.

	.DESCRIPTION
	Retrieves available device states from Zenoss Cloud via the REST interface.

	.PARAMETER Credential
	Specifies a PSCredential object where the Username is the URI for a specific Zenoss Cloud instance and the Password is the API key.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Reset
	Specifies that a fresh copy of the device states should be retrieved.

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Get-ZenossCloudProductionStates -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef'

	.EXAMPLE
	PS> Get-ZenossCloudProductionStates -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Reset

	#>

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter()]
		[switch]$Reset
	)

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# check for zenoss devices object
	If ($null -eq $ZenossProductionStates) {
		New-Variable -Name 'ZenossProductionStates' -Scope 'Global' -Force
	}

	# check for data array in zenoss states object
	If ($ZenossProductionStates.result.data -is [array] -and $ZenossProductionStates.result.data.Count -gt 0 -and -not $Reset) {
		# return production states
		Return $ZenossProductionStates
	}
	Else {
		# create hashtable for headers
		$HeadersHashtable = @{
			'z-api-key'    = $Key
			'Content-Type' = 'application/json'
		}

		# create hashtable for body
		$BodyHashtable = @{
			'action' = 'DeviceRouter'
			'method' = 'getProductionStates'
			'tid'    = 1
		}

		# create headers from hashtable
		$Headers = $HeadersHashtable | ConvertTo-Json -Compress

		# create body from hashtable
		$Body = $BodyHashtable | ConvertTo-Json -Compress

		# invoke rest method to retrieve production states
		$ZenossProductionStates = Invoke-RestMethod -Method 'Post' -Uri $Uri -Headers $Headers -Body $Body

		# return production states
		Return $ZenossProductionStates
	}
}

Function Set-ZenossCloudProductionState {
	<#
	.SYNOPSIS
	Sets the state of a device in Zenoss Cloud.

	.DESCRIPTION
	Sets the state of a device in Zenoss Cloud via the REST interface.

	.PARAMETER Credential
	Specifies a PSCredential object where the Username is the URI for a specific Zenoss Cloud instance and the Password is the API key.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Name
	Specifies the name of a device in Zenoss Cloud.

	.PARAMETER State
	Specifies the requested state for the device in Zenoss Cloud.

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Set-ZenossCloudProductionState -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Device 'test-device-1.department.example.com' -State 'Production'

	#>

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter(Mandatory = $true)]
		[string]$Device,
		[Parameter(Mandatory = $true)]
		[string]$State
	)

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# get zenoss cloud production states
	$ZenossProductionStates = Get-ZenossCloudProductionStates -Uri $Uri -Key $Key

	# check zenoss cloud production state
	$ZenossProductionState = $null
	$ZenossProductionState = ($ZenossProductionStates.result.data | Where-Object { $_.Name -eq $State }).Value
	If ($null -eq $ZenossProductionState) {
		Return "ERROR: ProductionState '$State' not found in Zenoss Cloud"
	}

	# retrieve device uid
	$ZenossCloudDevice = $null
	$ZenossCloudDevice = Get-ZenossCloudDevice -Uri $Uri -Key $Key -Device $Device
	If ($null -eq $ZenossCloudDevice.uid) {
		Return "ERROR: Device '$Device' not found in Zenoss Cloud"
	}

	# create hashtable for headers
	$HeadersHashtable = @{
		'z-api-key'    = $Key
		'Content-Type' = 'application/json'
	}

	# create hashtable for body data
	$Data = @{
		uids      = $ZenossCloudDevice.uid
		prodState = $ZenossProductionState
		hashcheck = 'no'
	}

	# create hashtable for body
	$BodyHashtable = @{
		'action' = 'DeviceRouter'
		'method' = 'setProductionState'
		'data'   = $Data
		'tid'    = 1
	}

	# create headers from hashtable
	$Headers = $HeadersHashtable | ConvertTo-Json -Compress

	# create body from hashtable
	$Body = $BodyHashtable | ConvertTo-Json -Compress

	# create device-specific URI
	$DeviceUri = $Uri.Replace('/zport/dmd', $ZenossCloudDevice.uid)

	# invoke rest method
	Invoke-RestMethod -Method 'Post' -Uri $DeviceUri -Headers $Headers -Body $Body
}

Function Invoke-ZenossCloudDeviceRemodel {
	<#
	.SYNOPSIS
	Remodels a device in Zenoss Cloud.

	.DESCRIPTION
	Remodels a device in Zenoss Cloud via the REST interface.

	.PARAMETER Credential
	Specifies a PSCredential object where the Username is the URI for a specific Zenoss Cloud instance and the Password is the API key.

	.PARAMETER Uri
	Specifies the URI for a specific Zenoss Cloud instance.

	.PARAMETER Key
	Specifies an API key for the specific Zenoss Cloud instance.

	.PARAMETER Name
	Specifies the name of a device in Zenoss Cloud.

	.INPUTS
	None.

	.OUTPUTS
	Response from the REST call.

	.EXAMPLE
	PS> Invoke-ZenossCloudDeviceRemodel -Uri 'https://test.zenoss.io/cz0/zport/dmd/device_router' -Key '0123456789abcdef' -Device 'test-device-1.department.example.com'

	#>

	[CmdletBinding(DefaultParameterSetName = 'Uri')]
	param (
		[Parameter(Mandatory = $true, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Uri,
		[Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
		[string]$Key,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	# if credential provided...
	If ($PSCmdlet.ParameterSetName -eq 'Credential') {
		# retrieve Uri and Key from Username and Password
		Try {
			$Uri, $Key = $Cred.GetNetworkCredential().UserName, $Cred.GetNetworkCredential().Password
		}
		Catch {
			Throw $_
		}
	}

	# retrieve device uid
	$ZenossCloudDevice = $null
	$ZenossCloudDevice = Get-ZenossCloudDevice -Uri $Uri -Key $Key -Name $Name
	If ($null -eq $ZenossCloudDevice.uid) {
		Return "ERROR: Device '$Name' not found in Zenoss Cloud"
	}

	# create hashtable for HTML headers
	$HeadersHashtable = @{
		'z-api-key'    = $Key
		'Content-Type' = 'application/json'
	}

	# create hashtable for body data
	$BodyData = [array][PSCustomObject]@{
		deviceUid = $ZenossCloudDevice.uid
	}

	# create hashtable for body
	$BodyHashtable = @{
		'action' = 'DeviceRouter'
		'method' = 'remodel'
		'data'   = $BodyData
		'tid'    = 1
	}

	# create device-specific URI
	$DeviceUri = $Uri.Replace('/zport/dmd', $ZenossCloudDevice.uid)

	# create headers from hashtable
	$Headers = $HeadersHashtable | ConvertTo-Json -Compress

	# create body from hashtable
	$Body = $BodyHashtable | ConvertTo-Json -Compress

	# invoke rest method
	Invoke-RestMethod -Method 'Post' -Uri $DeviceUri -Headers $Headers -Body $Body
}

# define functions to export
$FunctionsToExport = @(
    'Get-ZenossCloudDevices'
    'Get-ZenossCloudDevice'
    'Get-ZenossCloudProductionStates'
    'Set-ZenossCloudProductionState'
    'Invoke-ZenossCloudDeviceRemodel'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport