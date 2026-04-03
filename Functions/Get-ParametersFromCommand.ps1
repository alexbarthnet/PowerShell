function Get-ParametersFromCommand {
	param(
		[Parameter(Mandatory = $true)]
		[string]$CommandName,
		[string]$ParameterSetName = $PSCmdlet.ParameterSetName,
		[switch]$LimitToParameterSet,
		[switch]$ExcludeParameterSetName,
		[string[]]$ExcludeParameters,
		[string[]]$ExcludeParameterSets
	)

	# verify command
	try {
		$Command = Get-Command -Name $CommandName -ErrorAction ([System.Management.Automation.ActionPreference]::Stop)
	}
	catch {
		Write-Host "ERROR: '$CommandName' not found"
		return $_
	}

	# verify parameter set name
	if ([string]::IsNullOrEmpty($ParameterSetName)) {
		$LimitToParameterSet = $false
		$ExcludeParameterSetName = $false
	}

	# define lists
	$ParametersList = [System.Collections.Generic.List[string]]::new()
	$ExcludeParameterSetNames = [System.Collections.Generic.List[string]]::new()

	# retrieve parameters for script
	$ParametersFromScript = $Command.Parameters.Values
	
	# filter parameters to parameter set
	if ($ExcludeParameterSets) {
		foreach ($ExcludeParameterSet in $ExcludeParameterSets) {
			foreach ($ExcludedParameterSetName in ($ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ExcludeParameterSet }).Name) ) {
				$ExcludeParameterSetNames.Add($ExcludedParameterSetName)
			}
		}
	}

	# filter parameters to parameter set
	if ($LimitToParameterSet) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ParameterSetName })
	}

	# filter out parameter set name
	if ($ExcludeParameterSetName) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -ne $ParameterSetName })
	}

	# filter out excluded parameters
	if ($ExcludeParameters) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParameters })
	}

	# filter out default excluded parameters
	if ($ExcludeParametersDefault) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParametersDefault })
	}

	# filter parameters to parameter set
	if ($ExcludeParameterSets) {
		$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludeParameterSetNames })
	}

	# get parameters with and without position
	$ParametersWithPosition, $ParametersWithOutPosition = $ParametersFromScript.Where({ $_.Attributes.Position -ge 0 }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

	# process each parameter for script
	foreach ($Parameter in $ParametersWithPosition | Sort-Object -Property { $_.Attributes.Position } ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		if ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# process each parameter for script
	foreach ($Parameter in $ParametersWithOutPosition | Sort-Object -Property { $_.Name } ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		if ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# return list
	return $ParametersList
}