[CmdletBinding(SupportsShouldProcess)]
param(
    # switch for forcing domain controller behavior
    [switch]$ForceDomainControllerMode,
    # switch for forcing promotion behavior
    [switch]$ForcePromotionMode,
    # switch for forcing single site mode
    [switch]$ForceSingleSiteMode,
    # switch for including RODCs in list of global catalogs
    [switch]$IncludeReadOnlyDomainControllers,
    # network adapter name
    [Parameter(Position = 0)]
    [string]$InterfaceAlias = 'Ethernet',
    # preferred site name
    [Parameter(Position = 1)]
    [string]$PreferredPeerSiteName = 'Default-First-Site-Name',
    # preferred site name
    [Parameter(Position = 2)]
    [string]$PreferredPeerSiteLinkName = 'DEFAULTIPSITELINK',
    # count of server addresses to retrieve
    [Parameter(Position = 3)]
    [uint16]$CountOfServerAddresses = 2,
    # domain role of current system
    [Parameter(DontShow)]
    [uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole
)

function ConvertTo-ListSortedFromFirstObject {
    param(
        [object]$InputObject,
        [object]$FirstObject
    )

    # define list for objects
    $ListOfObjects = [System.Collections.Generic.List[object]]::new()

    # FIRST PASS: populates list with the defined object and all subsequent objects

    # loop through objects
    foreach ($Object in $InputObject) {
        # if object not in the list and object is the first object or list already contains the first object
        if ($Object -notin $ListOfObjects -and ($Object -eq $FirstObject -or $ListOfObjects -contains $FirstObject)) {
            # add object to the list
            $ListOfObjects.Add($Object)
        }
    }

    # SECOND PASS: completes the list with objects before the first object

    # loop through objects
    foreach ($Object in $InputObject) {
        # if object not in the list...
        if ($Object -notin $ListOfObjects) {
            # add object to the list
            $ListOfObjects.Add($Object)
        }
    }

    # return list
    return , $ListOfObjects
}

function Find-DnsClientServerAddressesFromAD {
    # switch on other writeable global catalogs in current forest count
    switch ($GlobalCatalogsInForest.Count) {
        0 {
            # report state and return
            Write-Host "Found no $Adjectives domain controllers in '$ForestName' forest; cannot add peer IP addresses to DNS server addresses"
            return
        }
        1 {
            # report state
            Write-Host "Found one $Adjectives domain controller in '$ForestName' forest; adding peer IP address to DNS server addresses"

            # retrieve peer domain controller
            $PeerDomainController = $GlobalCatalogsInForest | Where-Object { $_.Name -ne $DnsHostName }

            # add IP address of peer to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # return after updating DNS server addresses
            return
        }
        Default {
            # report state
            Write-Host "Found '$($GlobalCatalogsInForest.Count)' $Adjectives domain controllers in '$ForestName' forest; checking for domain controllers in computer domain"
        }
    }

    # STATE: forest contains 2 other GCs 

    # switch on other writeable global catalogs in computer domain count
    switch ($GlobalCatalogsInDomain.Count) {
        0 {
            # STATE: forest contains at least 2 other GCs, domain contains 0 other GCs

            # report state
            Write-Host "Found no $Adjectives domain controllers in '$DomainName' domain; checking other domains in the forest"

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInForest
            # $GlobalCatalogSource = 'current forest'
        }
        1 {
            # STATE: forest contains at least 2 other GCs, domain contains 1 other GC

            # report state
            Write-Host "Found one $Adjectives domain controller in '$DomainName' domain; adding peer IP address to DNS server addresses"

            # retrieve peer domain controller
            $PeerDomainController = $GlobalCatalogsInDomain | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInForest.Where({ $_.Domain.Name -ne $Domain.Name })
        }
        Default {
            # STATE: forest contains at least 2 other GCs, domain contains at least 2 other GCs

            # report state
            Write-Host "Found '$($GlobalCatalogsInDomain.Count)' $Adjectives domain controllers in '$DomainName' domain; checking for domain controllers in same site"

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInDomain
        }
    }

    # retrieve items for other global catalogs in the same site
    $OtherGlobalCatalogsInSameSite = $OtherGlobalCatalogs.Where({ $_.SiteName -eq $ActiveDirectorySite.Name })

    # retrieve items for other global catalogs in other sites
    $OtherGlobalCatalogsInOtherSites = $OtherGlobalCatalogs.Where({ $_.SiteName -ne $ActiveDirectorySite.Name })

    # switch on count of other global catalogs in the same site
    switch ($OtherGlobalCatalogsInSameSite.Count) {
        0 {
            # STATE: forest contains at least 2 other GCs, current site contains 0 other GCs

            # report state and return
            Write-Host "Found no $Adjectives domain controllers in '$ActiveDirectorySiteName' site; checking for domain controllers in next closest site"
        }
        1 {
            # STATE: forest contains at least 2 other GCs, current site contains 1 other GC

            # report state
            Write-Host "Found one $Adjectives domain controller in '$ActiveDirectorySiteName' site; adding peer IP address to DNS server addresses"

            # retrieve peer domain controller
            $PeerDomainController = $OtherGlobalCatalogsInSameSite | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # if server addresses is at least requested count...
            if ($DesiredServerAddresses -ge $CountOfServerAddresses) {
                return
            }
        }
        default {
            # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, no DNS servers selected

            # if domain role is member...
            if ($DomainRole -lt 4) {
                # report state
                Write-Host "Found '$($OtherGlobalCatalogsInSameSite.Count)' $Adjectives domain controllers in '$ActiveDirectorySiteName' site; selecting first domain controller by parity of last character in local computer name"

                # retrieve last character from computer name as byte
                $LastCharacter = $env:COMPUTERNAME[-1] -as [byte]

                # if last character is odd...
                if ($LastCharacter % 2 -eq 1) {
                    # set parity index to 1
                    $ParityIndex = 1
                    # set member index to 0
                    $MemberIndex = 0
                }
                # if last character is even or 0...
                else {
                    # set parity index to 0
                    $ParityIndex = 0
                    # set member index to 1
                    $MemberIndex = 1
                }

                # select global catalog by parity index
                $SelectedGlobalCatalog = $OtherGlobalCatalogsInSameSite[$ParityIndex]

                # add IP address of selected global catalog to DNS server addresses
                $DesiredServerAddresses.Add($SelectedGlobalCatalog.IPAddress)

                # report state
                Write-Host " - added '$($SelectedGlobalCatalog.IPAddress)' IP address of '$($SelectedGlobalCatalog.Name)' domain controller to DNS server addresses"

                # if server addresses is at least requested count...
                if ($DesiredServerAddresses -ge $CountOfServerAddresses) {
                    return
                }

                # report state
                Write-Host "Found one DNS server selected; selecting next domain controller in '$ActiveDirectorySiteName' site by parity of last character in local computer name"

                # select global catalog by member index
                $SelectedGlobalCatalog = $OtherGlobalCatalogsInNearestSite[$MemberIndex]

                # add IP address of selected global catalog to DNS server addresses
                $DesiredServerAddresses.Add($SelectedGlobalCatalog.IPAddress)

                # report state
                Write-Host " - added '$($SelectedGlobalCatalog.IPAddress)' IP address of '$($SelectedGlobalCatalog.Name)' domain controller to DNS server addresses"

                # return after adding second DNS server to list
                return
            }

            # report state
            Write-Host "Found '$($OtherGlobalCatalogsInSameSite.Count)' $Adjectives domain controllers in '$ActiveDirectorySiteName' site; identifying first available domain controller"

            # define sorted set for domain controllers in current site
            $DomainControllersForSameSite = [System.Collections.Generic.SortedSet[string]]::new()

            # loop through domain controllers in same site
            foreach ($OtherGlobalCatalogInSameSite in $OtherGlobalCatalogsInSameSite) {
                # add domain controllers to set
                $null = $DomainControllersForSameSite.Add($OtherGlobalCatalogInSameSite.Name)
            }

            # add local computer to sorted set for custom sort
            $null = $DomainControllersForSameSite.Add($DnsHostName)

            # convert sorted set to list with custom sort where local computer is first object
            try {
                $ArrangedDomainControllerNames = ConvertTo-ListSortedFromFirstObject -InputObject $DomainControllersForSameSite -FirstObject $DnsHostName
            }
            catch {
                throw $_
            }

            # retrieve first peer domain controller from list with custom sort
            $PeerDomainController = $OtherGlobalCatalogsInSameSite | Where-Object { $_.Name -eq $ArrangedDomainControllerNames[1] }

            # add IP address of first peer domain controller to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($SelectedGlobalCatalog.IPAddress)' IP address of '$($SelectedGlobalCatalog.Name)' domain controller to DNS server addresses"

            # if single site mode requested...
            if ($ForceSingleSiteMode) {
                # report state
                Write-Host "Found single site mode requested with multiple $Adjectives domain controllers available in '$ActiveDirectorySiteName' site; identifying next available domain controller"

                # retrieve peer domain controller from list with custom sort
                $PeerDomainController = $OtherGlobalCatalogsInSameSite | Where-Object { $_.Name -eq $ArrangedDomainControllerNames[2] }

                # add IP address of peer to DNS server addresses
                $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

                # report state
                Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                # return after updating DNS server addresses
                return
            }

            # switch on other global catalogs in other sites count
            switch ($OtherGlobalCatalogsInOtherSites.Count) {
                0 {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contain 0 other GCs

                    # report state
                    Write-Host "Found no $Adjectives domain controllers in other sites; identifying next peer domain controller"

                    # retrieve next peer domain controller
                    $PeerDomainController = $OtherGlobalCatalogsInSameSite | Where-Object { $_.Name -eq $ArrangedDomainControllerNames[2] }

                    # add IP address of next peer to DNS server addresses
                    $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

                    # report state
                    Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                    # return after adding second entry to list
                    return
                }
                1 {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contain 1 other GC

                    # report state
                    Write-Host "Found one $Adjectives domain controllers in other sites; identifying last peer domain controller"

                    # retrieve next peer domain controller
                    $PeerDomainController = $OtherGlobalCatalogsInOtherSites | Select-Object -First 1

                    # add IP address of next peer to DNS server addresses
                    $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

                    # report state
                    Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                    # return after adding second entry to list
                    return
                }
                Default {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contains at least 2 other GCs

                    # report state
                    Write-Host "Found '$($OtherGlobalCatalogsInOtherSites.Count)' $Adjectives domain controllers in other sites; checking for domain controllers in next closest site"

                    # define other global catalogs
                    $OtherGlobalCatalogs = $GlobalCatalogsInDomain
                    # $GlobalCatalogSource = 'computer domain'
                }
            }
        }
    }

    # retrieve items for adjacent sites with domain controllers
    $AdjacentSites = $ActiveDirectorySite.AdjacentSites.Where({ $_.Servers.Count })

    # switch on count of adjacent sites with domain controllers
    switch ($AdjacentSites.Count) { 
        0 {
            # report state
            Write-Host 'Found no adjacent sites with domain controllers, cannot add peer IP addresses to DNS server addresses'

            # return
            return
        }
        1 {
            # report state
            Write-Host 'Found one adjacent site with domain controllers, identifying domain controllers in site'

            # define nearest site from only adjacent site
            $NearestSite = $AdjacentSites | Select-Object -First 1
        }
        Default {
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
                    Write-Warning 'Found no site links with lowest cost for '$ActiveDirectorySiteName' site; review code to determine how this happened'
                    return
                }
                1 {
                    # STATE: forest contains at least 2 other GCs, other sites contains at least 2 other GCs, current site has 1 adjacent site with lowest cost

                    # report state
                    Write-Host 'Found one site link with lowest cost for '$ActiveDirectorySiteName' site; identifying peer sites'

                    # retrieve site link from collection
                    $SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Select-Object -First 1
                }
                Default {
                    # report state
                    Write-Host "Found '$($SiteLinksWithLowestCost.Count)' site links with lowest cost for '$ActiveDirectorySiteName' site; checking for preferred site link: '$PreferredPeerSiteLinkName'"

                    # if preferred peer site link name found in site links with lowest cost...
                    if ($PreferredPeerSiteLinkName -in $SiteLinksWithLowestCost.Name) {
                        # report state
                        Write-Host 'Found '$PreferredPeerSiteLinkName' preferred site link, identifying peer sites'

                        # retrieve preferred site link
                        $SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Where-Object { $_.Name -eq $PreferredPeerSiteLinkName } | Select-Object -First 1
                    }
                    # if preferred peer site link name not found in site links with lowest cost...
                    else {
                        # report state
                        Write-Host 'Preferred site link not found, selecting first site link alphabetically'

                        # retrieve preferred site link alphabetically by name
                        $SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Sort-Object -Property Name | Select-Object -First 1

                        # report state
                        Write-Host "Selected '$($SiteLinkWithLowestCost.Name)' site link, identifying peer sites"
                    }
                }
            }

            # retrieve adjacent sites with lowest cost
            $AdjacentSitesWithLowestCost = $AdjacentSites.Where({ $_.SiteLinks.Name -eq $SiteLinkWithLowestCost.Name })

            # switch on adjacent sites with lowest cost count
            switch ($AdjacentSitesWithLowestCost.Count) {
                0 {
                    # report state
                    Write-Warning 'Found no adjacent site with lowest cost; review code to determine how this happened'

                    # return out of frustration
                    return
                }
                1 {
                    # report state
                    Write-Host 'Found one adjacent site with lowest cost; identifying peer domain controllers'

                    # retrieve nearest site from only adjacent site from with lowest cost
                    $NearestSite = $AdjacentSitesWithLowestCost | Select-Object -First 1
                }
                Default {
                    # report state
                    Write-Host "Found '$($AdjacentSitesWithLowestCost.Count)' adjacent sites with lowest cost, checking for preferred site: '$PreferredPeerSiteName'"

                    # if preferred peer site name found in adjacent sites with lowest cost...
                    if ($PreferredPeerSiteName -in $AdjacentSitesWithLowestCost.Name) {
                        # report state
                        Write-Host 'Found '$PreferredPeerSiteName' preferred peer site, identifying domain controllers in peer site'

                        # retrieve nearest site from adjacent sites by preferred name
                        $NearestSite = $AdjacentSitesWithLowestCost | Where-Object { $_.Name -eq $PreferredPeerSiteName }
                    }
                    # if preferred peer site name not found in adjacent sites with lowest cost...
                    else {
                        # report state
                        Write-Host 'Preferred '$PreferredPeerSiteName' peer site not found, selecting first site alphabetically'

                        # retrieve nearest site from adjacent sites alphabetically by name
                        $NearestSite = $AdjacentSitesWithLowestCost | Sort-Object -Property Name | Select-Object -First 1

                        # report state
                        Write-Host "Selected '$($NearestSite.Name)' peer site, identifying domain controllers in peer site"
                    }
                }
            }
        }
    }

    # define name of nearest site for reporting
    $NearestSiteName = $NearestSite.Name

    # retrieve items for other global catalogs in nearest site
    $OtherGlobalCatalogsInNearestSite = $OtherGlobalCatalogs.Where({ $_.SiteName -eq $NearestSiteName })

    # switch on count of other global catalogs in nearest site
    switch ($OtherGlobalCatalogsInNearestSite.Count) {
        0 {
            # report state
            Write-Host 'Found no domain controllers in '$NearestSiteName' site; cannot add peer IP addresses to DNS server addresses'
            return
        }
        1 {
            # report state
            Write-Host 'Found one domain controller in '$NearestSiteName' site; adding peer IP address to DNS server addresses'

            # retrieve peer domain controller
            $PeerDomainController = $OtherGlobalCatalogsInNearestSite | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"
        }
        Default {
            # report state
            Write-Host "Found '$($OtherGlobalCatalogsInNearestSite.Count)' domain controllers in '$NearestSiteName' site; selecting domain controller by parity of last character in local computer name"

            # retrieve last character from computer name as byte
            $LastCharacter = $env:COMPUTERNAME[-1] -as [byte]

            # if last character is odd...
            if ($LastCharacter % 2 -eq 1) {
                # set parity index to 1
                $ParityIndex = 1
                # set member index to 0
                $MemberIndex = 0
            }
            # if last character is even or 0...
            else {
                # set parity index to 0
                $ParityIndex = 0
                # set member index to 1
                $MemberIndex = 1
            }

            # retrieve peer domain controller by parity index
            $PeerDomainController = $OtherGlobalCatalogsInNearestSite[$ParityIndex]

            # add IP address of peer to DNS server addresses
            $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # if server addresses is at least requested count...
            if ($DesiredServerAddresses -ge $CountOfServerAddresses) {
                return
            }

            # if only one server address found...
            if ($DesiredServerAddresses.Count -eq 1) {
                # report state
                Write-Host "Found one domain controller in DNS server addresses with multiple domain controllers available in '$NearestSiteName' site; identifying second available domain controller"

                # retrieve peer domain controller from list with custom sort
                $PeerDomainController = $OtherGlobalCatalogsInNearestSite[$MemberIndex]

                # add IP address of peer to DNS server addresses
                $DesiredServerAddresses.Add($PeerDomainController.IPAddress)

                # report state
                Write-Host " - added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"
            }
        }
    }
}

