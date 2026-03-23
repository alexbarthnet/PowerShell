[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'RoleOwner')]
param(
	# name of FSMO role to use to locate domain controller
	[Parameter(Position = 0, Mandatory, ParameterSetName = 'RoleOwner')][ValidateSet('PDC', 'RID', 'Infrastructure', 'Schema', 'Naming')]
	[string]$Role,
	# name of domain controller
	[Parameter(Position = 0, Mandatory, ParameterSetName = 'Server')]
	[string]$Server,
	# number of peers to return
	[Parameter(Position = 1)]
	[uint16]$Count,
	# number of peers per site to return
	[Parameter(Position = 2)]
	[uint16]$CountPerSite,
	# preferred site name
	[Parameter(Position = 3)]
	[string]$PreferredSiteName = 'Default-First-Site-Name',
	# preferred site link name
	[Parameter(Position = 4)]
	[string]$PreferredSiteLinkName = 'DEFAULTIPSITELINK',
	# switch to skip checking if domain controllers is a global catalog
	[Parameter(Position = 5)]
	[switch]$SkipGlobalCatalogCheck,
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 6)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 7)]
	[string]$VariableName = 'GetADDomainControllerPeer',
	# scope of variable when AsVariable is true
	[Parameter(Position = 8)]
	[string]$VariableScope = 'global',
	# type of output
	[Parameter(Position = 9)][ValidateSet('Name', 'Object')]
	[string]$OutputType = 'Name',
	# domain object
	[Parameter(DontShow)]
	[object]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain(),
	# global catalogs
	[Parameter(DontShow)]
	[object[]]$DomainControllers = $Domain.DomainControllers,
	# forest object
	[Parameter(DontShow)]
	[object]$Forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest(),
	# global catalogs
	[Parameter(DontShow)]
	[object[]]$GlobalCatalogs = $Forest.GlobalCatalogs
)

function ConvertTo-ListOrderedFromFirstObject {
	param(
		[object]$InputObject,
		[object]$FirstObject
	)

	# if input object contains first object...
	if ($InputObject.Contains($FirstObject)) {
		$StartingIndex = $InputObject.IndexOf($FirstObject)
	}
	# if input object missing first object...
	else {
		$StartingIndex = 0
	}

	# define list for objects
	$ListOfObjects = [System.Collections.Generic.List[object]]::new()

	# while index is less than count of objects...
	for ($Index = 0; $Index -lt $InputObject.Count; $Index++) {
		# add object at shifted index using modulo of count to add items before first object
		$ListOfObjects.Add($InputObject[($StartingIndex + $Index) % $InputObject.Count])
	}

	# return list
	return , $ListOfObjects
}

