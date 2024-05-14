Param(
	[Parameter(Position = 0)]
	[switch]$Passthru
)

Begin {
	# create list for results
	$global:GPOsWithNoSettings = [System.Collections.Generic.List[object]]::new()

	# define initial values for Write-Progress
	$ParentId = 0
	$CurrentId = 1

	# create parent progress
	Write-Progress -Id $CurrentId -ParentId $ParentId -Activity 'Processing GPOs'
}

Process {
	# check for global GPO reports collection
	If ($null -eq $global:GPOReports) {
		Write-Warning 'Global $GPOReports collection not found. Run "Get-GPOReportObjects.ps1" to create the collection.'
		Return
	}

	# define values for Write-Progress
	$Counter = 0
	$Maximum = $global:GPOReports.Keys.Count
	$Activity = 'Parsing GPO Reports'
	$CurrentId++

	# get IPSecuritySetting from each GPO report
	:NextGPOReport ForEach ($Guid in $global:GPOReports.Keys) {
		# increment counter for Write-Progress
		$Counter++

		# declare progress
		Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / ($Maximum) * 100)

		# if GPO has any computer or user settings configured...
		If ($global:GPOReports[$Guid].GPO.Computer.ExtensionData -or $global:GPOReports[$Guid].GPO.User.ExtensionData) {
			# continue to next GPO report
			Continue NextGPOReport
		}

		# create custom object
		$GPOCustomObject = [pscustomobject]@{
			Guid         = $Guid
			DisplayName  = $global:GPOReports[$Guid].GPO.Name
			ModifiedTime = $global:GPOReports[$Guid].GPO.ModifiedTime
			Links        = $global:GPOReports[$Guid].GPO.LinksTo.SOMPath
		}

		# add custom object to list
		$global:GPOsWithNoSettings.Add($GPOCustomObject)
	}

	# if passthru set...
	If ($Passthru) {
		# return object
		$global:GPOsWithNoSettings
	}
	Else {
		# declare results
		Write-Output "`nFound $($global:GPOsWithNoSettings.Count) GPOs with no settings configured.`n`nThe '`$GPOsWithNoSettings' object contains the results.`n"
	}
}