# if interface alias explicitly provided...
if ($PSBoundParameters.ContainsKey('InterfaceAlias')) {
    # retrieve network adapter by interface alias
    try {
        $NetAdapter = Get-NetAdapter -InterfaceAlias $InterfaceAlias -ErrorAction 'ignore'
    }
    catch {
        Write-Warning -Message "could not locate network adapter with '$InterfaceAlias' interface alias"
        return
    }

    # if default route not found...
    if ($null -eq $NetAdapter) {
        Write-Warning -Message "could not locate network adapterwith '$InterfaceAlias' interface alias"
        return
    }
}
# if interface alias explicitly provided...
else {
    # retrieve the default route
    try {
        $NetRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0'
    }
    catch {
        Write-Warning -Message 'could not retrieve default route'
        throw $_
    }

    # if default route not found...
    if ($null -eq $NetRoute) {
        Write-Warning -Message "could not locate network route matching '0.0.0.0/0' destination prefix"
        return
    }

    # if multiple default routes found...
    if ($NetRoute -is [array]) {
        # filter network routes by interface alias
        $NetRoute = $NetRoute | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias }
    }

    # if net route not found...
    if ($null -eq $NetRoute) {
        Write-Warning -Message "could not locate default route matching '$InterfaceAlias' interface alias"
        return
    }

    # retrieve the physical network adapter for default route
    try {
        $NetAdapter = Get-NetAdapter -Physical -InterfaceIndex $NetRoute.InterfaceIndex -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message 'could not locate network adapter for default route'
        throw $_
    }

    # define interface alias for reporting
    $InterfaceAlias = $NetAdapter.InterfaceAlias
}

