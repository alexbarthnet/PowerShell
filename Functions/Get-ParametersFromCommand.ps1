Function Get-ParametersFromCommand {
	Param(
		[Parameter(Mandatory = $true)]
		[string]$CommandName,
		[string]$ParameterSetName = $PSCmdlet.ParameterSetName,
		[switch]$LimitToParameterSet,
		[switch]$ExcludeParameterSetName,
		[string[]]$ExcludeParameters,
		[string[]]$ExcludeParameterSets
	)

	# verify command
	Try {
		$Command = Get-Command -Name $CommandName -ErrorAction ([System.Management.Automation.ActionPreference]::Stop)
	}
	Catch {
		Write-Host "ERROR: '$CommandName' not found"
		Return $_
	}

	# verify parameter set name
	If ([string]::IsNullOrEmpty($ParameterSetName)) {
		$LimitToParameterSet = $false
		$ExcludeParameterSetName = $false
	}

	# define lists
	$ParametersList = [System.Collections.Generic.List[string]]::new()
	$ExcludeParameterSetNames = [System.Collections.Generic.List[string]]::new()

	# retrieve parameters for script
	$ParametersFromScript = $Command.Parameters.Values
	
	# filter parameters to parameter set
	If ($ExcludeParameterSets) {
		ForEach ($ExcludeParameterSet in $ExcludeParameterSets) {
			ForEach ($ExcludedParameterSetName in ($ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ExcludeParameterSet }).Name) ) {
				$ExcludeParameterSetNames.Add($ExcludedParameterSetName)
			}
		}
	}

	# filter parameters to parameter set
	If ($LimitToParameterSet) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ParameterSetName })
	}

	# filter out parameter set name
	If ($ExcludeParameterSetName) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -ne $ParameterSetName })
	}

	# filter out excluded parameters
	If ($ExcludeParameters) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParameters })
	}

	# filter out default excluded parameters
	If ($ExcludeParametersDefault) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParametersDefault })
	}

	# filter parameters to parameter set
	If ($ExcludeParameterSets) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParameterSetNames })
	}

	# get parameters with position
	$ParametersWithPosition = $ParametersFromScript.Where({ $_.Attributes.Position -ge 0 })

	# get parameters with position
	$ParametersWithOutPosition = $ParametersFromScript.Where({ $_.Attributes.Position -lt 0 })

	# process each parameter for script
	ForEach ($Parameter in $ParametersWithPosition | Sort-Object -Property { $_.Attributes.Position } ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		If ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# process each parameter for script
	ForEach ($Parameter in $ParametersWithOutPosition | Sort-Object -Property { $_.Name } ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		If ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# return list
	Return $ParametersList
}