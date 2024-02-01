#Requires -Module ADFS

<#
.SYNOPSIS
Publishes ADFS modified metadata and public signing certificate to a folder.

.DESCRIPTION
Publishes ADFS modified metadata and public signing certificate to a folder. Metadata has been modified to better support SAML single logout in specific circumstances.

.PARAMETER Json
The path to a JSON file containing the configuration for the ADFS service. The following values are required:
 - FQDN - the FQDN of the ADFS service
 - Path - the parent path for the files

.PARAMETER ChildPath
The child path for the metadata files and certificate. The full path is formed by joining the path from the JSON file and the value of this parameter.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Publish-AdfsMetadata.ps1 -Json C:\Content\adfs\config.json -ChildPath 'metadata'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	# child path to metadata folder
	[Parameter(DontShow)]
	[string]$ChildPath = 'metadata',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
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
	Function Start-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path for transcript file
			[Parameter()]
			[string]$TranscriptPath,
			# log start time
			[Parameter(DontShow)]
			[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
		}

		# verify transcript path
		If (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
			# define parameters for New-Item
			$NewItem = @{
				Path        = $TranscriptPath
				ItemType    = 'Directory'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create transcript path
			Try {
				$null = New-Item @NewItem
			}
			Catch {
				Throw $_
			}
		}

		# build transcript file name with defined prefix, hostname, transcript name and current datetime
		$TranscriptFile = "PowerShell_transcript.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

		# define parameters for Start-Transcript
		$StartTranscript = @{
			Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start transcript
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path of transcript files
			[Parameter()]
			[string]$TranscriptPath,
			# minimum number of transcript files for removal
			[Parameter(DontShow)]
			[uint16]$TranscriptCount = 7,
			# minimum age of transcript files for removal
			[Parameter(DontShow)]
			[double]$TranscriptDays = 7,
			# datetime for transcript files for removal
			[Parameter(DontShow)]
			[datetime]$TranscriptDate = ([datetime]::Now.AddDays(-$TranscriptDays)),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
			# LEGACY: re-define default transcript path as string array containing current path and original path in common application data folder
			[string[]]$TranscriptPath = @([System.Environment]::GetFolderPath('CommonApplicationData'), $TranscriptPath)
		}

		# define filter using default transcript prefix, hostname, and script name
		$TranscriptFilter = "PowerShell_transcript.$TranscriptHost.$TranscriptName*"

		# get transcript files matching filter
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'SilentlyContinue'

		# split transcript files on transcript date
		$NewFiles, $OldFiles = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
		
		# if count of files after transcript date is less than to cleanup threshold...
		If ($NewFiles.Count -lt $TranscriptCount) {
			# declare skip
			Write-Verbose -Message "Skipping transcript file cleanup; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
		}
		Else {
			# declare cleanup
			Write-Verbose -Message "Removing any transcript files matching '$TranscriptFilter' that are older than '$TranscriptDays' days from: $TranscriptPath" -Verbose
			# remove old logs
			ForEach ($OldFile in ($OldFiles | Sort-Object -Property FullName)) {
				Try {
					Remove-Item -Path $OldFile.FullName -Force -Verbose -ErrorAction Stop
				}
				Catch {
					$_
				}
			}
		}

		# stop transcript
		Try {
			$null = Stop-Transcript
		}
		Catch {
			Throw $_
		}
	}

	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $PSBoundParameters['TranscriptName'] }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $PSBoundParameters['TranscriptPath'] }
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# retrieve JSON data
	Try {
		$JsonData = Get-Content -Path $Json | ConvertFrom-Json
	}
	Catch {
		Write-Output 'ERROR: retrieving ADFS JSON file'
		Return
	}

	# test FQDN from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Fqdn)) {
		Write-Output 'FQDN was not found in ADFS JSON file'
		Return
	}

	# test path from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Path)) {
		Write-Output 'Path was not found in ADFS JSON file'
		Return
	}

	# define path
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

	# get ADFS role
	Try {
		$Role = Get-AdfsSyncProperties | Select-Object -ExpandProperty 'Role'
	}
	Catch {
		Write-Output 'ERROR: retrieving ADFS sync properties'
		Return $_
	}

	# check ADFS role
	switch ($Role) {
		'PrimaryComputer' {
			Write-Output 'primary ADFS server: updating metadata...'
		}
		'SecondaryComputer' {
			Write-Output 'secondary ADFS server: skipping metadata update'
			Return
		}
		Default {
			Write-Output "unknown ADFS server role: $Role"
			Return
		}
	}

	# build dependent paths
	$FilePath = Join-Path -Path $Path -ChildPath 'token-signing.crt'

	# retrieve token signing certificate
	Try {
		$AdfsCertificate = Get-AdfsCertificate -CertificateType 'Token-Signing' | Select-Object -ExpandProperty 'Certificate' | Sort-Object -Property NotBefore | Select-Object -Last 1
	}
	Catch {
		Return $_
	}
	
	# export token signing certificate
	Try {
		$null = $AdfsCertificate | Export-Certificate -Force -FilePath $FilePath
	}
	Catch {
		Return $_
	}

	# get ADFS endpoints
	Try {
		$ADFSEndpoint = Get-ADFSEndpoint -ErrorAction Stop
	}
	Catch {
		Return $_
	}

	# get URL for metadata
	$UriForMetadata = ($ADFSEndpoint | Where-Object Protocol -EQ 'Federation Metadata').FullUrl.ToString()

	# get URL for rest method against local server
	$UriForRestMethod = $UriForMetadata.Replace($JsonData.Fqdn, $DnsHostName)

	# get local URL for metadata
	Try {
		$Xml = Invoke-RestMethod -Uri $UriForRestMethod
	}
	Catch {
		Return $_
	}

	# build paths for post method files
	$PostPath = Join-Path -Path $Path -ChildPath 'saml-single-logout-post.xml'
	$PostPathLegacy = Join-Path -Path $Path -ChildPath 'custom-logout-post.xml'

	# get URL for SAML
	$UriForEndpoint = ($ADFSEndpoint | Where-Object Protocol -EQ 'SAML 2.0/WS-Federation').FullUrl.ToString()

	# modify metadata for Single Logout Service then save modified metadata
	$XmlForPost = $Xml
	$XmlForPost.GetElementsByTagName('IDPSSODescriptor').GetElementsByTagName('SingleLogoutService') | Where-Object { $_.Binding -match 'Post' } | ForEach-Object { $_.Location = ($UriForEndpoint + 'logout.aspx') }
	$XmlForPost.Save($PostPath)
	$XmlForPost.Save($PostPathLegacy)

	# build paths for post method files
	$RedirectPath = Join-Path -Path $Path -ChildPath 'saml-single-logout-redirect.xml'
	$RedirectPathLegacy = Join-Path -Path $Path -ChildPath 'custom-logout-redirect.xml'

	# modify metadata for Single Logout Service then save modified metadata
	$XmlForRedirect = $Xml
	$XmlForRedirect.GetElementsByTagName('IDPSSODescriptor').GetElementsByTagName('SingleLogoutService') | Where-Object { $_.Binding -match 'Redirect' } | ForEach-Object { $_.Location = ($UriForEndpoint + '?wa=wsignout1.0') }
	$XmlForRedirect.Save($RedirectPath)
	$XmlForRedirect.Save($RedirectPathLegacy)
}

End {
	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
