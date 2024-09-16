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
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$Path,
	# switch to skip transcript logging
	[Parameter(Mandatory = $false)]
	[switch]$SkipSiteSpecificFiles,
	# string containing algorithm for Get-FileHash
	[Parameter(DontShow)][ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MACTripleDES', 'MD5', 'RIPEMD160')]
	[string]$Algorithm = 'SHA512',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
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
	# get info of path parameter
	Try {
		$PathInfo = [System.IO.FileInfo]::new($Path)
	}
	Catch {
		Write-Warning -Message "could not get info for file at Path: $Path"
		Return $_
	}

	# get base path from path info
	$BasePath = $PathInfo.DirectoryName

	# get main files from base folder
	Try {
		$MainFiles = Get-ChildItem -Path $BasePath -Filter 'main*.txt'
	}
	Catch {
		Write-Warning -Message "could not retrieve main files from Path: $SitePath"
		Return $_
	}

	# if main files not found...
	If (!$MainFiles) {
		Write-Warning -Message "could not retrieve required main files from '$BasePath' base path"
		Return $_
	}

	# get client files from base folder
	Try {
		$ClientFiles = Get-ChildItem -Path $BasePath -Filter 'client*.txt'
	}
	Catch {
		Write-Warning -Message "could not retrieve client files from '$BasePath' base path"
		Return $_
	}

	# if client files not found...
	If (!$ClientFiles) {
		Write-Warning -Message "could not retrieve required client files from '$BasePath' base path"
		Return $_
	}

	# get server files from base folder
	Try {
		$ServerFiles = Get-ChildItem -Path $BasePath -Filter '*server*.txt'
	}
	Catch {
		Write-Warning -Message "could not retrieve server files from '$BasePath' base path"
		Return $_
	}

	# if server files not found...
	If (!$ServerFiles) {
		Write-Warning -Message "could not retrieve required server files from '$BasePath' base path"
		Return $_
	}

	# create empty content string for base content
	$BaseContent = [string]::Empty

	# get content from base main files
	ForEach ($File in $MainFiles) {
		# add content from base main files to base content
		$FileContent = Get-Content -Path $File.FullName -Raw
		$BaseContent = $BaseContent, $FileContent -join "`r`n"
	}

	# get content from base client files
	ForEach ($File in $ClientFiles) {
		# add content from base client files to base content
		$FileContent = Get-Content -Path $File.FullName -Raw
		$BaseContent = $BaseContent, $FileContent -join "`r`n"
	}

	# get content from base server files
	ForEach ($File in $ServerFiles) {
		# add content from base server files to base content
		$FileContent = Get-Content -Path $File.FullName -Raw
		$BaseContent = $BaseContent, $FileContent -join "`r`n"
	}

	# trim start of text content
	$BaseContent = $BaseContent.TrimStart("`r`n")

	# define path to base configuration file
	$BaseFilePath = Join-Path -Path $BasePath -ChildPath $PathInfo.Name

	# if base configuration file does not exist...
	If (![System.IO.File]::Exists($BaseFilePath)) {
		# create base configuration file
		$null = New-Item -ItemType 'File' -Path $BaseFilePath
	}

	# get content of existing base configuration file
	Try {
		$BaseFileContent = Get-Content -Path $BaseFilePath -Raw
	}
	Catch {
		Write-Warning -Message "could not retrieve content from base configuration file: $BaseFilePath"
		Return $_
	}

	# if base text does matches base configuration file content...
	If ($BaseContent -eq $BaseFileContent) {
		Write-Verbose -Verbose -Message "found current configuration in base configuration file: $BaseFilePath"
	}
	# if base text does not match base configuration file content...
	Else {
		# update default file with default text
		Try {
			Set-Content -Path $BaseFilePath -Value $BaseContent -NoNewLine
		}
		Catch {
			Write-Warning -Message "could not update base configuration file: $BaseFilePath"
			Return $_
		}
		# declare updated
		Write-Verbose -Verbose -Message "updated configuration in base configuration file: $BaseFilePath"
	}

	### start site-specific configuration

	# define site-specific folder path
	$SitePath = Join-Path -Path $BasePath -ChildPath $SiteName

	# test for site-specific folder path
	$SiteFound = Test-Path -Path $SitePath -PathType 'Container'

	# if site-specific folder path found...
	If ($SiteFound) {
		# get site-specific main files
		Try {
			$SiteMainFiles = Get-ChildItem -Path $SitePath -Filter 'main*.txt'
		}
		Catch {
			Write-Warning -Message "could not retrieve site-specific main files from site-specific Path: $SitePath"
			Return $_
		}

		# get site-specific client files
		Try {
			$SiteClientFiles = Get-ChildItem -Path $SitePath -Filter 'client*.txt'
		}
		Catch {
			Write-Warning -Message "could not retrieve site-specific client files from site-specific Path: $SitePath"
			Return $_
		}

		# get site-specific server files
		Try {
			$SiteServerFiles = Get-ChildItem -Path $SitePath -Filter '*server*.txt'
		}
		Catch {
			Write-Warning -Message "could not retrieve site-specific server files from site-specific Path: $SitePath"
			Return $_
		}

		# define site-specific configuration file
		$SiteFilePath = Join-Path -Path $SitePath -ChildPath $PathInfo.Name

		# create empty content string for site-specific content
		$SiteContent = [string]::Empty

		# if site-specific main files found...
		If ($SiteMainFiles) {
			# add content from site-specific main files to site content
			ForEach ($File in $SiteMainFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}
		Else {
			# add content from base main files to site content
			ForEach ($File in $MainFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}

		# if site-specific client files found...
		If ($SiteClientFiles) {
			# add content from site-specific client files to site content
			ForEach ($File in $SiteClientFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}
		Else {
			# add content from base client files to site content
			ForEach ($File in $ClientFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}

		# if site-specific server files found...
		If ($SiteServerFiles) {
			# add content from site-specific server files to site content
			ForEach ($File in $SiteServerFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}
		Else {
			# add content from base server files to site content
			ForEach ($File in $ServerFiles) {
				$FileContent = Get-Content -Path $File.FullName -Raw
				$SiteContent = $SiteContent, $FileContent -join "`r`n"
			}
		}

		# create empty content string for base content
		$BaseContent = [string]::Empty

		# get content from base main files
		ForEach ($File in $MainFiles) {
			# add content from base main files to base content
			$FileContent = Get-Content -Path $File.FullName -Raw
			$BaseContent = $BaseContent, $FileContent -join "`r`n"
		}

		# get content from base client files
		ForEach ($File in $ClientFiles) {
			# add content from base client files to base content
			$FileContent = Get-Content -Path $File.FullName -Raw
			$BaseContent = $BaseContent, $FileContent -join "`r`n"
		}

		# get content from base server files
		ForEach ($File in $ServerFiles) {
			# add content from base server files to base content
			$FileContent = Get-Content -Path $File.FullName -Raw
			$BaseContent = $BaseContent, $FileContent -join "`r`n"
		}

		# trim start of text content
		$SiteContent = $SiteContent.TrimStart("`r`n")

		# define path to site-specific file
		$SiteFilePath = Join-Path -Path $SitePath -ChildPath 'authproxy.cfg'

		# if site-specific file does not exist...
		If (![System.IO.File]::Exists($SiteFilePath)) {
			# create site-specific file
			$null = New-Item -ItemType 'File' -Path $SiteFilePath
		}

		# get content of existing site-specific file
		Try {
			$SiteFileContent = Get-Content -Path $SiteFilePath -Raw
		}
		Catch {
			Write-Warning -Message "could not retrieve content from site-specific file: $SiteFilePath"
			Return $_
		}

		# if site-specific text matches site-specific file content...
		If ($SiteContent -eq $SiteFileContent) {
			Write-Verbose -Verbose -Message "found current configuration in site-specific file: $SiteFilePath"
		}
		# if site-specific text does not match site-specific file content...
		Else {
			# update site-specific file with site-specific text
			Try {
				Set-Content -Path $SiteFilePath -Value $SiteContent -NoNewline
			}
			Catch {
				Write-Warning -Message "could not update site-specific file: $SiteFilePath"
				Return $_
			}
			# declare updated
			Write-Verbose -Verbose -Message "updated configuration in site-specific file: $SiteFilePath"
		}
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
