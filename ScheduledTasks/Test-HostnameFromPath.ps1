<#
.SYNOPSIS
Test if the content at a path is the local hostname.

.DESCRIPTION
Test if the content at a path is the local hostname.

.PARAMETER Path
The path with one or more files to evaluate.

.PARAMETER Hostname
The local hostname expected in the files. The default value is the hostname of the local system.

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-HostnameFoundAtPath.ps1 -Path 'C:\Content\path\item'

.NOTES
The path may be a folder or a file. The file with the last write time is selected when the path is a folder.
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

Process {
	# if path is a folder...
	If (Test-Path -Path $Path -PathType 'Container') {
		# retrieve content from latest file in path
		Try {
			$PathContent = Get-ChildItem -Path $Path -ErrorAction 'Stop' | Sort-Object -Property 'LastWriteTimeUtc' | Select-Object -Last 1 | Get-Content -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve content from latest file in path: '$Path'"
			Return $_
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
