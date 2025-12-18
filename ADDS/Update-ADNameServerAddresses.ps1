[CmdletBinding(SupportsShouldProcess)]
param(
    # mode for script
    [Parameter(Position = 0)][ValidateSet('DomainController', 'Member')]
    [string]$Mode = 'DomainController',
    # network adapter name
    [Parameter(Position = 1)]
    [string]$Name = 'Ethernet',
    # preferred site name
    [Parameter(Position = 2)]
    [string]$PreferredPeerSiteName = 'Default-First-Site-Name',
    # preferred site name
    [Parameter(Position = 3)]
    [string]$PreferredPeerSiteLinkName = 'DEFAULTIPSITELINK',
    # local host name
    [Parameter(DontShow)]
    [string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
    # local domain name
    [Parameter(DontShow)]
    [string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
    # local DNS hostname
    [Parameter(DontShow)]
    [string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
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

function Find-ADNameServerAddresses {
    # retrieve other writeable global catalogs in current forest 
    $GlobalCatalogsInForest = $GlobalCatalogs.Where({ $_.OutboundConnections.Count -gt 0 -and $_.Name -ne $DnsHostName })

    # switch on other writeable global catalogs in current forest count
    switch ($GlobalCatalogsInForest.Count) {
        0 {
            # report state and return
            Write-Host 'Found no other writeable domain controllers in current forest; cannot add peer IP addresses to DNS server addresses'
            return
        }
        1 {
            # report state
            Write-Host 'Found one other writeable domain controller in current forest; adding peer IP address to DNS server addresses'

            # retrieve peer domain controller
            $PeerDomainController = $GlobalCatalogsInForest | Where-Object { $_.Name -ne $DnsHostName }

            # add IP address of peer to DNS server addresses
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # return after updating DNS server addresses
            return
        }
        Default {
            # report state
            Write-Host "Found '$($GlobalCatalogsInForest.Count)' other writeable domain controllers in current forest; checking for domain controllers in computer domain"
        }
    }

    # STATE: forest contains 2 other GCs 

    # retrieve other writeable global catalogs in computer domain
    $GlobalCatalogsInDomain = $GlobalCatalogs.Where({ $_.OutboundConnections.Count -gt 0 -and $_.Name -ne $DnsHostName -and $_.Domain.Name -eq $Domain.Name })

    # switch on other writeable global catalogs in computer domain count
    switch ($GlobalCatalogsInDomain.Count) {
        0 {
            # STATE: forest contains at least 2 other GCs, domain contains 0 other GCs

            # report state
            Write-Host 'Found no other writeable domain controllers in computer domain; checking other domains in the forest'

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInForest
            # $GlobalCatalogSource = 'current forest'
        }
        1 {
            # STATE: forest contains at least 2 other GCs, domain contains 1 other GC

            # report state
            Write-Host 'Found one other writeable domain controller in computer domain; adding peer IP address to DNS server addresses'

            # retrieve peer domain controller
            $PeerDomainController = $GlobalCatalogsInDomain | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInForest.Where({ $_.Domain.Name -ne $Domain.Name })
            # $GlobalCatalogSource = 'current forest'
        }
        Default {
            # STATE: forest contains at least 2 other GCs, domain contains at least 2 other GCs

            # report state
            Write-Host "Found '$($GlobalCatalogsInDomain.Count)' other writeable domain controllers in computer domain; checking for domain controllers in same site"

            # define other global catalogs
            $OtherGlobalCatalogs = $GlobalCatalogsInDomain
            # $GlobalCatalogSource = 'computer domain'
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
            Write-Host 'Found no other writeable domain controllers in same site; checking for domain controllers in next closest site'
        }
        1 {
            # STATE: forest contains at least 2 other GCs, current site contains 1 other GC

            # report state
            Write-Host 'Found one other writeable domain controller in same site; adding peer IP address to DNS server addresses'

            # retrieve peer domain controller
            $PeerDomainController = $OtherGlobalCatalogsInSameSite | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"
        }
        Default {
            # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs

            # report state
            Write-Host "Found '$($OtherGlobalCatalogsInSameSite.Count)' available domain controllers in same site; identifying first available domain controller"

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
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

            # if domain role is member...
            if ($DomainRole -lt 4) {
                # report state
                Write-Host "Found member domain role with multiple domain controllers available in same site; identifying second available domain controller"

                # retrieve peer domain controller from list with custom sort
                $PeerDomainController = $OtherGlobalCatalogsInSameSite | Where-Object { $_.Name -eq $ArrangedDomainControllerNames[2] }

                # add IP address of peer to DNS server addresses
                $ServerAddresses.Add($PeerDomainController.IPAddress)

                # report state
                Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                # return after updating DNS server addresses
                return
            }

            # switch on other global catalogs in other sites count
            switch ($OtherGlobalCatalogsInOtherSites.Count) {
                0 {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contain 0 other GCs

                    # report state
                    Write-Host 'Found no other writeable domain controllers in other sites; identifying next peer domain controller'

                    # retrieve next peer domain controller
                    $PeerDomainController = $OtherGlobalCatalogsInSameSite | Where-Object { $_.Name -eq $ArrangedDomainControllerNames[2] }

                    # add IP address of next peer to DNS server addresses
                    $ServerAddresses.Add($PeerDomainController.IPAddress)

                    # report state
                    Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                    # return after adding second entry to list
                    return
                }
                1 {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contain 1 other GC

                    # report state
                    Write-Host 'Found one other writeable domain controllers in other sites; identifying last peer domain controller'

                    # retrieve next peer domain controller
                    $PeerDomainController = $OtherGlobalCatalogsInOtherSites | Select-Object -First 1

                    # add IP address of next peer to DNS server addresses
                    $ServerAddresses.Add($PeerDomainController.IPAddress)

                    # report state
                    Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"

                    # return after adding second entry to list
                    return
                }
                Default {
                    # STATE: forest contains at least 2 other GCs, current site contains at least 2 other GCs, other sites contains at least 2 other GCs

                    # report state
                    Write-Host "Found '$($OtherGlobalCatalogsInOtherSites.Count)' writeable domain controllers in other sites; checking for domain controllers in next closest site"

                    # define other global catalogs
                    $OtherGlobalCatalogs = $GlobalCatalogsInDomain
                    # $GlobalCatalogSource = 'computer domain'
                }
            }
        }
    }

    # return if two server addresses added
    if ($ServerAddresses.Count -eq 2) {
        return
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
                    Write-Warning 'Found no site links with lowest cost; review code to determine how this happened'
                    return
                }
                1 {
                    # STATE: forest contains at least 2 other GCs, other sites contains at least 2 other GCs, current site has 1 adjacent site with lowest cost

                    # report state
                    Write-Host 'Found one site link with the lowest cost site; identifying peer sites'

                    # retrieve site link from collection
                    $SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Select-Object -First 1
                }
                Default {
                    # report state
                    Write-Host "Found '$($SiteLinksWithLowestCost.Count)' site links with lowest cost for current site, checking for preferred site link: '$PreferredPeerSiteLinkName'"

                    # if preferred peer site link name found in site links with lowest cost...
                    if ($PreferredPeerSiteLinkName -in $SiteLinksWithLowestCost.Name) {
                        # report state
                        Write-Host 'Found preferred site link, identifying peer sites'

                        # retrieve preferred site link
                        $SiteLinkWithLowestCost = $SiteLinksWithLowestCost | Where-Object { $_.Name -eq $PreferredPeerSiteLinkName }
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
            $AdjacentSitesWithLowestCost = $AdjacentSites.Where({ $_.SiteLinks.Name -contains $SiteLinkWithLowestCost.Name })

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
                        Write-Host 'Found preferred peer site, identifying domain controllers in peer site'

                        # retrieve nearest site from adjacent sites by preferred name
                        $NearestSite = $AdjacentSitesWithLowestCost | Where-Object { $_.Name -eq $PreferredPeerSiteName }
                    }
                    # if preferred peer site name not found in adjacent sites with lowest cost...
                    else {
                        # report state
                        Write-Host 'Preferred peer site not found, selecting first site alphabetically'

                        # retrieve nearest site from adjacent sites alphabetically by name
                        $NearestSite = $AdjacentSitesWithLowestCost | Sort-Object -Property Name | Select-Object -First 1

                        # report state
                        Write-Host "Selected '$($AdjacentSite.Name)' peer site, identifying domain controllers in peer site"
                    }
                }
            }
        }
    }

    # retrieve items for other global catalogs in nearest site
    $OtherGlobalCatalogsInNearestSite = $OtherGlobalCatalogs.Where({ $_.SiteName -eq $NearestSite.Name })

    # switch on count of other global catalogs in nearest site
    switch ($OtherGlobalCatalogsInNearestSite.Count) {
        0 {
            # report state
            Write-Host 'Found no domain controllers in nearest site; cannot add peer IP addresses to DNS server addresses'
            return
        }
        1 {
            # report state
            Write-Host 'Found one domain controller in nearest site; adding peer IP address to DNS server addresses'

            # retrieve peer domain controller
            $PeerDomainController = $DomainControllersInPeerSite | Select-Object -First 1

            # add IP address of peer to DNS server addresses
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"
        }
        Default {
            # report state
            Write-Host "Found '$($OtherGlobalCatalogsInNearestSite.Count)' domain controllers in nearest site; selecting peer domain controller by parity of last character in local computer name"

            # retrieve last character from computer name as byte
            $LastCharacter = $env:COMPUTERNAME[-1] -as [byte]

            # if last character is odd...
            if ($LastCharacter % 2 -eq 1) {
                # set index to 1
                $Index = 1
            }
            # if last character is even or 0...
            else {
                # set index to 0
                $Index = 0
            }

            # retrieve peer domain controller by index
            $PeerDomainController = $DomainControllersInPeerSite[$Index]

            # add IP address of peer to DNS server addresses
            $ServerAddresses.Add($PeerDomainController.IPAddress)

            # report state
            Write-Host "Added '$($PeerDomainController.IPAddress)' IP address of '$($PeerDomainController.Name)' domain controller to DNS server addresses"
        }
    }

    # return if two server addresses added
    if ($ServerAddresses.Count -eq 2) {
        return
    }
}

# retrieve the named physical network adapter
try {
    $NetAdapter = Get-NetAdapter -Physical -Name $Name -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not locate '$Name' network adapter"
    throw $_
}

# retrieve forest
try {
    $Forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
}
catch {
    Write-Warning -Message 'could not retrieve current forest'
    throw $_
}

# retrieve forest
try {
    $Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
}
catch {
    Write-Warning -Message 'could not retrieve computer domain'
    throw $_
}

# retrieve global catalogs in forest
$GlobalCatalogs = $Forest.GlobalCatalogs

# if no global catalogs in forest found...
if ($GlobalCatalogs.Count -eq 0) {
    Write-Warning -Message 'could not locate any writeable domain controllers with global catalog role in current forest'
    return
}

# retrieve computer site
try {
    $ActiveDirectorySite = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite()
}
catch {
    Write-Warning -Message 'could not retrieve computer site'
    throw $_
}

# define list for DNS server addresses
$ServerAddresses = [System.Collections.Generic.List[string]]::new()

# find DNS server addresses
try {
    Find-ADNameServerAddresses
}
catch {
    throw $_
}

# if mode is domain controller...
if ($Mode -eq 'DomainController') {
    # add localhost to DNS server addresses
    $ServerAddresses.Add('127.0.0.1')

    # report state
    Write-Host "Added '127.0.0.1' IP address for 'localhost' to DNS server addresses for current or future domain controller"
}

# convert DNS server addresses list to string array
$ServerAddresses = $ServerAddresses -as [string[]]

# define should process components
$ShouldProcessTarget = $NetAdapter.Name
$ShouldProcessAction = "set DNS server addresses: $($ServerAddresses -join ', ')"

# if should process...
if ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
    # set DNS server addresses on network adapter
    try {
        Set-DnsClientServerAddress -InterfaceAlias $NetAdapter.InterfaceAlias -ServerAddresses $ServerAddresses
    }
    catch {
        throw $_
    }

    # report state
    Write-Host "Set DNS server addresses on '$Name' network adapter: $($ServerAddresses -join ', ')"
}
