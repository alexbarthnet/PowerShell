#requires -Modules ActiveDirectory

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string]$ActiveDirectoryRights = 'CreateChild, DeleteChild, ListChildren, ReadProperty, DeleteTree, ExtendedRight, Delete, GenericWrite, WriteDacl, WriteOwner',
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName
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

	# report state
	Write-Host ("$Hostname,$Name - checking computer object...")

	# define identity for computer object
	$Identity = 'CN={0},{1}' -f $Name, $Path

	# define parameters
	$GetADComputer = @{
		Server      = $Server
		Identity    = $Identity
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
			New-ADComputer -Server $Server -Name $Name -Path $Path -ErrorAction 'Stop'
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
			Write-Warning -Message "could not add computer to  group with '$Group' name on '$Server' server in '$DomainName' domain"
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...added computer to group")
	}
}