# retrieve current DNS server addresses
try {
    $CurrentServerAddresses = Get-DnsClientServerAddress -InterfaceIndex $NetAdapter.InterfaceIndex -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses
}
catch {
    Write-Warning -Message "could not retrieve current DNS client server addresses on '$InterfaceAlias' network adapter"
    throw $_
}

# retrieve forest
try {
    $Forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
    $ForestName = $Forest.Name
}
catch {
    Write-Warning -Message 'could not retrieve current forest'
    throw $_
}

# retrieve domain
try {
    $Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    $DomainName = $Domain.Name
}
catch {
    Write-Warning -Message 'could not retrieve computer domain'
    throw $_
}

# define DNS host name
$DnsHostName = '{0}.{1}' -f $env:COMPUTERNAME.ToLowerInvariant(), $DomainName

# if domain controller mode requested...
if ($ForceDomainControllerMode) {
    # set domain role to 4
    $DomainRole = 4
}

# if domain role is domain controller...
if ($DomainRole -ge 4) {
    $Adjectives = 'other writeable'
}
else {
    $Adjectives = 'writeable'
}

# define initial collection for global catalogs
$GlobalCatalogs = [System.Collections.Generic.List[object]]::new()

# loop through global catalogs in forest
:NextGlobalCatalog foreach ($GlobalCatalog in $Forest.GlobalCatalogs) {
    # if the global catalog is the current host...
    if ($GlobalCatalog.Name -eq $DnsHostName) {
        # report exclusion and continue
        Write-Warning -Message "[ ] excluding local global catalog: $($GlobalCatalog.Name)"
        continue NextGlobalCatalog
    }

    # connect to RootDSE
    try {
        $DirectoryEntry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$($GlobalCatalog.Name)/RootDSE")
    }
    catch {
        Write-Warning -Message "[ ] excluding unreachable global catalog: $($GlobalCatalog.Name): $($_.Exception.Message)"
        continue NextGlobalCatalog
    }

    # if the global catalog is an RODC...
    if ($DirectoryEntry.supportedCapabilities.Contains('1.2.840.113556.1.4.1920') -and -not $IncludeReadOnlyDomainControllers.IsPresent) {
        # report exclusion and continue
        Write-Verbose -Message "[ ] excluding read-only global catalog: $($GlobalCatalog.Name)"
        continue NextGlobalCatalog
    }

    # report state
    Write-Verbose -Message "[X] including global catalog: $($GlobalCatalog.Name)"

    # add global catalog to collection
    $GlobalCatalogs.Add($GlobalCatalog)
}

