<#
.SYNOPSIS
Updates the local 'ActiveScriptHost' file with the name of the server actively servicing requests to ADFS.

.DESCRIPTION
Updates the local 'ActiveScriptHost' file with the name of the server actively servicing requests to ADFS. See the Notes for more details.

.PARAMETER Path
The path to the folder containing the 'script host' files.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsScriptHost.ps1 -Path C:\Content\adfs\host

.NOTES
This script is a key element in 'ActiveScriptHost' process that provides an effective "FSMO" to scripts run on ADFS server. This process assumes the following:
 1. The ADFS servers and Web Application Proxy servers are able to access a common file location. 
 2. The ADFS servers are load balanced in an active/passive fashion with a consistent active node.

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# path for script host files
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Path,
	# path for constructed uri
	[Parameter(Position = 1)]
	[string]$UriPath = '/host',
	# path for specific script host file
	[Parameter(Position = 2)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath "$HostName.txt")
)

Begin {
	Function Get-UriWithIPAddressFromUriWithHostname {
		Param(
			# a URI object or a string that can be cast a URI object
			[Parameter(Mandatory = $true)]
			[uri]$Uri,
			[Parameter(DontShow)][ValidateScript({ [Microsoft.DnsClient.Commands.RecordType].IsEnumDefined($_) })]
			# the DNS record type to resolve
			[string]$Type = 'A'
		)

		# get DnsSafeHost from Uri
		Try {
			$DnsSafeHost = $Uri.DnsSafeHost
		}
		Catch {
			Write-Warning "could not retrieve DnsSafeHost from Uri: $($Uri.AbsoluteUri)"
			Return $_
		}

		# define parameters
		$ResolveDnsName = @{
			Name        = $DnsSafeHost
			Type        = $Type
			Server      = '8.8.8.8'
			DnsOnly     = $True
			NoHostsFile = $True
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# resolve DnsSafeHost
		Try {
			$DnsName = Resolve-DnsName @ResolveDnsName
		}
		Catch {
			Write-Warning "could not resolve DnsSafeHost '$DnsSafeHost' from Uri: $($Uri.AbsoluteUri)"
			Return $_
		}

		# filter results and extract IPAddress
		$IPAddress = $DnsName.Where({ $_.Type -eq $Type }).IPAddress

		# check for
		switch ($IPAddress.Count) {
			# if 0 records in IPAddress...
			0 {
				# warn and return null
				Write-Warning "could not resolve any '$Type' records from DNS for DnsSafeHost '$DnsSafeHost' from Uri: $($Uri.AbsoluteUri)"
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
		Write-Host "Resolved IP address '$IPAddress' from URL: $($Uri.AbsoluteUri)"

		# update URI with IP address
		Try {
			$Uri = [Uri]$Uri.AbsoluteUri.Replace($Uri.DnsSafeHost, $IPAddress)
			Write-Host "Constructed host URL from IP: '$($Uri.AbsoluteUri)'"
		}
		Catch {
			Write-Warning "Error constructing host URL from IP: '$($Uri.AbsoluteUri)'"
			Return $_
		}

		# return updated URI
		Return $Uri
	}
}

Process {
	# if path not found...
	If (![System.IO.Directory]::Exists($Path)) {
		# create path
		Try {
			$null = New-Item -Path $Path -Force -ItemType 'Directory' -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not create path: $local:Path"
			Return $_
		}
	}

	# if file not found...
	If (![System.IO.File]::Exists($local:FilePath)) {
		# create script host file
		Try {
			$null = New-Item -Path $local:FilePath -Force -ItemType 'File' -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not create script host file: '$local:FilePath"
			Return $_
		}
	}

	# retrieve proxy configuration
	Try {
		$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
	}
	Catch {
		Write-Warning "could not retrieve Web Application Proxy Application on host: $local:Hostname"
		Return $_
	}

	# retrieve ADFS URL
	If ([string]::IsNullOrEmpty($local:WebApplicationProxyConfiguration.ADFSUrl)) {
		Write-Warning "found empty ADFS URL in Web Application Proxy Application on host: $local:Hostname"
		Return
	}

	# create URI builder from ADFS URL
	Try {
		$UriBuilder = [System.UriBuilder]::new($local:WebApplicationProxyConfiguration.ADFSUrl)
	}
	Catch {
		Write-Warning "could not create UriBuilder from ADFS URL on host: $local:Hostname"
		Return $_
	}

	# update path in URI builder
	Try {
		$UriBuilder.Path = $UriPath
	}
	Catch {
		Write-Warning "could not update Path in UriBuilder on host: $local:Hostname"
		Return $_
	}

	# get Uri from URI builder
	Try {
		$Uri = $UriBuilder.Uri
	}
	Catch {
		Write-Warning -Message "could create Uri from UriBuilder on host: $local:Hostname"
		Return $_
	}

	# get content of hosts file
	Try {
		$Content = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	Catch {
		Write-Warning "could not retrieve hosts file on host: $local:Hostname"
		Return $_
	}

	# process hosts file content
	:NextLine ForEach ($Line in $Content) {
		# if line is commented out...
		If ($Line.StartsWith('#')) {
			# continue to the next line
			Continue NextLine
		}
		# if line ends with the hostname...
		If ($Line -match "\s$($Uri.DnsSafeHost)$") {
			# set URI with IP address required
			$UriWithIPAddressRequired = $true
		}
	}

	# if URI with IP address required...
	If ($local:UriWithIPAddressRequired) {
		# retrieve updated URI with hostname for ADFS service replaced with IP address of ADFS service to address hosts file configuration for non-split-brain DNS
		Try {
			$Uri = Get-UriWithIPAddressFromUriWithHostname -Uri $local:Uri
		}
		Catch {
			Write-Warning 'could not create new Uri with IP address from original Uri'
			Return $_
		}
	}

	# define parameters for Invoke-WebRequest
	$InvokeWebRequest = @{
		Uri                = $Uri
		Headers            = @{ 'host' = $UriBuilder.Host }
		UseBasicParsing    = $true
		MaximumRedirection = 0
		ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve content from URI
	Try {
		$WebRequest = Invoke-WebRequest @InvokeWebRequest
	}
	Catch {
		Write-Warning "could not retrieve response from URL: $($Uri.AbsoluteUri)"
		Return $_
	}

	# if content empty...
	If ([string]::IsNullOrEmpty($WebRequest.Content)) {
		Write-Warning "found empty content at host URL: $($Uri.AbsoluteUri)"
		Return
	}

	# parse response
	Try {
		$ActiveHost = $WebRequest.Content.Trim()
	}
	Catch {
		Write-Warning "could not parse response from host URL: $($Uri.AbsoluteUri)"
		Return $_
	}

	# retrieve current host from file
	Try {
		$CurrentHost = Get-Content -Path $FilePath
	}
	Catch {
		Write-Warning "Error retrieving script host from file: '$FilePath'"
		Return $_
	}

	# check current host and active host
	If ([string]::IsNullOrEmpty($CurrentHost) -or $CurrentHost -ne $ActiveHost) {
		Write-Host "Verified script host file: active script host is '$ActiveHost'"
		Return
	}

	# update host name
	Try {
		Set-Content -Path $FilePath -Value $ActiveHost
	}
	Catch {
		Write-Warning "Error updating script host file: '$FilePath"
		Return $_
	}

	# declare state
	Write-Host "Updated script host file: replaced '$CurrentHost' with new script host: $ActiveHost"
}
