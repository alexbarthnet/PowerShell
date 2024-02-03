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
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	# child path to host folder
	[Parameter(Dontshow)]
	[string]$ChildPath = 'host',
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
		Return $_
	}

	# test FQDN from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Fqdn)) {
		Write-Output 'required value not found in JSON file: Fqdn'
		Return
	}

	# test Path from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Path)) {
		Write-Output 'required value not found in JSON file: Path'
		Return
	}

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

	# define URI to ADFS hostname
	Try {
		$Uri = [uri]"https://$($JsonData.Fqdn)/host/"
		Write-Output "Constructed URL IP address from URL: '$($Uri.AbsoluteUri)'"
	}
	Catch {
		Write-Output "Error creating URL from FQDN: '$($JsonData.Fqdn)'"
		Return $_
	}

	# get content of hosts file
	Try {
		$Hosts = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	Catch {
		Write-Output 'Error retrieving hosts file'
		Return $_
	}

	# if hosts contains an entry for FQDN...
	If ($Hosts -match "^[^#].*$($JsonData.Fqdn)$") {
		# resolve host in URI to IP Address to workaround potential hosts file resolution of ADFS servers
		Try {
			$IPAddress = Resolve-DnsName -Name $($JsonData.Fqdn) -DnsOnly -NoHostsFile | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress
			Write-Output "Resolved IP address from URL: '$($Uri.AbsoluteUri)'"
		}
		Catch {
			Write-Output "Error resolving IP address from URL: '$($Uri.AbsoluteUri)'"
			Return $_
		}

		# update URI with IP address
		Try {
			$Uri = [Uri]$Uri.AbsoluteUri.Replace($Uri.DnsSafeHost, $IPAddress)
			Write-Output "Constructed host URL from IP: '$($Uri.AbsoluteUri)'"
		}
		Catch {
			Write-Output "Error constructing host URL from IP: '$($Uri.AbsoluteUri)'"
			Return $_
		}
	}

	# retrieve content from URI
	Try {
		$WebRequest = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers @{'host' = $Fqdn } -MaximumRedirection 0
		Write-Output "Retrieved response from host URL: '$($Uri.AbsoluteUri)'"
	}
	Catch {
		Write-Output "Error retrieving response from host URL: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# parse response
	Try {
		$ActiveHost = $WebRequest.Content.Trim().ToLowerInvariant()
		Write-Output "Parsed response from host URL: '$($Uri.AbsoluteUri)'"
	}
	Catch {
		Write-Output "Error parsing response from host URL: '$($Uri.AbsoluteUri)'"
		Return $_
	}

	# create empty string for current host
	$CurrentHost = [string]::Empty

	# test file
	If (Test-Path -Path $FilePath) {
		# retrieve current host from file
		Try {
			$CurrentHost = Get-Content -Path $FilePath
			Write-Output "Retrieved script host from file: '$FilePath'"
		}
		Catch {
			Write-Output "Error retrieving script host from file: '$FilePath'"
			Return $_
		}
	}
	Else {
		# create script host file and variable
		Try {
			$null = New-Item -ItemType 'File' -Path $FilePath
			Write-Output "Created script host file: '$FilePath'"
		}
		Catch {
			Write-Output "Error creating script host file: '$FilePath"
			Return $_
		}
	}

	# check current host and active host
	If ($CurrentHost -eq $ActiveHost) {
		Write-Output "'$ActiveHost' is active host and script host; no change required"
		Return 
	}

	# update host name
	Try {
		Set-Content -Path $FilePath -Value $ActiveHost
		Write-Output "'$ActiveHost' is new script host; replaced old script host: '$CurrentHost' "
	}
	Catch {
		Write-Output "Error updating script host file: '$FilePath"
		Return $_
	}
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
