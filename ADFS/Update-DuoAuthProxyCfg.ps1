<#
.SYNOPSIS
Updates the local Duo Authentication Proxy configuration file from a shared location.

.DESCRIPTION
Updates the local Duo Authentication Proxy configuration file from a shared location and restarts the service when the existing configuration file does not match the provided configuration file

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
	# path to shared Duo Authentication Proxy configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$Path,
	# path to local Duo Authentication Proxy configuration file
	[Parameter(Dontshow)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$Destination = (Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'Duo Security Authentication Proxy\conf\authproxy.cfg'),
	# string containing algorithm for Get-FileHash
	[Parameter(DontShow)][ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MACTripleDES', 'MD5', 'RIPEMD160')]
	[string]$Algorithm = 'SHA512',
	# local site name
	[Parameter(DontShow)]
	[string]$SiteName = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name,
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

Process {
	# get info of path parameter
	Try {
		$PathInfo = [System.IO.FileInfo]::new($Path)
	}
	Catch {
		Write-Warning -Message "could not get info for file at Path: $Path"
		Return $_
	}

	# define site-specific folder path
	$SitePath = Join-Path -Path $PathInfo.DirectoryName -ChildPath $SiteName

	# if site folder exists...
	If (Test-Path -Path $SitePath -PathType 'Container') {
		# define site-specific folder path
		$SiteFile = Join-Path -Path $SitePath -ChildPath $PathInfo.Name

		# if site-specific file exists...
		If (Test-Path -Path $SiteFile -PathType 'Leaf') {
			$Path = $SiteFile
		}
	}

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
		Write-Verbose -Verbose -Message "Skipping update of Duo Auth Proxy: found matching hashes for '$Path' Path and '$Destination' Destination"
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