function Get-ADDomainControllerAndPeers {
	param(
		[Parameter(Position = 0, Mandatory)][ValidateNotNull()]
		[System.DirectoryServices.ActiveDirectory.DomainController]$Server
	)

	# define list for domain controllers
	$OrderedDomainControllers = [System.Collections.Generic.List[object]]::new()

	# create directory context for current forest
	$DirectoryContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Forest, $Forest.Name)

	# get site of domain controller holding the defined role
	$ActiveDirectorySite = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::FindByName($DirectoryContext, $Server.SiteName)

	# report state
	Write-Host "Found '$($Server.Name)' domain controller in '$($ActiveDirectorySite.Name)' site"

	# switch on count of servers in current site
	switch ($ActiveDirectorySite.Servers.Count) {
		0 {
			# report warning
			Write-Warning -Message "found '$($ActiveDirectorySite.Servers.Count)' domain controllers in '$($ActiveDirectorySite.Name)' site; how did this happen?"
			return
		}
		1 {
			# report warning
			Write-Host "Found '$($ActiveDirectorySite.Servers.Count)' domain controller in '$($ActiveDirectorySite.Name)' site; adding domain controller to list"

			# select domain controller object
			$DomainControllerInCurrentSite = $ActiveDirectorySite.Servers | Select-Object -First 1

			# add domain controller to list
			$OrderedDomainControllers.Add($DomainControllerInCurrentSite)

			# set parity index to 0
			$ParityIndex = 0
		}
		default {
			# report state
			Write-Host "Found '$($ActiveDirectorySite.Servers.Count)' domain controllers in '$($ActiveDirectorySite.Name)' site; sorting domain controllers then adding to list"

			# define list for names of domain controllers in current site
			$CurrentSiteServerNames = [System.Collections.Generic.List[string]]::new()

			# loop through servers in current site
			foreach ($ServerName in $ActiveDirectorySite.Servers.Name) {
				# report state
				Write-Verbose -Message "site '$($ActiveDirectorySite.Name)' has unsorted domain controller: '$ServerName'"

				# add domain controllers to set
				$null = $CurrentSiteServerNames.Add($ServerName)
			}

			# sort list
			$CurrentSiteServerNames.Sort()

			# loop through list after sort for reporting
			foreach ($CurrentSiteServerName in $CurrentSiteServerNames) {
				# report state
				Write-Verbose -Message "site '$($ActiveDirectorySite.Name)' has sorted domain controller: '$CurrentSiteServerName'"
			}

			# retrieve index of role owner in ordered domain controllers list
			$Index = $CurrentSiteServerNames.IndexOf($Server.Name)

			# if index is odd...
			if ($Index % 2 -eq 1) {
				# set parity index to 1
				$ParityIndex = 1
			}
			# if index is even or 0...
			else {
				# set parity index to 0
				$ParityIndex = 0
			}

			# convert list with default sort to list with custom sort where server from parameters is first object
			try {
				$ArrangedDomainControllerNames = ConvertTo-ListOrderedFromFirstObject -InputObject $CurrentSiteServerNames -FirstObject $Server.Name
			}
			catch {
				throw $_
			}

			# loop through arranged domain controller names
			foreach ($DomainControllerName in $ArrangedDomainControllerNames) {
				# report state
				Write-Verbose -Message "site '$($ActiveDirectorySite.Name)' has arranged domain controller: '$DomainControllerName'"

				# select domain controller object
				$DomainControllerInCurrentSite = $ActiveDirectorySite.Servers | Where-Object { $_.Name -eq $DomainControllerName }

				# add domain controller to list
				$OrderedDomainControllers.Add($DomainControllerInCurrentSite)
			}
		}
	}

	# if not adjacent sites found...
	if ($ActiveDirectorySite.AdjacentSites.Count -eq 0) {
		# report state and return list immediately
		Write-Host "Found '$($AdjacentSites.Count)' adjacent sites"
		return $OrderedDomainControllers
	}

	# report parity index
	Write-Host "Found parity index of '$ParityIndex' for '$($Server.Name)' domain controller in '$($ActiveDirectorySite.Name)' site"

	# retrieve adjacent sites with domain controllers
	$AdjacentSites = $ActiveDirectorySite.AdjacentSites.Where({ $_.Servers.Count })

	# switch on count of adjacent sites with domain controllers
	switch ($AdjacentSites.Count) { 
		0 {
			# warn about state
			Write-Warning -Message "found '$($AdjacentSites.Count)' adjacent sites with domain controllers; how did this happen?"
		}
		1 {
			# report state
			Write-Host "Found '$($AdjacentSites.Count)' adjacent site with domain controllers, identifying domain controllers in adjacent site"

			# define nearest site from only adjacent site
			$NearestSite = $AdjacentSites | Select-Object -First 1
		}
		default {
			# report state
			Write-Host "Found '$($AdjacentSites.Count)' adjacent sites with domain controllers, identifying closest site by cost"

			# retrieve lowest cost of site links for adjacent sites
			$LowestCost = $AdjacentSites.SiteLinks.Cost | Sort-Object | Select-Object -First 1

			# retrieve site links for adjacent sites with lowest cost
			$SiteLinksWithLowestCost = $AdjacentSites.SiteLinks.Where({ $_.Cost -eq $LowestCost })

			# switch on site links for adjacent sites with lowest cost count
			switch ($SiteLinksWithLowestCost.Count) {
				0 {
					# STATE: forest contains at least 2 other GCs, other sites contains at least 2 other GCs, current site has 0 adjacent sites with lowest cost

					# warn and return
					Write-Warning "Found '$($SiteLinksWithLowestCost.Count)' site links with lowest cost for '$($ActiveDirectorySite.Name)' site; how did this happen?"
					return
				}
				1 {
					# STATE: forest contains at least 2 other GCs, other sites contains at least 2 other GCs, current site has 1 adjacent site with lowest cost

					# report state
					Write-Host "Found '$($SiteLinksWithLowestCost.Count)' site link with lowest cost for '$($ActiveDirectorySite.Name)' site; identifying sites in link"

					# retrieve site link from collection
					$SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Select-Object -First 1
				}
				default {
					# report state
					Write-Host "Found '$($SiteLinksWithLowestCost.Count)' site links with lowest cost for '$($ActiveDirectorySite.Name)' site; checking for preferred site link: '$PreferredSiteLinkName'"

					# if preferred site link name found in site links with lowest cost...
					if ($PreferredSiteLinkName -in $SiteLinksWithLowestCost.Name) {
						# report state
						Write-Host "Found '$PreferredSiteLinkName' preferred site link, identifying sites in link"

						# retrieve preferred site link
						$SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Where-Object { $_.Name -eq $PreferredSiteLinkName } | Select-Object -First 1
					}
					# if preferred site link name not found in site links with lowest cost...
					else {
						# report state
						Write-Host "The '$PreferredSiteLinkName' preferred site link not found, selecting first site link alphabetically'"

						# retrieve preferred site link alphabetically by name
						$SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Sort-Object -Property Name | Select-Object -First 1

						# report state
						Write-Host "Selected '$($SiteLinkWithLowestCost.Name)' site link, identifying sites in link"
					}
				}
			}

			# retrieve adjacent sites with lowest cost
			$AdjacentSitesWithLowestCost = $AdjacentSites.Where({ $_.SiteLinks.Name -eq $SiteLinkWithLowestCost.Name })

			# switch on adjacent sites with lowest cost count
			switch ($AdjacentSitesWithLowestCost.Count) {
				0 {
					# report state
					Write-Warning "Found '$($AdjacentSitesWithLowestCost.Count)' adjacent site with lowest cost; how did this happen?"

					# return out of frustration
					return
				}
				1 {
					# report state
					Write-Host "Found '$($AdjacentSitesWithLowestCost.Count)' adjacent site with lowest cost; identifying domain controllers in nearest site by cost"

					# retrieve nearest site from only adjacent site from with lowest cost
					$NearestSite = $AdjacentSitesWithLowestCost | Select-Object -First 1
				}
				default {
					# report state
					Write-Host "Found '$($AdjacentSitesWithLowestCost.Count)' adjacent sites with lowest cost, checking for preferred site: '$PreferredSiteName'"

					# if preferred site name found in adjacent sites with lowest cost...
					if ($PreferredSiteName -in $AdjacentSitesWithLowestCost.Name) {
						# report state
						Write-Host "'Found '$PreferredSiteName' preferred site, identifying domain controllers in preferred site'"

						# retrieve nearest site from adjacent sites by preferred name
						$NearestSite = $AdjacentSitesWithLowestCost | Where-Object { $_.Name -eq $PreferredSiteName }
					}
					# if preferred site name not found in adjacent sites with lowest cost...
					else {
						# report state
						Write-Host "Preferred '$PreferredSiteName' site not found, selecting first site alphabetically"

						# retrieve nearest site from adjacent sites alphabetically by name
						$NearestSite = $AdjacentSitesWithLowestCost | Sort-Object -Property Name | Select-Object -First 1

						# report state
						Write-Host "Selected '$($NearestSite.Name)' site, identifying domain controllers in site"
					}
				}
			}
		}
	}

	# switch on count of other global catalogs in nearest site
	switch ($NearestSite.Servers.Count) {
		0 {
			# warn about state
			Write-Warning -Message "found '$($NearestSite.Servers.Count)' domain controllers found in '$($NearestSite.Name)' site; how did this happen?"
		}
		1 {
			# report state
			Write-Host "Found '$($NearestSite.Servers.Count)' domain controller in '$($NearestSite.Name)' site; adding domain controller to list"

			# select domain controller object
			$DomainControllerInNearestSite = $NearestSite.Servers | Select-Object -First 1

			# add domain controller to list
			$OrderedDomainControllers.Add($DomainControllerInNearestSite)
		}
		default {
			# report state
			Write-Host "Found '$($NearestSite.Servers.Count)' domain controllers in '$($NearestSite.Name)' site; selecting first domain controller by parity of last character in role owner name"

			# define list for domain controllers in nearest site
			$NearestSiteServerNames = [System.Collections.Generic.List[string]]::new()

			# loop through servers in nearest site
			foreach ($ServerName in $NearestSite.Servers.Name) {
				# report state
				Write-Verbose -Message "site '$($NearestSite.Name)' has unsorted domain controller: '$ServerName'"

				# add domain controllers to sorted set
				$null = $NearestSiteServerNames.Add($ServerName)
			}

			# sort list
			$NearestSiteServerNames.Sort()

			# loop through sorted list
			foreach ($NearestSiteServerName in $NearestSiteServerNames) {
				# report state
				Write-Verbose -Message "site '$($NearestSite.Name)' has sorted domain controller: '$NearestSiteServerName'"
			}

			# select domain controller in nearest site by parity index
			$FirstDomainControllerNameInNearestSite = $NearestSiteServerNames[$ParityIndex]

			# report state
			Write-Host "Found '$FirstDomainControllerNameInNearestSite' domain controller by parity in '$($ActiveDirectorySite.Name)' site"

			# convert list to list with custom sort where role owner is first object
			try {
				$ArrangedDomainControllerNames = ConvertTo-ListOrderedFromFirstObject -InputObject $NearestSiteServerNames -FirstObject $FirstDomainControllerNameInNearestSite
			}
			catch {
				throw $_
			}

			# loop through arranged domain controller names
			foreach ($DomainControllerName in $ArrangedDomainControllerNames) {
				# report state
				Write-Verbose -Message "site '$($NearestSite.Name)' has arranged domain controller: '$DomainControllerName'"

				# select domain controller object
				$DomainControllerInNearestSite = $NearestSite.Servers | Where-Object { $_.Name -eq $DomainControllerName }

				# add domain controller to list
				$OrderedDomainControllers.Add($DomainControllerInNearestSite)
			}
		}
	}

	# return list after sorting
	return $OrderedDomainControllers
}

