#requires -Modules TranscriptWithHostAndDate

<#
.SYNOPSIS
Updates the Duo Authentication Proxy configuration file.

.DESCRIPTION
Updates the Duo Authentication Proxy configuration file and restarts the service when the existing configuration file does not match the provided configuration file

.PARAMETER Path
The path to the shared Duo Authentication Proxy configuration file.

.PARAMETER Destination
The path to the local Duo Authentication Proxy configuration file. The default value is 'Duo Security Authentication Proxy\conf\authproxy.cfg' in the Program Files directory.

.PARAMETER Algorithm
The algorithm for comparing hashes of the shared and local Duo Authentication Proxy configuration files. The default value is 'SHA512' and the permitted values are the values permitted for the Algorithm parameter of the Get-FileHash function.

.INPUTS
System.String. The path to the shared Duo Authentication Proxy configuration file.

.OUTPUTS
None. The script does not provide any actionable output.

.EXAMPLE
.\Update-DuoAuthProxyCfg.ps1 -Path C:\Content\adfs\authproxy.cfg
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType ([Microsoft.PowerShell.Commands.TestPathType]::Leaf) })]
	[string]$Path,
	# child path to host folder
	[Parameter(Dontshow)][ValidateScript({ Test-Path -Path $_ -PathType ([Microsoft.PowerShell.Commands.TestPathType]::Leaf) })]
	[string]$Destination = (Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'Duo Security Authentication Proxy\conf\authproxy.cfg'),
	# string containing algorithm for Get-FileHash
	[Parameter(DontShow)][ValidateSet("SHA1", "SHA256", "SHA384", "SHA512", "MACTripleDES", "MD5", "RIPEMD160")]
	[string]$Algorithm = 'SHA512',
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
	# get file hash of path
	Try {
		$PathHash = Get-FileHash -Path $Path -Algorithm $Algorithm -Verbose
	}
	Catch {
		Write-Warning -Message "could not get hash of file at Path: $Path"
		Return $_
	}

	# get file hash of destination
	Try {
		$DestinationHash = Get-FileHash -Path $Destination -Algorithm $Algorithm -Verbose
	}
	Catch {
		Write-Warning -Message "could not get hash of file at Destination: $Destination"
		Return $_
	}

	# if hashes match...
	If ($PathHash.Hash -eq $DestinationHash.Hash) {
		Write-Verbose -Verbose -Message 'Found matching hashes for Path and Destination, skipping update of Duo Auth Proxy'
		Return
	}

	# copy path to destination
	Try {
		Copy-Item -Path $Path -Destination $Destination -Force -Verbose
	}
	Catch {
		Write-Warning -Message "could not copy '$Path' path file to '$Destination' destination file"
		Return $_
	}

	# restart service
	Try {
		Restart-Service -Name 'DuoAuthProxy' -Force -Verbose
	}
	Catch {
		Write-Warning -Message 'could not restart DuoAuthProxy service'
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
