#Requires -Modules LogToMultiple

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Run')]
	[switch]$Run,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Test')]
	[switch]$Test,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')]
	[int]$Days
)

Function Remove-ItemsFromPathByDays {
	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Path,
		[Parameter(Position = 1, Mandatory = $true)][ValidateScript({ $_ -gt 0 })]
		[int]$Days
	)

	# declare start
	Write-LogToMultiple -LogSubject $Path -Text 'checking for directory...'
	If (Test-Path -Path $Path) {
		Write-LogToMultiple -LogSubject $Path -Text 'directory found, setting date...'
		$date_purge = (Get-Date).AddDays($Days * -1)
	
		# remove old files first
		Write-LogToMultiple -LogSubject $Path -Text "removing files written before: '$date_purge'"
		$old_files = @()
		$old_files += Get-ChildItem -Path $Path -Recurse -Force -Attributes '!Directory' | Where-Object { $_.LastWriteTime -lt $date_purge }
		ForEach ($old_file in $old_files) {
			If ($Run) {
				Write-LogToMultiple -LogSubject $Path -Text "removing file: '$($old_file.FullName)'"
				Remove-Item -Path $old_file.FullName -Force
			}
			Else {
				Write-LogToMultiple -LogSubject $Path -Text "TESTING - would remove file: '$($old_file.FullName)'"
			}
		}
	
		# remove old folders last
		Write-LogToMultiple -LogSubject $Path -Text "removing folders written before: '$date_purge'"
		$old_paths = @()
		$old_paths += Get-ChildItem -Path $Path -Recurse -Force -Attributes 'Directory' | Where-Object { $_.LastWriteTime -lt $date_purge } | Sort-Object -Property FullName -Descending
		ForEach ($old_path in $old_paths) {
			Write-LogToMultiple -LogSubject $Path -Text "checking folder: '$($old_path.FullName)'"
			If ($null -eq (Get-ChildItem -Path $old_path -Recurse -Force)) {
				If ($Run) {
					Write-LogToMultiple -LogSubject $Path -Text 'folder is empty, removing!'
					Remove-Item -Path $old_path.FullName -Force
				}
				Else {
					Write-LogToMultiple -LogSubject $Path -Text 'TESTING - folder is empty, would remove!'
				}
			}
			Else {
				Write-LogToMultiple -LogSubject $Path -Text 'folder not empty, skipping!'
			}
		}
	}
	Else {
		Write-LogToMultiple -LogSubject $Path -Text 'directory not found, skipping!'
	}    
}

# define configuration file from script path then verify path
$json_path = $PSCommandPath.Replace('.ps1', '.json')
$json_test = Test-Path -Path $json_path

# clear required objects then check file
$json_data = @()
If ($json_test) {
	# retrieve JSON file name
	$json_name = (Get-Item -Path $json_path).Name
	# create object from JSON file
	$json_data += Get-Content -Path $json_path | ConvertFrom-Json
} 
Else {
	# define expected JSON file name
	$json_name = Split-Path -Path $json_path -Leaf
}

# evaluate parameters
switch ($true) {
	$Clear { 
		Write-Output "`nClearing '$json_name'`n"
		If ($json_test) { Remove-Item -Path $json_path -Force }
	}
	$Remove { 
		# remove matching entries from object
		$json_data = $json_data | Where-Object { $_.Path -ne $Path }
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "`nUpdated '$json_name' to remove '$Path':"
		$json_data | Select-Object Path, Path, Updated
	}
	$Add { 
		# create custom object from parameters then add to object
		$json_data += [pscustomobject]@{ 
			Days    = $Days
			Path    = $Path 
			Updated = (Get-Date -Format FileDateTimeUniversal) 
		}
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "`nUpdated '$json_name' to add '$Path'"
		$json_data | Select-Object Days, Path, Updated
	}
	{ $Run -or $Test } {
		Try {
			# define transcript file from script path and start transcript
			Start-Transcript -Path $PSCommandPath.Replace('.ps1', '.txt') -Force

			# start logging
			Start-LogToMultiple -ScriptPath $PSCommandPath

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $json_name"
				Exit
			}
			
			# process configuration file
			ForEach ($json_datum in $json_data) { 
				If ([string]::IsNullOrEmpty($json_datum.Path) -and -not [string]::IsNullOrEmpty($json_datum.Days)) {
					Remove-ItemsFromPathByDays -Path $json_datum.Path -Days $json_datum.Days
				}
			}
		}
		Finally {
			Write-Host ([string]::Empty)
			Stop-Transcript
		}
	}
	Default {
		Write-Output "`nDisplaying '$json_name'`n"
		$json_data | Select-Object Days, Path, Updated
	}
}
