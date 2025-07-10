#requires -Modules ActiveDirectory

param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string]$ActiveDirectoryRights = 'CreateChild, DeleteChild, ListChildren, ReadProperty, DeleteTree, ExtendedRight, Delete, GenericWrite, WriteDacl, WriteOwner'
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

	# define parameters
	$GetADComputer = @{
		Server      = $Server
		Identity    = $Identity
		Properties  = 'msDS-PrincipalName'
		ErrorAction = 'Stop'
	}

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer @GetADComputer
		Write-Host ("$Hostname,$Name - ...computer object retrieved")
	}
	catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		# report state
		Write-Host ("$Hostname,$Name - computer object not found; creating computer object...")

		# create computer object
		try {
			New-ADComputer -Server $Server -Name $Name -Path $Path -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not create Computer with '$Name$' name on '$Server' server in '$Domain' domain"
			continue NextVMName
		}

		# retrieve computer object with required properties
		try {
			$ComputerObject = Get-ADComputer @GetADComputer
		}
		catch {
			Write-Warning -Message "could not retrieve Computer with '$Name$' name on '$Server' server in '$Domain' domain after creating new object"
			continue NextVMName
		}

		# report state
		Write-Host ("$Hostname,$Name - ...computer object created")
	}
	catch {
		Write-Warning -Message "could not retrieve Computer with '$Name$' name on '$Server' server in '$Domain' domain"
		continue NextVMName
	}

	# retrieve principal name
	$Principal = $ComputerObject.'msDS-PrincipalName'
	$ObjectSID = $ComputerObject.SID

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
			Write-Warning -Message "could not add computer to  group with '$Group' name on '$Server' server in '$Domain' domain"
			continue NextGroup
		}

		# report state
		Write-Host ("$Hostname,$Name - ...added computer to group")
	}

	# if VMNetworkAdapters not found...
	if ($null -eq $JsonData.$Name.VMNetworkAdapters) {
		continue NextVMName
	}

	# retrieve DNS zone for looking up zones
	try {
		$DnsServerZone = Get-DnsServerZone -ComputerName $Server -Name $Domain
	}
	catch {
		Write-Warning -Message "could not retrieve zone for '$Domain' domain on '$Server' server"
		continue NextGroup
	}

	# loop through VMNetwork adapters
	:NextVMNetworkAdapter ForEach ($VMNetworkAdapter in $JsonData.$Name.VMNetworkAdapters) {
		# if VM network adapter does not have an IP address...
		if ([string]::IsNullOrEmpty($VMNetworkAdapter.IPAddress)) {
			continue NextVMNetworkAdapter
		}

		# define parameters
		$GetADObjectForAddress = @{
			Server      = $Server
			SearchBase  = $DnsServerZone.DistinguishedName
			SearchScope = 'OneLevel'
			Filter      = "Name -eq '$Name'"
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DNS record object for address updates
		try {
			$ADObjectForAddress = Get-ADObject @GetADObjectForAddress
		}
		catch {
			Write-Warning -Message "could not perform first query for DNS record object with '$Name' name in '$Domain' zone on '$Server' server"
			Return $_
		}

		# if DNS record object not found...
		If ($null -eq $ADObjectForAddress) {
			# define parameters
			$AddDnsServerResourceRecord = @{
				ComputerName = $Server
				ZoneName     = $Domain
				Name         = $Name
				RRType       = 'A'
				IPv4Address  = $VMNetworkAdapter.IPAddress
				PassThru     = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# create DNS record
			try {
				$DnsServerResourceRecord = Add-DnsServerResourceRecord @AddDnsServerResourceRecord
			}
			catch {
				Write-Warning -Message "could not create DNS record for '$Name' name in '$Domain' zone on '$Server' server"
				Return $_
			}
		}
		# if DNS record object found...
		Else {
			# retrieve existing DNS record
			Try {
				$OldInputObject = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $Domain -Name $Name -RRType A
			}
			Catch {
				Write-Warning -Message "could not retrieve DNS record for '$Name' name in '$Domain' zone on '$Server' server: $($_.Exception.Message)"
				Return $_
			}

			# if value of existing DNS record does not match JSON file...
			If ($OldInputObject.RecordData.IPv4Address.IPAddressToString -ne $VMNetworkAdapter.IPAddress) {
				# clone DNS record object
				$NewInputObject = $OldInputObject.Clone()

				# update IP address of cloned DNS record object 
				$NewInputObject.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($VMNetworkAdapter.IPAddress)

				# define parameters
				$SetDnsServerResourceRecord = @{
					ComputerName   = $Server
					ZoneName       = $Domain
					OldInputObject = $OldInputObject
					NewInputObject = $NewInputObject
					PassThru       = $true
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# set new A record
				Try {
					$DnsServerResourceRecord = Set-DnsServerResourceRecord @SetDnsServerResourceRecord
				}
				Catch {
					Write-Warning -Message "could not update DNS record for '$Name' name in '$Domain' zone on '$Server' server: $($_.Exception.Message)"
					Return $_
				}
			}
		}

		# retrieve DN of DNS record
		$Identity = $DnsServerResourceRecord.DistinguishedName

		# define parameters
		$GetADObjectForSecurity = @{
			Server      = $Server
			Identity    = $Identity
			Properties  = 'nTSecurityDescriptor'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DNS record object for security updates
		try {
			$ADObjectForSecurity = Get-ADObject @GetADObjectForSecurity
		}
		catch {
			Write-Warning -Message "could not perform second query for DNS record object with '$Name' name in '$Domain' zone on '$Server' server"
			Return $_
		}

		# if DNS record object not found...
		If ($null -eq $ADObjectForSecurity) {
			Write-Warning -Message "could not locate DNS record object with '$Name' name in '$Domain' zone on '$Server' server after address update"
			continue NextVMNetworkAdapter
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObjectForSecurity.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# retrieve invalid access rules for DNS record object where identity matches computer but rights are incorrect
		$AccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.NTAccount]).Where({ $_.IdentityReference -eq $Principal -and $_.ActiveDirectoryRights -ne $ActiveDirectoryRights })

		# if no invalid access rules found...
		If ($AccessRules.Count -eq 0) {
			continue NextVMNetworkAdapter
		}

		# loop through invalid access rules
		:NextAccessRule ForEach ($AccessRule in $AccessRules) {
			$nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)
		}

		# create access rule
		$AccessRule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($ObjectSID, $ActiveDirectoryRights, 'Allow')

		# add access rule to security descriptor
		$nTSecurityDescriptor.AddAccessRule($AccessRule)

		# define parameters
		$SetADObject = @{
			Server      = $Server
			Identity    = $Identity
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# update security on DNS record object
		try {
			Set-ADObject @SetADObject
		}
		catch {
			Write-Warning -Message "could not update security on DNS record object with '$Name' name in '$Domain' zone on '$Server' server: $($_.Exception.Message)"
			Return $_
		}
	}
}
