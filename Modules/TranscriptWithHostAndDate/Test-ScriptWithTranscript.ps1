#Requires -module TranscriptWithHostAndDate
<#
.SYNOPSIS
Template for writing PowerShell transcripts for a script.

.DESCRIPTION
Template for writing PowerShell transcripts for a script. The End block will remove any transcript files that match the generated transcript file name less the date and are older than the computed transcript cleanup date.

.PARAMETER Parameter1
Example parameter for script

.PARAMETER SkipTranscript
Switch parameter to skip writing transcript and transcript cleanup.

.PARAMETER TranscriptName
The string to substitute for the random component of the default PowerShell transcript file name.

.PARAMETER TranscriptPath
The path to a folder for saving PowerShell transcript files.

.PARAMETER TranscriptDateUnits
The units for computing the transcript cleanup date. Must be one of: Hours, Days, Months, Years

.PARAMETER TranscriptDateValue
The value for computing the transcript cleanup date. Must be an unsigned integer and at least 1

.PARAMETER TranscriptFileCount
The number of transcript files that must remain after cleanup. Transcript cleanup will not run if the count of transcript files that would remain is not at least the value of this parameter.

.PARAMETER HostName
The host name for the current computer.

.PARAMETER DomainName
The domain name for the current computer.

.PARAMETER DnsHostName
The fully qualified DNS host name for the current computer.

.INPUTS
None.

.OUTPUTS
None.
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# parameter for script
	[Parameter(Position = 0)]
	[string]$Parameter1,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
	# units for transcript cleanup date
	[Parameter(DontShow)][ValidateSet('Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$TranscriptDateUnits,
	# value for transcript cleanup date
	[Parameter(DontShow)][ValidateScript({ $_ -ge 1 })]
	[uint16]$TranscriptDateValue,
	# count of files to remain after transcript cleanup
	[Parameter(DontShow)]
	[uint16]$TranscriptFileCount,
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
	If ($SkipTranscript -ne $true) {
		# define hashtable for transcript parameters
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript function
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
	# example try/catch block
	Try {
		# insert commands here
		$PSCallStack = Get-PSCallStack
		# if information preference is ignore...
		If ($InformationPreference -eq 'Ignore') {
			# example write to information output stream written to transcript only via Write-Information
			Write-Information -Message 'retrieved PSCallStack'
		}
		Else {
			# example write to information output stream written to transcript and console via Write-Host
			Write-Host -Object 'retrieved PSCallStack'
		}
		# example write to verbose output stream written to transcript and displayed on the console
		If ($VerbosePreference -eq 'Continue') {
			Write-Verbose -Message $PSCallStack.ToString()
		}
	}
	Catch {
		# write to transcript example for warning
		Write-Warning -Message $_.ToString()
		# use return to hand errors to the calling function or console
		Return $_
		# avoid using Throw in the Process section; calling Throw will terminate the script, skip the End block, and skip transcript cleanup
	}
}

End {
	# if skip transcript not requested...
	If ($SkipTranscript -ne $true) {
		# update parameters for transcript function
		If ($PSBoundParameters.ContainsKey('TranscriptDateUnits')) { $TranscriptWithHostAndDate['TranscriptDateUnits'] = $PSBoundParameters['TranscriptDateUnits'] }
		If ($PSBoundParameters.ContainsKey('TranscriptDateValue')) { $TranscriptWithHostAndDate['TranscriptDateValue'] = $PSBoundParameters['TranscriptDateValue'] }
		If ($PSBoundParameters.ContainsKey('TranscriptFileCount')) { $TranscriptWithHostAndDate['TranscriptFileCount'] = $PSBoundParameters['TranscriptFileCount'] }
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
