[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# CertEnroll path on CA
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
	$CertEnroll = 'C:\Windows\system32\CertSrv\CertEnroll',
	# destination path
	[Parameter(Position = 1)]
	$Destination = 'C:\Content\pki\certsrv',
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.' -replace '\.$')
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
			# remove old transcript files
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

	# verify destination
	If ((Test-Path -Path $Destination) -eq $false) { 
		Try {
			$null = New-Item -Type Directory -Path $Destination -ErrorAction Stop
		}
		Catch {
			Write-Error -Message 'creating destination directory'
			Throw $_
		}
	}
}

Process {
	# copy CRL file
	$ca_crl = Get-ChildItem -Path $CertEnroll | Where-Object { $_.Extension -eq '.crl' }
	$ca_crl | Copy-Item -Destination $Destination -Verbose
 
	# get CRT file object and byte encoding
	$ca_file = Get-ChildItem -Path $CertEnroll | Where-Object { $_.Extension -eq '.crt' } | Sort-Object LastWriteTime | Select-Object -Last 1
	$ca_byte = Get-Content -Path $ca_file.FullName -Encoding Byte

	# get CRT file without hostname
	$ca_name = $ca_file.BaseName -replace "$HostName.$DomainName`_"

	# copy CRT file
	$ca_path = Join-Path -Path $Destination -ChildPath ($ca_name + '.crt')
	$ca_file | Copy-Item -Destination $ca_path -Verbose
 
	# define the required strings for base64 files
	$ca_base64 = [System.Convert]::ToBase64String($ca_byte, [System.Base64FormattingOptions]::InsertLineBreaks)
	$ca_header = '-----BEGIN CERTIFICATE-----'
	$ca_footer = '-----END CERTIFICATE-----'

	# define the environment specific line break strings
	$ca_break_win = "`r`n"
	$ca_break_pem = "`n"
 
	# insert the environment specific line break after the 64th character on each line
	$ca_base64_win = $ca_base64 -replace '.{64}', "`$&$ca_break_win"
	$ca_base64_pem = $ca_base64 -replace '.{64}', "`$&$ca_break_pem"
 
	# define the file names for each certificate type
	$ca_file_win = Join-Path -Path $Destination -ChildPath ($ca_name + '.cer')
	$ca_file_pem = Join-Path -Path $Destination -ChildPath ($ca_name + '.pem')
 
	# set the header and footer around each base64-encoded certificate then export the content to the associated file
	($ca_header, $ca_base64_win, $ca_footer) -join $ca_break_win | Out-File -FilePath $ca_file_win -Encoding ASCII -Force -NoNewline -Verbose
	($ca_header, $ca_base64_pem, $ca_footer) -join $ca_break_pem | Out-File -FilePath $ca_file_pem -Encoding ASCII -Force -NoNewline -Verbose
 
	# append an environment specific line break to the end of the file
	Add-Content -Path $ca_file_win -Value $ca_break_win -NoNewline
	Add-Content -Path $ca_file_pem -Value $ca_break_pem -NoNewline
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
