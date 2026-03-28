#requires -Modules ActiveDirectory

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string]$ActiveDirectoryRights = 'CreateChild, DeleteChild, ListChildren, ReadProperty, DeleteTree, ExtendedRight, Delete, GenericWrite, WriteDacl, WriteOwner',
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName,
	[Parameter(Position = 2)]
	[switch]$Reset
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

# loop through VM names
:NextVMName foreach ($Name in $VMName) {
	# if ADComputer not found...
	if ($null -eq $JsonData.$Name.ADComputer) {
		Write-Warning -Message "could not retrieve required 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# if domain not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.DomainName)) {
		Write-Warning -Message "could not retrieve required 'DomainName' value in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if domain provided...
	else {
		# assign variable to provided domain for ease of use
		$DomainName = $JsonData.$Name.ADComputer.DomainName
	}

	# if OU not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.OrganizationalUnit)) {
		Write-Warning -Message "could not retrieve required 'OrganizationalUnit' value in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if OU provided...
	else {
		# assign variable for ease of use
		$Path = $JsonData.$Name.ADComputer.OrganizationalUnit
	}

	# resolve domain
	try {
		$null = Resolve-DnsName -Name $DomainName -DnsOnly -Type A_AAAA -QuickTimeout -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not resolve A_AAAA record(s) for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - connecting to domain...")

	# get domain object
	try {
		$DomainObject = Get-ADDomain -Identity $DomainName
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve object for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - ...connected to domain: $($DomainObject.Name)")

	# retrieve server from domain object
	$Server = $DomainObject.PDCEmulator

	# report state
	Write-Host ("$Hostname,$Name - ...located PDCEmulator: $Server")

	################################
	# create computer object
	################################

	# report state
	Write-Host ("$Hostname,$Name - checking computer object...")

	# define identity for computer object
	$Identity = 'CN={0},{1}' -f $Name, $Path

	# define parameters
	$GetADComputer = @{
		Server      = $Server
		Identity    = $Identity
		Properties  = 'AuthenticationPolicySilo'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer @GetADComputer
		Write-Host ("$Hostname,$Name - ...computer object retrieved")
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$Server' server for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		# report state
		Write-Host ("$Hostname,$Name - ...computer object not found; creating computer object...")

		# create computer object
		try {
			New-ADComputer -Server $Server -Name $Name.ToUpperInvariant() -Path $Path -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not create Computer with '$Name' name on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
			continue NextVMName
		}

		# retrieve computer object with required properties
		try {
			$ComputerObject = Get-ADComputer @GetADComputer
		}
		catch {
			Write-Warning -Message "could not retrieve computer with '$Name' name on '$Server' server for '$DomainName' domain after creating new object: $($_.Exception.Message)"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...computer object created")
	}
	catch {
		Write-Warning -Message "could not retrieve computer with '$Name' name on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
		continue NextVMName
	}

	# define identities list
	$Identities = [System.Collections.Generic.SortedDictionary[string, string]]::new()

	# add computer to identities list
	$Identities.Add($Name, $Identity)

	################################
	# update computer object
	################################

	# if join account present...
	if (![string]::IsNullOrEmpty($JsonData.$Name.ADComputer.DomainJoinAccount)) {
		# report state
		Write-Host ("$Hostname,$Name - checking domain join account...")

		# define identity for domain join account
		$DomainJoinIdentity = $JsonData.$Name.ADComputer.DomainJoinAccount

		# define parameters
		$GetADUser = @{
			Server      = $Server
			Identity    = $DomainJoinIdentity
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve user object for domain join account
		try {
			$ADUser = Get-ADUser @GetADUser
		}
		catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
			Write-Warning -Message "could not locate user with '$DomainJoinIdentity' identity on '$Server' server for '$DomainName' domain"
			continue NextVMName
		}
		catch {
			Write-Warning -Message "could not retrieve user with '$DomainJoinIdentity' identity on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...domain join account retrieved, creating access rules...")

		# define parameters
		$NewADAccessRule = @{
			SecurityIdentifier = $ADUser.SID
			Preset             = 'ComputerJoinThisObjectOnly'
			ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
		}

		# create access rules
		try {
			$AccessRule = New-ADAccessRule @NewADAccessRule
		}
		catch {
			Write-Warning -Message "could not create 'ComputerJoinThisObjectOnly' access rules for '$DomainJoinIdentity' identity: $($_.Exception.Message)"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...access rules created, applying access rules...")

		# define parameters
		$UpdateADAccessRule = @{
			Server      = $Server
			Identity    = $Identity
			AccessRule  = $AccessRule
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# update access rules
		try {
			Update-ADAccessRule @UpdateADAccessRule
		}
		catch {
			Write-Warning -Message "could not apply 'ComputerJoinThisObjectOnly' access rules for '$DomainJoinIdentity' identity to computer with '$Name' name on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...access rules applied")
	}

	################################
	# add computer to groups
	################################

	# loop through groups
	:NextGroup foreach ($Group in $JsonData.$Name.ADComputer.Groups) {
		# report state
		Write-Host ("$Hostname,$Name - retrieving '$Group' group...")

		# define parameters
		$GetADGroup = @{
			Server      = $Server
			Identity    = $Group
			Properties  = 'Member'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve group by name
		try {
			$GroupObject = Get-ADGroup @GetADGroup
		}
		catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
			Write-Warning -Message "could not locate group with '$Group' name on '$Server' server in '$DomainName' domain"
			continue NextGroup
		}
		catch {
			Write-Warning -Message "could not retrieve group with '$Group' name on '$Server' server in '$DomainName' domain"
			continue NextGroup
		}

		# add group to identities list
		$Identities.Add($Group, $GroupObject.DistinguishedName)

		# report state
		Write-Host ("$Hostname,$Name - ...retrieved group; checking members...")

		# if computer already a member...
		if ($ComputerObject.DistinguishedName -in $GroupObject.Member) {
			Write-Host ("$Hostname,$Name - ...found computer already in group")
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...adding computer to group...")

		# define parameters
		$AddADGroupMember = @{
			Server      = $Server
			Identity    = $GroupObject
			Members     = $ComputerObject
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# add computer to group
		try {
			Add-ADGroupMember @AddADGroupMember
		}
		catch {
			Write-Warning -Message "could not add computer to group with '$Group' name on '$Server' server in '$DomainName' domain: $($_.Exception.Message)"
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...added computer to group")
	}

	################################
	# add computer to silos
	################################

	# loop through silos
	:NextSilo foreach ($Silo in $JsonData.$Name.ADComputer.Silos) {
		# report state
		Write-Host ("$Hostname,$Name - retrieving '$Silo' authentication policy silo...")

		# define parameters
		$GetADAuthenticationPolicySilo = @{
			Server      = $Server
			Identity    = $Silo
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve the authentication silo
		try {
			$AuthenticationPolicySilo = Get-ADAuthenticationPolicySilo @GetADAuthenticationPolicySilo
		}
		catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
			Write-Warning -Message "could not locate authentication policy silo with '$Silo' name on '$Server' server in '$DomainName' domain: $($_.Exception.Message)"
			continue NextSilo
		}
		catch {
			Write-Warning -Message "could not retrieve authentication policy silo with '$Silo' name on '$Server' server in '$DomainName' domain: $($_.Exception.Message)"
			continue NextSilo
		}

		# add silo to identities list
		$Identities.Add($Silo, $AuthenticationPolicySilo.DistinguishedName)

		# report state
		Write-Host ("$Hostname,$Name - ...retrieved authentication policy silo; checking members...")

		# if computer already in silo...
		if ($AuthenticationPolicySilo.Members -contains $Identity) {
			# report state
			Write-Host ("$Hostname,$Name - ...found computer already granted access to authentication policy silo; checking computer account...")
		}
		# if computer not yet in silo...
		else {
			# report state
			Write-Host ("$Hostname,$Name - ...found computer not yet granted access to authentication policy silo; granting computer access to authentication policy silo...")

			# define parameters
			$GrantADAuthenticationPolicySiloAccess = @{
				Server      = $Server
				Identity    = $AuthenticationPolicySilo
				Account     = $Identity
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# grant the computer access to the authentication silo:
			try {
				Grant-ADAuthenticationPolicySiloAccess @GrantADAuthenticationPolicySiloAccess
			}
			catch {
				Write-Warning -Message "could not grant computer access to '$Silo' authentication policy silo on '$Server' server in '$DomainName' domain: $($_.Exception.Message)"
				continue NextGroup
			}

			# report state
			Write-Host ("$Hostname,$Name - ...granted computer access to authentication policy silo; checking computer account...")
		}

		# if authentication policy silo already configured on computer object...
		if ($AuthenticationPolicySilo.DistinguishedName -in $ComputerObject.AuthenticationPolicySilo) {
			# report state
			Write-Host ("$Hostname,$Name - ...found computer already in authentication policy silo")
		}
		# if authentication policy silo not yet configured on computer object...
		else {
			# report state
			Write-Host ("$Hostname,$Name - ...found computer not yet in authentication policy silo; adding computer to authentication policy silo...")

			# define parameters
			$SetADAccountAuthenticationPolicySilo = @{
				Server                   = $Server
				Identity                 = $Identity
				AuthenticationPolicySilo = $AuthenticationPolicySilo
				ErrorAction              = [System.Management.Automation.ActionPreference]::Stop
			}

			# set the authentication silo property on the computer object:
			try {
				Set-ADAccountAuthenticationPolicySilo @SetADAccountAuthenticationPolicySilo
			}
			catch {
				Write-Warning -Message "could not add computer object to '$Silo' authentication policy silo on '$Server' server in '$DomainName' domain: $($_.Exception.Message)"
				continue NextGroup
			}

			# report state
			Write-Host ("$Hostname,$Name - ...added computer object to authentication policy silo")
		}
	}

	# define parameters
	$GetADDomainControllers = @{
		Server      = $Server
		Filter      = 'IsGlobalCatalog -eq $true -and -not IsReadOnly -eq $true -and -not HostName -eq "{0}"' -f $Server
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	################################
	# sync objects across domain
	################################

	# retrieve domain controllers
	try {
		$ADDomainControllers = Get-ADDomainController @GetADDomainControllers | Sort-Object -Property Name
	}
	catch {
		Write-Warning -Message "could not retrieve domain controllers for object sync: $($_.Exception.Message)"
		continue NextVMName
	}

	# loop through identities
	foreach ($ObjectName in $Identities.Keys) {
		# define object identity
		$Object = $Identities[$ObjectName]

		# report state
		Write-Host ("$Hostname,$Name - syncing '$ObjectName' object from '$Server' server...")

		# loop through domain controllers
		foreach ($ADDomainController in $ADDomainControllers) {
			# define destination
			$Destination = $ADDomainController.Hostname

			# define parameters
			$SyncADObject = @{
				Object      = $Object
				Source      = $Server
				Destination = $Destination
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# sync updated object 
			try {
				Sync-ADObject @SyncADObject
			}
			catch {
				Write-Warning -Message "could not sync '$ObjectName' object from '$Server' server to '$Destination' server: $($_.Exception.Message)"
				continue NextGroup
			}

			# report state
			Write-Host ("$Hostname,$Name - ...synced '$ObjectName' object to '$Destination' server")
		}
	}
}