# switch on parameter set name
switch ($PSCmdLet.ParameterSetName) {
	'RoleOwner' {
		# switch on role
		switch ($Role) {
			'PDC' {
				$DomainController = $Domain.PdcRoleOwner
			}
			'RID' {
				$DomainController = $Domain.RidRoleOwner
			}
			'Infrastructure' {
				$DomainController = $Domain.InfrastructureRoleOwner
			}
			'Naming' {
				$DomainController = $Forest.NamingRoleOwner
			}
			'Schema' {
				$DomainController = $Forest.SchemaRoleOwner
			}
		}
	}
	'Server' {
		$DomainController = $DomainControllers | Where-Object { $_.Name -eq $Server -or $_.Name.Split('.')[0] -eq $Server }
	}
}

# if domain controller is null...
if ($null -eq $DomainController) {
	Write-Warning -Message 'could not locate domain controller with provided parameters'
	return
}

# report state
Write-Host "Found '$($GlobalCatalogs.Count)' global catalogs in '$($Forest.Name)' forest"

# report state
Write-Host "Found '$($DomainControllers.Count)' domain controllers in '$($Domain.Name)' domain"

# populate list of domain controllers
try {
	$OrderedDomainControllers = Get-ADDomainControllerAndPeers -Server $DomainController
}
catch {
	throw $_
}

