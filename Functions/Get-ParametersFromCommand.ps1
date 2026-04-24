function Get-ParametersFromCommand {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	param(
		# name of command; default value is current command path
		[Parameter(Position = 0)]
		[string]$CommandName = $PSCommandPath,
		# name of parameter set; default value is parameter set in calling scope
		[Parameter(Position = 1, ParameterSetName = 'Default')]
		[string]$ParameterSetName = $PSCmdlet.ParameterSetName,
		# switch parameter to return all parameters from all parameter sets
		[Parameter(Position = 1, ParameterSetName = 'All')]
		[switch]$All
	)

	# retrieve command from script scope
	try {
		$Command = Get-Command -Name $CommandName -ErrorAction 'Stop'
	}
	catch {
		throw $_
	}

	# switch on function parameter set2
	switch ($PSCmdlet.ParameterSetName) {
		'Default' {
			# if parameter set name not in parameter sets...
			if ($ParameterSetName -notin $Command.ParameterSets.Name) {
				# warn and return
				Write-Warning -Message "could not locate '$ParameterSetName' parameter set in '$CommandName' command"
				return $null
			}
		}
		'All' {
			# override parameter set name
			$ParameterSetName = '__AllParameterSets'
		}
	}

	# retrieve parameters from command
	try {
		$Parameters = $Command.Parameters.Values
	}
	catch {
		throw $_
	}

	# define filter script
	$FilterScript = { ($_.Attributes.Mandatory -eq $true -and $_.Attributes.ParameterSetName -eq '__AllParameterSets') -or $_.Attributes.ParameterSetName -eq $ParameterSetName }

	# filter parameters to named parameter set
	$Parameters = $Parameters.Where($FilterScript)

	# define lists
	$ParametersList = [System.Collections.Generic.List[string]]::new()

	# get parameters with and without position
	$ParametersWithPosition, $ParametersWithOutPosition = $Parameters.Where({ ($FilterScript).Position -ge 0 }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

	# process each parameter for script
	foreach ($Parameter in $ParametersWithPosition ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		if ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# process each parameter for script
	foreach ($Parameter in $ParametersWithOutPosition ) {
		# if parameter has a name and name not in ExcludeParameters or ExcludeParametersDefault...
		if ($null -ne $Parameter.Name) {
			# add parameter name to list
			$ParametersList.Add($Parameter.Name)
		}
	}

	# return list
	return $ParametersList
}