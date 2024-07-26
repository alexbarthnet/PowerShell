#requires -Modules TranscriptWithHostAndDate

<#
.SYNOPSIS
Updates a 'script host' file with the name of the server actively servicing requests to ADFS.

.DESCRIPTION
Updates a 'script host' file with the name of the server actively servicing requests to ADFS. This file is leveraged by other scripts to determine an effective 'FSMO' equivalent on ADFS servers without reliance upon the static primary/secondary server configuration.

.PARAMETER Json
The path to a JSON file containing the configuration for the ADFS service. The following values are required:
 - FQDN - the FQDN of the ADFS service
 - Path - the parent path for the files

.PARAMETER ChildPath
The child path for the 'script host' file. The full path is formed by joining the path from the JSON file and the value of this parameter.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsScriptHost.ps1 -Json C:\Content\adfs\config.json -ChildPath 'host'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType [Microsoft.PowerShell.Commands.TestPathType]::Leaf })]
	[string]$Json,
	# child path to host folder
	[Parameter(Dontshow)]
	[string]$ChildPath = 'host',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
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
		Write-Host "Resolved IP address '$IPAddress' from URL: '$($Uri.AbsoluteUri)'"

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

	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# retrieve JSON data
	Try {
		$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
	}
	Catch {
		Write-Host 'ERROR: retrieving ADFS JSON file'
		Return $_
	}

	# if Uri not in JSON data...
	If ([string]::IsNullOrEmpty($JsonData.Uri)) {
		Write-Warning -Message 'could not find Uri property in JSON file'
		Return
	}

	# if Path not in JSON data...
	If ([string]::IsNullOrEmpty($JsonData.Path)) {
		Write-Warning -Message 'could not find Path property in JSON file'
		Return
	}

	# cast Uri property to Uri object
	Try {
		$Uri = [uri]$JsonData.Uri
	}
	Catch {
		Write-Warning -Message 'could not cast Uri property in JSON file to Uri object'
		Return $_
	}

	# record hostname from original Uri
	$UriHostName = $Uri.DnsSafeHost

	# build primary path
	$Path = Join-Path -Path $JsonData.Path -ChildPath $ChildPath

	# verify path
	If (-not (Test-Path -Path $Path)) {
		Try {
			$null = New-Item -ItemType 'Directory' -Path $Path -ErrorAction Stop
		}
		Catch {
			Return $_
		}
	}

	# define path of specific host file
	$FilePath = Join-Path -Path $Path -ChildPath "$HostName.txt"

	# get content of hosts file
	Try {
		$HostsFileContent = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	Catch {
		Write-Warning 'Error retrieving hosts file'
		Return $_
	}

	# if hosts contains an entry with hostname from Uri...
	If ($HostsFileContent -match "^[^#].*$($Uri.DnsSafeHost)$") {
		# report matching hosts entry found
		Write-Verbose -Message 'hosts file contains entry with hostname from the provided URI; resolving hostname to IP via DNS to build alternate URI'
		# record hostname from original Uri
		$UriHostName = $Uri.DnsSafeHost
		# resolve host in URI to IP Address to workaround potential hosts file resolution of ADFS servers
		Try {
			$Uri = Get-UriWithIPAddressFromUriWithHostname -Uri $Uri
		}
		Catch {
			Write-Warning 'could not create new Uri with IPaddress from original Uri'
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
		Write-Host "Retrieved response from host URL: '$($Uri.AbsoluteUri)'"
	}
	Catch {
		Write-Warning "Error retrieving response from host URL: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# parse response
	Try {
		$ActiveHost = $WebRequest.Content.Trim().ToLowerInvariant()
		Write-Host "Parsed response from host URL: '$($Uri.AbsoluteUri)'"
	}
	Catch {
		Write-Warning "Error parsing response from host URL: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# create empty string for current host
	$CurrentHost = [string]::Empty

	# test file
	If (Test-Path -Path $FilePath) {
		# retrieve current host from file
		Try {
			$CurrentHost = Get-Content -Path $FilePath
			Write-Host "Retrieved script host from file: '$FilePath'"
		}
		Catch {
			Write-Warning "Error retrieving script host from file: '$FilePath'"
			Return $_
		}
	}
	Else {
		# create script host file and variable
		Try {
			$null = New-Item -ItemType 'File' -Path $FilePath
			Write-Host "Created script host file: '$FilePath'"
		}
		Catch {
			Write-Warning "Error creating script host file: '$FilePath"
			Return $_
		}
	}

	# check current host and active host
	If ($CurrentHost -eq $ActiveHost) {
		Write-Host "'$ActiveHost' is active host and script host; no change required"
		Return
	}

	# update host name
	Try {
		Set-Content -Path $FilePath -Value $ActiveHost
		Write-Host "'$ActiveHost' is new script host; replaced old script host: '$CurrentHost' "
	}
	Catch {
		Write-Warning "Error updating script host file: '$FilePath"
		Return $_
	}
}

End {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
