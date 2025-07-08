#requires -Modules ActiveDirectory,DnsServer

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string[]]$RRTypes = @('A', 'AAAA'),
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
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

	# clear computer object
	$ComputerObject = $null

	# define parameters
	$GetADComputer = @{
		Identity    = $Identity
		Server      = $Server
		ErrorAction = 'Stop'
	}

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer @GetADComputer
	}
	catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		Write-Warning -Message "could not locate computer with '$Name$' name on '$Server' server in '$Domain' domain"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve computer with '$Name$' name on '$Server' server in '$Domain' domain: $($_.Exception.Message)"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - computer object found; removing computer object...")

	# define parameters
	$RemoveADObject = @{
		Identity    = $ComputerObject
		Server      = $Server
		Recursive   = $true
		ErrorAction = 'Stop'
	}

	# remove computer object
	try {
		Remove-ADObject @RemoveADObject
	}
	catch {
		Write-Warning -Message "could not remove computer object with '$Name$' name on '$Server' server in '$Domain' domain"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - ...computer object removed")

	# if skip DNS cleanup not requested...
	if (!$SkipDnsCleanup) {
		# define list of DNS host names to remove...
		$List = [System.Collections.Generic.List[string]]::new()

		# add default DNS host name to list
		$List.Add(('{0}.{1}' -f $Name, $Domain))

		# if computer object has a DNS host name...
		if (![string]::IsNullOrEmpty($ComputerObject.DnsHostName)) {
			if ($ComputerObject.DnsHostName -notin $List ) {
				$List.Add($ComputerObject.DnsHostName)
			}
		}

		# loop through DNS host names
		:NextDnsHostName foreach ($DnsHostName in $List) {
			# retrieve DNS record and zone names from DNS host name
			$RecordName, $ZoneName = $DnsHostName.Split('.', 2)

			# retrieve DNS zone
			try {
				$null = Get-DnsServerZone -ComputerName $Server -Name $ZoneName -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not retrieve '$ZoneName' zone on '$Server' server in '$Domain' domain"
				continue NextDnsHostName
			}

			# loop through record types
			foreach ($RRType in $RRTypes) {
				# clear DNS record object
				$DnsServerResourceRecord = $null
				
				# retrieve DNS record
				$DnsServerResourceRecord = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Name $RecordName -RRType $RRType -ErrorAction 'Ignore'

				# if DNS record found...
				if ($DnsServerResourceRecord) {
					# define parameters
					$RemoveDnsServerResourceRecord = @{
						ComputerName = $Server
						ZoneName     = $ZoneName
						Name         = $Name
						RRType       = $RRType
						ErrorAction  = 'Stop'
					}

					# remove IPv4 DNS record
					try {
						Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
					}
					catch {
						Write-Warning -Message "could not remove '$RecordName' $RRType record in '$ZoneName' zone on '$Server' server in '$Domain' domain"
					}
				}
			}
		}
	}
}