# filter global catalogs to current forest
$GlobalCatalogsInForest = $GlobalCatalogs.Where({ $_.Forest -eq $ForestName })

# filter global catalogs to current domain
$GlobalCatalogsInDomain = $GlobalCatalogs.Where({ $_.Forest -eq $DomainName })

# retrieve computer site
try {
    $ActiveDirectorySite = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite()
    $ActiveDirectorySiteName = $ActiveDirectorySite.Name
}
catch {
    Write-Warning -Message 'could not retrieve computer site'
    throw $_
}

# define list for desired DNS server addresses
$DesiredServerAddresses = [System.Collections.Generic.List[string]]::new()

# TODO: special modes for 

# find DNS server addresses
try {
    Find-DnsClientServerAddressesFromAD
}
catch {
    throw $_
}

# if domain role is domain controller...
if ($DomainRole -ge 4) {
    # add localhost to DNS server addresses
    $DesiredServerAddresses.Add('127.0.0.1')

    # report state
    Write-Host " - added '127.0.0.1' IP address for 'localhost' to DNS server addresses"
}

# if no desired DNS server addresses found...
if ($DesiredServerAddresses.Count -eq 0) {
    Write-Warning -Message "could not locate any $Adjectives domain controllers with global catalog role in '$ForestName' forest"
    return
}

