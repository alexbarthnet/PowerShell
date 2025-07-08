#requires -Modules ActiveDirectory

param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

# if Json is not an absolute path...
If (![System.IO.Path]::IsPathRooted($Json)) {
	# get unresolved absolute path
	Try {
		$Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
	}
	Catch {
		Write-Warning -Message "could not create absolute path from the provided Json parameter: $Json"
		Return
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
		Write-Warning -Message "could not locate 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# if domain not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.Domain)) {
		Write-Warning -Message "could not locate required 'Domain' value in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if domain provided...
	else {
		# assign variable to provided domain for ease of use
		$Domain = $JsonData.$Name.ADComputer.Domain
	}

	# if OU not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.OrganizationalUnit)) {
		Write-Warning -Message "could not locate required 'OrganizationalUnit' value in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if OU provided...
	else {
		# assign variable for ease of use
		$Path = $JsonData.$Name.ADComputer.OrganizationalUnit
	}

	# resolve domain
	try {
		$null = Resolve-DnsName -Name $Domain -DnsOnly -Type A_AAAA -QuickTimeout -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not resolve A_AAAA record(s) for '$Domain' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# get domain object
	try {
		$DomainObject = Get-ADDomain -Identity $Domain
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$Domain' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve object for '$Domain' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# retrieve server from domain object
	$Server = $DomainObject.PDCEmulator

	# define identity for computer object
	$Identity = 'CN={0},{1}' -f $Name, $Path

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer -Server $Server -Identity $Identity -ErrorAction 'Stop'
	}
	catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		# report state
		Write-Host ("$Hostname,$Name - computer object not found; creating computer object...")

		# create computer object
		try {
			$ComputerObject = New-ADComputer -Server $Server -Name $Name -Path $Path -ErrorAction 'Stop' -PassThru
		}
		catch {
			Write-Warning -Message "could not create Computer with '$Name$' name on '$Server' server in '$Domain' domain"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...computer object created")
	}
	catch {
		Write-Warning -Message "could not retrieve Computer with '$Name$' name on '$Server' server in '$Domain' domain"
		continue NextVMName
	}

	# loop through groups
	:NextGroup foreach ($Group in $JsonData.$Name.ADComputer.Groups) {
		# report state
		Write-Host ("$Hostname,$Name - retrieving '$Group' group...")

		# retrieve group by name
		try {
			$GroupObject = Get-ADGroup -Server $Server -Identity $Group -Properties 'member' -ErrorAction 'Stop'
		}
		catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
			Write-Warning -Message "could not locate group with '$Group' name on '$Server' server in '$Domain' domain"
			continue NextGroup
		}
		catch {
			Write-Warning -Message "could not retrieve group with '$Group' name on '$Server' server in '$Domain' domain"
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...retrieved group; checking members...")

		# if computer already a member...
		if ($ComputerObject.DistinguishedName -in $GroupObject.Member) {
			Write-Host ("$Hostname,$Name - ...found computer already in group members")
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...adding computer to group...")

		# add computer to group
		try {
			Add-ADGroupMember -Server $Server -Identity $GroupObject -Members $ComputerObject -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not add computer to  group with '$Group' name on '$Server' server in '$Domain' domain"
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...added computer to group")
	}
}
