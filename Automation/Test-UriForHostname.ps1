<#
.SYNOPSIS
Test if the content retrieved from a URI matches the local hostname.

.DESCRIPTION
Test if the content retrieved from a URI matches the local hostname.

.PARAMETER Uri
The URI with content to evaluate.

.PARAMETER Hostname
The local hostname expected in the content at the URI. The default value is the hostname of the local system.

.INPUTS
Uri.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-UriForHostname.ps1 -Uri 'https://www.example.com/host/'

.NOTES
The URI must have a trailing backslash if the URI points to a folder rather than a file.
#>

Param(
	# URI to evaluate
	[Parameter(Position = 0, Mandatory = $True)]
	[uri]$Uri,
	# local host name
	[Parameter(Position = 1)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant()
)

Begin {
	Function Get-UriWithIPAddressFromUriWithHostname {
		Param(
			# a URI object or a string that can be cast a URI object
			[Parameter(Mandatory = $true)]
			[System.Uri]$Uri,
			# the DNS server to resolve the URI against
			[Parameter(DontShow)][ValidateScript({ [System.Net.IPAddress]::TryParse($_, [ref][System.Net.IPAddress]::None) })]
			[System.Net.IPAddress]$DnsServer = '1.1.1.1',
			# the DNS record type to resolve
			[Parameter(DontShow)][ValidateScript({ [Microsoft.DnsClient.Commands.RecordType].IsEnumDefined($_) })]
			[string]$Type = 'A'
		)

		# define parameters
		$ResolveDnsName = @{
			Name        = $Uri.DnsSafeHost
			Server      = $DnsServer.IPAddressToString
			Type        = $Type
			DnsOnly     = $True
			NoHostsFile = $True
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define object for retry loop
		$ErrorList = [System.Collections.Generic.List[object]]::new()
		$RetryCount = 0
		$Unresolved = $true

		# resolve hostname from URI with retry
		While ($Unresolved -and $RetryCount -lt 5) {
			# resolve hostname
			Try {
				$DnsName = Resolve-DnsName @ResolveDnsName
			}
			Catch {
				# add error to error list
				$ErrorList.Add($_)
				# increment retry counter
				$RetryCount++
				# sleep for one second
				Start-Sleep -Seconds 1
			}
			# verify hostname resolved to requested type
			If ($DnsName.Where({ $_.Type -eq $Type }).Count -gt 0) {
				$Unresolved = $false
			}
		}

		# if hostname not resolved...
		If ($Unresolved) {
			Return $ErrorList
		}

		# filter results and extract IPAddress
		$IPAddress = $DnsName.Where({ $_.Type -eq $Type }).IPAddress

		# check for
		switch ($IPAddress.Count) {
			# if 0 records in IPAddress...
			0 {
				# warn and return null
				Write-Warning -Message "could not resolve any DNS '$Type' records for DnsSafeHost '$($Uri.DnsSafeHost)' of Uri: $($Uri.AbsoluteUri)"
				Return $null
			}
			# if 1 record in IPaddress...
			1 {
				# break out of switch and continue
				Break
			}
			# if more than 1 record in IPaddress...
			Default {
				# select first address and continue
				$IPAddress = $IPAddress[0]
			}
		}

		# report IP address
		Write-Verbose -Message "resolved IP address '$IPAddress' from URL: '$($Uri.AbsoluteUri)'"

		# update URI with IP address
		Try {
			$Uri = [Uri]$Uri.AbsoluteUri.Replace($Uri.DnsSafeHost, $IPAddress)
		}
		Catch {
			Write-Warning -Message "could not construct host URL from IP: '$($Uri.AbsoluteUri)'"
			Return $_
		}

		# return updated URI
		Write-Verbose -Message "constructed host URL from IP: '$($Uri.AbsoluteUri)'"
		Return $Uri
	}
}

Process {
	# validate URI
	If ($Uri.Scheme -notin 'http', 'https') {
		Write-Warning -Message "URI scheme is not 'http' or 'https'"
		Return
	}

	# record hostname from original Uri
	$UriHostName = $Uri.DnsSafeHost

	# get content of hosts file
	Try {
		$HostsFileContent = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	Catch {
		Write-Warning -Message 'could not read hosts file'
		Return $_
	}

	# if hosts contains an entry with hostname from Uri...
	If ($HostsFileContent -match "^[^#].*$($Uri.DnsSafeHost)$") {
		# report matching hosts entry found
		Write-Verbose -Message 'hosts file contains entry with hostname from the provided URI; resolving hostname to IP via DNS to build alternate URI'
		# resolve host in URI to IP Address to workaround potential hosts file resolution of ADFS servers
		Try {
			$Uri = Get-UriWithIPAddressFromUriWithHostname -Uri $Uri
		}
		Catch {
			Write-Warning -Message 'could not create new Uri with IPaddress from original Uri'
			Return $_
		}
	}

	# define parameters for Invoke-WebRequest
	$InvokeWebRequest = @{
		Uri                = $Uri
		Headers            = @{ 'host' = $UriHostName }
		UseBasicParsing    = $true
		MaximumRedirection = 0
		ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve content from URI
	Try {
		$WebRequest = Invoke-WebRequest @InvokeWebRequest
	}
	Catch {
		Write-Warning -Message "could not retrieve content from URI: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# parse content
	Try {
		$UriContent = $WebRequest.Content.Trim().ToLowerInvariant()
	}
	Catch {
		Write-Warning -Message "could not parse content retrieved from URI: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# if URI content matches hostname...
	If ($UriContent -eq $HostName) {
		Return $true
	}
	Else {
		Return $false
	}
}