# if force promotion mode requested...
if ($ForcePromotionMode) {
    $DesiredServerAddresses = $DesiredServerAddresses | Select-Object -First 1
}

# create strings
$CurrentServerAddressesString = [System.String]::Join(', ', $CurrentServerAddresses)
$DesiredServerAddressesString = [System.String]::Join(', ', $DesiredServerAddresses)

# if strings match...
if ($CurrentServerAddressesString -eq $DesiredServerAddressesString) {
    Write-Host "Found DNS server addresses on '$InterfaceAlias' network adapter already set to desired server addresses: $DesiredServerAddressesString"
    return
}

# convert desired DNS server addresses list to string array for Set-DnsClientServerAddress command
$ServerAddresses = $DesiredServerAddresses -as [string[]]

# define should process components
$ShouldProcessTarget = $NetAdapter.Name
$ShouldProcessAction = "set DNS server addresses: $DesiredServerAddressesString"

# if should process...
if ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
    # set DNS server addresses on network adapter
    try {
        Set-DnsClientServerAddress -InterfaceIndex $NetAdapter.InterfaceIndex -ServerAddresses $ServerAddresses
    }
    catch {
        throw $_
    }

    # report state
    Write-Host "Set DNS server addresses on '$InterfaceAlias' network adapter: $DesiredServerAddressesString"
}
