[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 1, Mandatory)]
	[string]$Path,
	[Parameter(Position = 2)]
	[string[]]$Include,
	[Parameter(Position = 3)]
	[string[]]$Exclude,
	[Parameter(Position = 6)]
	[switch]$Generalize,
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

# if Path found as a file...
If ([System.IO.File]::Exists($Path)) {
	# warn and inquire
	Write-Warning -Message "found existing file with the provided Path parameter: $Path; overwrite file?" -WarningAction Inquire
}
Else {
	# create file and path
	Try {
		$null = New-Item -Path $Path -ItemType File -Force | Remove-Item -Force
	}
	Catch {
		Write-Warning -Message "could not create file from the provided Path parameter: $Path"
		Return
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

# create List for WMI filters
$List = [System.Collections.Generic.List[hashtable]]::new()

# loop through WMI filters
:NextWMIFilter ForEach ($WMIFilter in $WMIFilters) {
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

	# create hashtable with WMI Filter properties
	$WMIFilterProperties = @{
		'msWMI-Author'       = $WMIFilter.'msWMI-Author' # UPN of creator
		'msWMI-ChangeDate'   = $WMIFilter.'msWMI-ChangeDate'
		'msWMI-CreationDate' = $WMIFilter.'msWMI-CreationDate'
		'msWMI-ID'           = $WMIFilter.'msWMI-ID'
		'msWMI-Name'         = $WMIFilter.'msWMI-Name' # display name
		'msWMI-Parm1'        = $WMIFilter.'msWMI-Parm1' # description
		'msWMI-Parm2'        = $WMIFilter.'msWMI-Parm2' # WMI filter
	}

	# if generalize requested...
	If ($Generalize) {
		$WMIFilterProperties['msWMI-Author'] = 'Administrator@domain.local'
	}

	# add WMI filter to dictionary
	$List.Add($WMIFilterProperties)
}

# convert dictionary to JSON
Try {
	$Json = ConvertTo-Json -InputObject $List -Depth 100
}
Catch {
	Write-Warning -Message "could not convert dictionary of WMI filters to JSON: $($_.Exception.Message)"
	Throw $_
}

# save JSON to file
Try {
	$Json | Set-Content -Path $Path
}
Catch {
	Write-Warning -Message "could not save JSON to '$Path' file: $($_.Exception.Message)"
	Throw $_
}
