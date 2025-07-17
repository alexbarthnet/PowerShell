<#
.SYNOPSIS
Test if the content of the most recently updated file in a path matches the local hostname.

.DESCRIPTION
Test if the content of the most recently updated file in a path matches the local hostname.

.PARAMETER Path
The path with one or more files to evaluate.

.PARAMETER Hostname
The hostname expected in the files. The default value is the hostname of the local system.

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-PathForHostname.ps1 -Path 'C:\Content\path'

.NOTES
The path may be a folder or a file. The file with the last write time is selected when the path is a folder.
#>

Param(
	# path to evaluate
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Path,
	# local host name
	[Parameter(Position = 1)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 2)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 3)]
	[string]$VariableName = 'TestPathForHostName',
	# scope of variable when AsVariable is true
	[Parameter(Position = 4)]
	[string]$VariableScope = 'global'
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
		$Value = $true
	}
	Else {
		$Value = $false
	}

	# if AsVariable requested...
	If ($AsVariable) {
		New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
	}
	Else {
		return $Value
	}
}
