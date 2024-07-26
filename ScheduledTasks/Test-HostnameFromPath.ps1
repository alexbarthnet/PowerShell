<#
.SYNOPSIS
Test if the content at a URI is the local hostname.

.DESCRIPTION
Test if the content at a URI is the local hostname.

.PARAMETER Path
The path with one or more files to evaluate.

.PARAMETER Hostname
The local hostname expected in the files. The default value is the hostname of the local system.

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-HostnameAtUri.ps1 -Uri 'https://www.example.com/host/'

.NOTES
The URI must have a trailing backslash if the URI points to a folder rather than a file.
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path for reference text
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Default')][ValidateScript({ Test-Path -Path $_})]
	[string]$Path,
	# local host name
	[Parameter(DontShow)]
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
	# if path is a folder...
	If (Test-Path -Path $Path -PathType 'Container') {
		# retrieve content from latest file in path
		Try {
			$PathContent = Get-ChildItem -Path $Path -ErrorAction 'Stop' | Sort-Object -Property 'LastWriteTimeUtc' | Select-Object -Last 1 | Get-Content -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve content from latest file in path: '$Path'"
			Return
		}
	}

	# if path is a file...
	If (Test-Path -Path $Path -PathType 'Leaf') {
		# retrieve content from latest file in path
		Try {
			$PathContent = Get-Content -Path $Path -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve content from file with path: '$Path'"
			Return $_
		}
	}

	# if path content matches hostname...
	If ($PathContent -eq $HostName) {
		Return $true
	}
	Else {
		Return $false
	}
}
