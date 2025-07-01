[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 1, Mandatory)]
	[string]$Path,
	[Parameter(Position = 2)]
	[string[]]$Include,
	[Parameter(Position = 3)]
	[string[]]$Exclude,
	[Parameter(Position = 6)]
	[switch]$Specialize,
	[Parameter(Position = 8)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name,
	[Parameter(DontShow)]
	[string]$DomainNCName = [System.DirectorySErvices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(DontShow)]
	[string]$WMIContainer = "CN=SOM,CN=WMIPolicy,CN=System,$DomainNCName",
	[Parameter(DontShow)]
	[string[]]$RequiredProperties = @('msWMI-Author', 'msWMI-ChangeDate', 'msWMI-CreationDate', 'msWMI-ID', 'msWMI-Name', 'msWMI-Parm2'),
	[Parameter(DontShow)]
	[string[]]$OptionalProperties = @('msWMI-Parm1')
)

# if Path is not an absolute path...
If (![System.IO.Path]::IsPathRooted($Path)) {
	# get unresolved absolute path
	Try {
		$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	}
	Catch {
		Write-Warning -Message "could not create absolute path from the provided Path parameter: $Path"
		Return
	}

	# report absolute path
	Write-Warning -Message "converted relative path in provided Path parameter to absolute path: $Path"
}

# if Path not found as a file...
If (![System.IO.File]::Exists($Path)) {
	Write-Warning -Message "could not locate file with the provided Path parameter: $Path"
	Return
}
Else {
	# import JSON object
	Try {
		$WMIFiltersFromJson = Get-Content -Path $Path -Raw | ConvertFrom-Json
	}
	Catch {
		Write-Warning -Message "could not convert contents of '$Path' file from JSON: $($_.Exception.Message)"
		Throw $_
	}
}

# get WMI filters
Try {
	$WMIFilters = Get-ADObject -Server $Server -SearchBase $WMIContainer -SearchScope 'OneLevel' -Filter * -Properties *
}
Catch {
	Write-Warning -Message "could not retrieve WMI filters from '$WMIContainer' container on '$Server' server: $($_.Exception.Message)"
	Throw $_
}

# loop through WMI filters
:NextWMIFilter ForEach ($WMIFilter in $WMIFiltersFromJson) {
	# define boolean for required properties check
	$RequiredPropertiesMissing = $false

	# define hashtable for object attributes
	$OtherAttributes = @{
		showInAdvancedViewOnly = $true
		instanceType           = 4
	}

	# loop through required properties
	ForEach ($RequiredProperty in $RequiredProperties) {
		If ([string]::IsNullOrEmpty($WMIFilter.$RequiredProperty)) {
			Write-Warning -Message "WMI Filter object missing required property: $RequiredProperty"
			$RequiredPropertiesMissing = $true
		}
		Else {
			$OtherAttributes.Add($RequiredProperty, $WMIFilter.$RequiredProperty)
		}
	}

	# if required properties missing...
	If ($RequiredPropertiesMissing) {
		Continue NextWMIFilter
	}

	# loop through optional properties
	ForEach ($OptionalProperty in $OptionalProperties) {
		If (![string]::IsNullOrEmpty($WMIFilter.$OptionalProperty)) {
			$OtherAttributes.Add($OptionalProperty, $WMIFilter.$OptionalProperty)
		}
	}

	# if specialize requested...
	If ($Specialize) {
		$OtherAttributes['msWMI-Author'] = (Get-ADuser -Identity ([System.Security.Principal.WindowsIdentity]::GetCurrent().User))
	}

	# create objects for WMI filter properties
	$FilterId = $WMIFilter.'msWMI-Id'
	$FilterName = $WMIFilter.'msWMI-Name'

	# if include defined...
	If ($PSBoundParameters.ContainsKey('Include')) {
		# declare include match not found
		$IncludeNotFound = $true

		# loop through include strings...
		ForEach ($IncludeString in $Include) {
			# if WMI Filter display name matches include string...
			If ($WMIFilter.'msWMI-Name' -like $IncludeString) {
				# update boolean to false
				$IncludeNotFound = $false
			}
		}

		# if include not found...
		If ($IncludeNotFound) {
			Write-Verbose -Message "WmiFilterId: $FilterId; skipping WMI Filter: display name of '$FilterName' does not match one of the provided Include strings: '$($Include -join ', ')'"
			Continue NextWMIFilter
		}
	}

	# if exclude defined...
	If ($PSBoundParameters.ContainsKey('Exclude')) {
		# loop through exclude strings...
		ForEach ($ExcludeString in $Exclude) {
			# if WMI Filter display name matches exclude string...
			If ($WMIFilter.'msWMI-Name' -like $ExcludeString) {
				Write-Verbose -Message "WmiFilterId: $FilterId; skipping WMI Filter: display name of '$FilterName' matches Exclude string: '$ExcludeString'"
				Continue NextWMIFilter
			}
		}
	}

	# if filter id found in existing WMI filters...
	If ($FilterId -in $WMIFilters.'msWMI-Id') {
		Write-Warning -Message "found existing WMI Filter in '$DomainNCName' domain with '$FilterId' ID"
		Continue NextWMIFilter
	}

	# define parameters
	$NewADObject = @{
		Server          = $Server
		Name            = $FilterId
		Type            = 'msWMI-Som'
		Path            = $WMIContainer
		OtherAttributes = $OtherAttributes
	}

	# create object
	Try {
		New-ADObject @NewADObject
	}
	Catch {
		Write-Warning -Message "could not import WMI Filter with '$FilterId' id: $($_.Exception.Message)"
	}
}
