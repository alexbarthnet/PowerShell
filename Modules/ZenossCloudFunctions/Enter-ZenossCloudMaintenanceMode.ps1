#requires -Modules ZenossCloudFunctions,CmsCredentials
[CmdletBinding()]
param (
	# string for CmsCredential identity
	[Parameter(Position = 0)]
	[string]$Identity = 'Zenoss',
	# path for transcript files
	[Parameter(Position = 1)]
	[string]$TranscriptName,
	# path for transcript files
	[Parameter(Position = 2)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
	[string]$TranscriptPath,
	# switch to skip transcript logging
	[Parameter(Position = 3)]
	[switch]$SkipTranscript,
	# local hostname
	[Parameter(DontShow)]
	[string]$Hostname = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$Dnshostname = ($Hostname, [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant() -join '.').TrimEnd('.')
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

		# verify transcript name
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName')
		}

		# verify transcript path
		If (!$PSBoundParameters.ContainsKey('TranscriptPath') -or !(Test-Path -Path $TranscriptPath -PathType Container)) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData')
		}

		# build transcript basename from transcript name and hostname
		$TranscriptBase = "PowerShell_transcript.$TranscriptHost.$TranscriptName"

		# build transcript file name with transcript basename and current datetime
		$TranscriptFile = "$TranscriptBase.$TranscriptTime.txt"

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
			# path for transcript file
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

		# verify transcript name
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName')
		}

		# verify transcript path
		If (!$PSBoundParameters.ContainsKey('TranscriptPath') -or !(Test-Path -Path $TranscriptPath -PathType Container)) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData')
		}

		# build transcript basename from transcript name and hostname
		$TranscriptBase = "PowerShell_transcript.$TranscriptHost.$TranscriptName"

		# declare transcript cleanup
		Write-Verbose -Message "Removing any transcripts named '$TranscriptBase' from '$TranscriptPath' that are older than '$TranscriptDays' days" -Verbose

		# get transcript files
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath | Where-Object { $_.BaseName.StartsWith($TranscriptBase, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt $TranscriptDate }

		# get transcript files newer than cleanup date
		$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt $TranscriptDate }

		# if count of transcript files count is less than cleanup threshold...
		If ($TranscriptCount -lt $NewFiles.Count ) {
			# declare and continue
			Write-Verbose -Message "Skipping transcript removal; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
		}
		# if count of transcript files is not less than cleanup threshold...
		Else {
			# get log files older than cleanup date
			$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt $TranscriptDate } | Sort-Object -Property FullName
			# remove old logs
			ForEach ($OldFile in $OldFiles) {
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
	If (!$SkipTranscript) {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $TranscriptName }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $TranscriptPath }
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
	# get credential object
	Try {
		$Credential = Unprotect-CmsCredentials -Identity $Identity
	}
	Catch {
		Throw $_
	}

	# define parameters for Set-ZenossCloudProductionStatec
	$SetZenossCloudProductionState = @{
		Credential  = $Credential
		Device      = $Dnshostname
		State       = 'Maintenance'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# call zenoss function
	Try {
		Set-ZenossCloudProductionState @SetZenossCloudProductionState
	}
	Catch {
		Throw $_
	}
}

End {
	# if running...
	If (!$SkipTranscript) {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}