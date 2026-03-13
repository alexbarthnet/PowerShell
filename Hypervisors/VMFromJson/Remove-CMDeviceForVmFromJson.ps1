#requires -Modules ActiveDirectory,DnsServer

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string[]]$RRTypes = @('A', 'AAAA'),
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName,
	[Parameter(Position = 2, Mandatory)]
	[string]$ComputerName
)

begin {
	function Test-PSSessionByName {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# if computername matches hostname...
		if ($ComputerName -eq $Hostname) {
			# ...return false as no session is needed
			return $false
		}

		# if hashtable is missing...
		if ($script:PSSessions -isnot [hashtable]) {
			# ...create hashtable
			$script:PSSessions = @{}
		}

		# if session exists for computer...
		if ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			if ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				return $true
			}
		}

		# create a new session
		try {
			$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
		}
		catch {
			return $false
		}

		# ...validate session
		if ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			if ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				return $true
			}
			else {
				return $false
			}
		}
		else {
			return $false
		}
	}

	function Get-PSSessionInvoke {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[hashtable]$ArgumentList
		)

		# default arguments passed to ScriptBlock run by Invoke-Command
		$ArgumentListForInvokeCommand = @{
			# ErrorAction for ScriptBlock run by Invoke-Command
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# optional arguments passed to ScriptBlock run by Invoke-Command
		foreach ($Key in $ArgumentList.Keys) {
			$ArgumentListForInvokeCommand[$Key] = $ArgumentList[$Key]
		}

		# define hashtable for Invoke-Command
		$InvokeCommand = @{
			# ErrorAction for Invoke-Command itself
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			# arguments passed to script block executed by Invoke-Command
			ArgumentList = $ArgumentListForInvokeCommand
		}

		# if computername matches hostname...
		if ($ComputerName -eq $Hostname) {
			# ...update hashtable to invoke commands in the current scope on the local computer
			$InvokeCommand['NoNewScope'] = $true
			# ...return hashtable
			return $InvokeCommand
		}

		# check for session
		try {
			$SessionExists = Test-PSSessionByName -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# if a session exists...
		if ($SessionExists) {
			# ...update hashtable to invoke commands in the session
			$InvokeCommand['Session'] = $script:PSSessions[$ComputerName]
			# ...return hashtable
			return $InvokeCommand
		}
		else {
			# ...update hashtable to invoke commands in a standalone session
			$InvokeCommand['ComputerName'] = $ComputerName
			# ...return hashtable
			return $InvokeCommand
		}
	}

	function Get-CMModulePath {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[string]$ChildPath = '\bin\ConfigurationManager.psd1'
		)

		# define hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# retrieve path to CM module from remote registry
		try {
			$Path = Invoke-Command @InvokeCommand -ScriptBlock {
				# define parameters for Get-ItemProperty
				$GetItemProperty = @{
					Path        = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
					Name        = 'UI Installation Directory'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# get property by name from path
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		catch {
			throw $_
		}

		# if path not found...
		if ([string]::IsNullOrEmpty($Path)) {
			# ...return empty string
			return [string]::Empty
		}

		# update argument list with CM module path
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['ChildPath'] = $ChildPath

		# test CM module path
		try {
			$CMModulePath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Join-Path
				$JoinPath = @{
					Path        = $ArgumentList['Path']
					ChildPath   = $ArgumentList['ChildPath']
					Resolve     = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# join paths together
				Join-Path @JoinPath
			}
		}
		catch {
			throw $_
		}

		# if path not found...
		if ([string]::IsNullOrEmpty($CMModulePath)) {
			return [string]::Empty
		}
		# if path found...
		else {
			# ...return path
			return $CMModulePath
		}
	}

	function Get-CMSiteCode {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# define hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# retrieve CM site code from remote registry
		try {
			$CMSiteCode = Invoke-Command @InvokeCommand -ScriptBlock {
				# define parameters for Get-ItemProperty
				$GetItemProperty = @{
					Path        = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
					Name        = 'Site Code'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# get property by name from path
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		catch {
			throw $_
		}

		# if CM site code not found...
		if ([string]::IsNullOrEmpty($CMSiteCode)) {
			# ...return empty string
			return [string]::Empty
		}
		# if CM site code found...
		else {
			# ...return CM site code
			return $CMSiteCode
		}
	}

	function Remove-CMDeviceByName {
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$Name,
			# define CM parameters
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# get CM module path
		try {
			$CMModulePath = Get-CMModulePath -ComputerName $ComputerName -ErrorAction Stop
		}
		catch {
			Write-Host "$HostName,$Name - ERROR: could not retrieve path to CM PowerShell module on management server: $ComputerName"
			throw $_
		}

		# test CM module path
		if ([string]::IsNullOrEmpty($CMModulePath)) {
			Write-Host "$HostName,$Name - WARNING: could not retrieve path to CM PowerShell module on management server: $ComputerName"
			return
		}

		# get CM site code
		try {
			$CMSiteCode = Get-CMSiteCode -ComputerName $ComputerName -ErrorAction Stop
		}
		catch {
			Write-Host "$HostName,$Name - ERROR: could not retrieve CM site code from management server: $ComputerName"
			throw $_
		}

		# test CM site code
		if ([string]::IsNullOrEmpty($CMSiteCode)) {
			Write-Host "$HostName,$Name - WARNING: could not retrieve CM site code from management server: $ComputerName"
			return
		}

		# update arguments for Invoke-Command - reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update arguments for Invoke-Command - deployment
		$InvokeCommand['ArgumentList']['ModulePath'] = $CMModulePath
		$InvokeCommand['ArgumentList']['SiteCode'] = $CMSiteCode

		# connect to CM remotely
		Write-Host "$HostName,$Name - connecting to management server: $ComputerName"
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

			# reset device object
			$Device = $null

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$Name = $ArgumentList['Name']

			# import CM module
			try {
				Write-Host "$HostName,$ComputerName,$Name - ...importing CM module"
				Import-Module -Name $ArgumentList['ModulePath'] -ErrorAction 'Stop'
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: importing CM module"
				throw $_
			}

			# move to site drive
			try {
				Write-Host "$HostName,$ComputerName,$Name - ...setting location to site drive"
				Set-Location -Path ([string]::Concat($ArgumentList['SiteCode'], ':\'))
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: setting location to CM drive"
				throw $_
			}

			# retrieve All Systems collection
			try {
				Write-Host "$HostName,$ComputerName,$Name - retrieving 'All Systems' collection"
				$AllSystems = Get-CMDeviceCollection -Name 'All Systems'
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: retrieving 'All Systems' collection"
				throw $_
			}

			# validate All Systems collection
			if ($null -eq $AllSystems) {
				Write-Host "$HostName,$ComputerName,$Name - WARNING: All Systems collection is empty"
				return
			}

			# retrieve device by name
			try {
				Write-Host "$HostName,$ComputerName,$Name - retrieving device by name from 'All Systems' collection"
				$Device = Get-CMDevice -Collection $AllSystems -Fast -Name $Name
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: retrieving device by name from 'All Systems' collection"
				throw $_
			}

			# if multiple devices found by name...
			if ($Device.Count -gt 1) {
				# ...warn and return
				Write-Host "$HostName,$ComputerName,$Name - WARNING: multiple devices found with the same name"
				Write-Host "$HostName,$ComputerName,$Name - ...remove extra devices from CM before continuing"
				return
			}

			# if device not found by name...
			if ($null -eq $Device) {
				# report and continue
				Write-Host "$HostName,$ComputerName,$Name - ...device not found by name in 'All Systems' collection"
				return
			}
			# if device found by name...
			else {
				# retrieve resource ID
				$ResourceId = $Device.ResourceId

				# report and continue
				Write-Host "$HostName,$ComputerName,$Name - ...found existing device with resource ID: '$ResourceId'"
			}

			# define parameters for Clear-CMPxeDeployment
			$ClearCMPxeDeployment = @{
				Device      = $Device
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# clear PXE flag on CM resource
			try {
				Write-Host "$HostName,$ComputerName,$Name - clearing any PXE deployments for existing device..."
				Clear-CMPxeDeployment @ClearCMPxeDeployment
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: clearing CM PXE deployment"
				throw $_
			}

			# report and continue
			Write-Host "$HostName,$ComputerName,$Name - ...cleared PXE deployment for existing device"

			# remove device
			try {
				Write-Host "$HostName,$ComputerName,$Name - removing device with resource ID: $ResourceId"
				Remove-CMResource -ResourceId $ResourceId -Force
			}
			catch {
				Write-Host "$HostName,$ComputerName,$Name - ERROR: removing device by resource ID"
				throw $_
			}

			# report and return
			Write-Host "$HostName,$ComputerName,$Name - ...removed device from CM"
			return
		}
	}
}

process {
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

	# loop through VM names
	:NextVMName foreach ($Name in $VMName) {
		# if ADComputer not found...
		if ($null -eq $JsonData.$Name) {
			Write-Warning -Message "could not retrieve '$Name' VM in configuration file: '$Json'"
			continue NextVMName
		}

		# remove CM device by name from CM management server
		try {
			Remove-CMDeviceByName -Name $Name -ComputerName $ComputerName
		}
		catch {
			throw $_
		}
	}
}