# report state
Write-Host "Found '$($OrderedDomainControllers.Count)' domain controllers after ordering"

# define list for peers of original domain controller
$DomainControllerPeers = [System.Collections.Generic.List[object]]::new()

# loop through domain controllers
:NextDomainController foreach ($OrderedDomainController in $OrderedDomainControllers) {
	# skip role owner
	if ($OrderedDomainController.Name -eq $DomainController.Name) {
		# report skip and continue
		Write-Verbose -Message "[ ] excluding original domain controller: $($OrderedDomainController.Name)"
		continue NextDomainController
	}

	# if skip global catalog check not present and domain is not a global catalog...
	if (!$SkipGlobalCatalogCheck.IsPresent -and $OrderedDomainController.Name -notin $GlobalCatalogs.Name) {
		# report skip and continue
		Write-Verbose -Message "[ ] skipping not-a-global-catalog server: $($OrderedDomainController.Name)"
		continue NextDomainController
	}

	# connect to RootDSE on domain controller
	try {
		$DirectoryEntry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$($OrderedDomainController.Name)/RootDSE")
	}
	catch {
		# report skip and continue
		Write-Warning -Message "[ ] skipping unreachable domain controller: $($OrderedDomainController.Name): $($_.Exception.Message)"
		continue NextDomainController
	}

	# if domain controller is an RODC...
	if ($DirectoryEntry.supportedCapabilities.Contains('1.2.840.113556.1.4.1920')) {
		# report skip and continue
		Write-Verbose -Message "[ ] skipping read-only domain controller: $($OrderedDomainController.Name)"
		continue NextDomainController
	}

	# if count per site parameter provided...
	if ($PSBoundParameters.ContainsKey('CountPerSite')) {
		# define count in current site as count of domain controllers already in list and in same site as current domain controller
		$CountInCurrentSite = $DomainControllerPeers.Where({ $_.SiteName -eq $OrderedDomainController.SiteName }).Count
	
		# if count in current site is greater than or equal to requested count per site...
		if ($CountInCurrentSite -ge $CountPerSite) {
			# report skip and continue
			Write-Verbose -Message "[ ] skipping excessive domain controller: $($OrderedDomainController.Name) (list already contains '$CountInCurrentSite' domain controller(s) from same site)"
			continue NextDomainController
		}
	}	
	
	# if count parameter provided...
	if ($PSBoundParameters.ContainsKey('Count')) {
		# if count of domain controllers in list is greater than or equal to requested count...
		if ($DomainControllerPeers.Count -ge $Count) {
			# report skip and continue
			Write-Verbose -Message "[ ] skipping writeable domain controller: $($OrderedDomainController.Name) (list already contains '$($DomainControllerPeers.Count)' domain controller(s))"
			continue NextDomainController
		}
	}

	# add domain controller object to list
	$DomainControllerPeers.Add($OrderedDomainController)

	# report state
	Write-Verbose -Message "[X] selected writeable domain controller: $($OrderedDomainController.Name)"
}

# switch on output type
switch ($OutputType) {
	'Name' {
		# add domain controller name to list
		$Values = $DomainControllerPeers.Name

	}
	'Object' {
		# add domain controller object to list
		$Values = $DomainControllerPeers
	}
}

# if count is 1...
if ($Count -eq 1) {
	# define value as first object from values list
	$Value = $Values | Select-Object -First 1
}
# if count is not 1...
else {
	# define value as values list
	$Value = $Values
}

# if AsVariable requested...
if ($AsVariable.IsPresent) {
	New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
}
else {
	return $Value
}
