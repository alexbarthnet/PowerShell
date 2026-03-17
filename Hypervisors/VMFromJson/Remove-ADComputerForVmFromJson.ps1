#requires -Modules ActiveDirectory,DnsServer

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string[]]$RRTypes = @('A', 'AAAA'),
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
		Write-Warning -Message "could not retrieve 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
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
		Write-Warning -Message "could not retrieve required 'OrganizationalUnit' value in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
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
		Write-Warning -Message "could not resolve A_AAAA record(s) for '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# get domain object
	try {
		$DomainObject = Get-ADDomain -Identity $DomainName
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve object for '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
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
		Properties  = 'ServerReferenceBL'
		ErrorAction = 'Stop'
	}

	# report state
	Write-Host "$Hostname,$Name - checking computer object..."

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer @GetADComputer
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$Server' server for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		# report state
		Write-Host "$Hostname,$Name - ...computer object not found in expected container; checking for computer object in default container..."

		# redefine identity for computer object in default computer container
		$GetADComputer['Identity'] = 'CN={0},{1}' -f $Name, $DomainObject.ComputersContainer
		
		# retrieve computer object in default computer container
		try {
			$ComputerObject = Get-ADComputer @GetADComputer
		}
		catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
			Write-Warning -Message "could not locate computer with '$Name' name on '$Server' server for '$DomainName' domain"
			continue NextVMName
		}
	}
	catch {
		Write-Warning -Message "could not retrieve computer with '$Name' name on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
		continue NextVMName
	}

	# report state
	Write-Host "$Hostname,$Name - ...computer object found; checking properties..."

	# if server reference present...
	if ($ADComputer.ServerReferenceBL.Count) {
		# report state
		Write-Host "$Hostname,$Name - ...server references found; removing server references..."

		# loop through server references...
		:NextServerReference foreach ($ServerReference in $ADComputer.ServerReferenceBL) {
			# define required parameters
			$RemoveADObject = @{
				Identity    = $ServerReference
				Server      = $Server
				Recursive   = $true
				ErrorAction = 'Stop'
			}

			# define optional parameters
			if ($script:Force) {
				$RemoveADObject['Confirm'] = $false
			}

			# remove computer object
			try {
				Remove-ADObject @RemoveADObject
			}
			catch {
				Write-Warning -Message "could not remove '$ServerReference' object on '$Server' server for '$DomainName' domain"
				continue NextServerReference
			}

			# report state
			Write-Host "$Hostname,$Name - ...removed server reference: $ServerReference"
		}
	}

	# report state
	Write-Host "$Hostname,$Name - ...properties checked; removing computer object..."

	# define required parameters
	$RemoveADObject = @{
		Identity    = $ComputerObject
		Server      = $Server
		Recursive   = $true
		ErrorAction = 'Stop'
	}

	# define optional parameters
	if ($script:Force) {
		$RemoveADObject['Confirm'] = $false
	}

	# remove computer object
	try {
		Remove-ADObject @RemoveADObject
	}
	catch {
		Write-Warning -Message "could not remove computer object with '$Name' name on '$Server' server for '$DomainName' domain"
		continue NextVMName
	}

	# report state
	Write-Host "$Hostname,$Name - ...computer object removed"
}
