[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Copy')]
	[switch]$Copy,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Source,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Target,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Purge,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Recurse,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$CheckHash,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$SkipFiles,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$SkipCreateTarget,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$CopyToCluster,
	[Parameter()]
	[string]$Json
)

Function Copy-FilesFromSourceToTarget {
	[CmdletBinding()]
	param (
		[string]$Source,
		[string]$Target,
		[switch]$Purge,
		[switch]$Recurse,
		[switch]$CheckHash,
		[switch]$SkipFiles,
		[switch]$SkipCreateTarget
	)

	# trim inputs
	$Source = $Source.TrimEnd('\')
	$Target = $Target.TrimEnd('\')

	# verify source and target
	If (-not (Test-Path -Path $Source -PathType 'Container')) {
		Write-Output "Could not find source folder '$Source' on host"; Return
	}
	ElseIf (-not (Test-Path -Path $Target -PathType 'Container') -and $SkipCreateTarget) {
		Write-Output "Could not find target folder '$Target' on host"; Return
	}
	ElseIf (-not (Test-Path -Path $Target -PathType 'Container') -and -not $SkipCreateTarget) {
		Try {
			$null = New-Item -ItemType 'Directory' -Path $Target
		}
		Catch {
			Write-Output "Could not create target folder '$Target' on host"; Return
		}
	}
	Else {
		Write-Output "Verified '$Source' and '$Target' on host"
	}

	# remove all files and folders from target if Purge is set
	If ($Purge) {
		Write-Output "Clearing '$Target' before copy"
		Try {
			Get-ChildItem -Path $Target -Recurse -Force | Remove-Item -Force
		}
		Catch {
			"ERROR: Could not purge folder '$Target'"
			Return
		}
	}

	# process folder structure if Recurse is true
	If ($Recurse) {
		# retrieve folders from source
		$source_folders = Get-ChildItem -Path $Source -Recurse:$Recurse -Directory | Select-Object -ExpandProperty 'FullName'
		$target_folders = Get-ChildItem -Path $Target -Recurse:$Recurse -Directory | Select-Object -ExpandProperty 'FullName'

		# trim folders to relative paths
		If ($source_folders.Count) { $source_folders_relative = $source_folders.Replace($Source, $null) } Else { $source_folders_relative = @() }
		If ($target_folders.Count) { $target_folders_relative = $target_folders.Replace($Target, $null) } Else { $target_folders_relative = @() }

		# retrieve folders that are missing
		$folders_missing += [array][System.Linq.Enumerable]::Except([string[]]$source_folders_relative, [string[]]$target_folders_relative)

		# retrieve folders that are invalid
		$folders_invalid += [array][System.Linq.Enumerable]::Except([string[]]$target_folders_relative, [string[]]$source_folders_relative)

		# create any missing folders
		ForEach ($folder in $folders_missing) {
			$target_folder = Join-Path -Path $Target -ChildPath $folder
			Try {
				$null = New-Item -Path $target_folder -ItemType 'Directory' -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not create folder '$target_folder'"
				Return
			}
		}
	}

	# process files if SkipFiles is false
	If (-not $SkipFiles) {
		# retrieve files from source
		$source_files = Get-ChildItem -Path $Source -Recurse:$Recurse -File | Select-Object -ExpandProperty 'FullName'
		$target_files = Get-ChildItem -Path $Target -Recurse:$Recurse -File | Select-Object -ExpandProperty 'FullName'

		# trim files to relative paths
		If ($source_files.Count) { $source_files_relative = $source_files.Replace($Source, $null) } Else { $source_files_relative = @() }
		If ($target_files.Count) { $target_files_relative = $target_files.Replace($Target, $null) } Else { $target_files_relative = @() }

		# retrieve files that are missing
		$files_missing += [array][System.Linq.Enumerable]::Except([string[]]$source_files_relative, [string[]]$target_files_relative)

		# retrieve files that are invalid
		$files_invalid += [array][System.Linq.Enumerable]::Except([string[]]$target_files_relative, [string[]]$source_files_relative)

		# copy any missing files
		ForEach ($file in $files_missing) {
			$source_file = Join-Path -Path $Source -ChildPath $file
			$target_file = Join-Path -Path $Target -ChildPath $file
			Try {
				Copy-Item -Path $source_file -Destination $target_file -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not copy file '$source_file' to file '$target_file'"
			}
		}

		# remove any invalid files
		ForEach ($file in $files_invalid) {
			$target_file = Join-Path -Path $Target -ChildPath $file
			Try {
				$null = Remove-Item -Path $target_file -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not remove file '$target_file'"
			}
		}

		# retrieve files that are present
		$files_present += [array][System.Linq.Enumerable]::Intersect([string[]]$source_files_relative, [string[]]$target_files_relative)

		# copy any present files when hash or lastwritetime are different
		ForEach ($file in $files_present) {
			$source_file = Join-Path -Path $Source -ChildPath $file
			$target_file = Join-Path -Path $Target -ChildPath $file
			# compare target file with source file
			If ($CheckHash) {
				If ((Get-FileHash -Path $source_file).Hash -eq (Get-FileHash -Path $target_file).Hash) {
					Write-Output "Skipping '$source_file' as '$target_file' has same file hash"
					Continue
				}
			}
			Else {
				If ((Get-Item -Path $source_file).LastWriteTime -eq (Get-Item -Path $target_file).LastWriteTime) {
					Write-Output "Skipping '$source_file' as '$target_file' has same LastWriteTime"
					Continue
				}
			}
			# copy the file
			Try {
				Copy-Item -Path $source_file -Destination $target_file -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not copy file '$source_file' to file '$target_file'"
			}
		}
	}
}

# define JSON file
If ($null -eq $Json) {
	$PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
}

# verify JSON file
If (-not (Test-Path -Path $Json)) {
	If ($Add) {
		Try {
			$null = New-Item -ItemType 'File' -Path $Json
		}
		Catch {
			Write-Output "`nERROR: could not create configuration file:"
			Write-Output "$Json`n"
			Return
		}
	}
	Else {
		Write-Output "`nERROR: could not find configuration file:"
		Write-Output "$Json`n"
		Return
	}
}

# import JSON data
$json_data = @()
$json_data += Get-Content -Path $Json | ConvertFrom-Json

# evaluate parameters
switch ($true) {
	$Clear {
		# remove configuration file
		If (Test-Path -Path $Json) {
			Try {
				Remove-Item -Path $Json -Force
				Write-Output "`nCleared configuration file: '$Json'"
			}
			Catch {
				Write-Output "`nERROR: could not clear configuration file: '$Json'"
			}
		}
	}
	$Remove {
		# remove matching entries from object
		Try {
			$json_data = $json_data | Where-Object {
				$_.Source -ne $Source
			}
			If ($null -eq $json_data) {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nRemoved '$Source' from configuration file: '$Json'"
			}
			Else {
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nRemoved '$Source' from configuration file: '$Json'"
			}
			$json_data | Format-Table
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Add {
		# create custom object from parameters then add to object
		Try {
			$json_data += [pscustomobject]@{
				Source           = $Source
				Target           = $Target
				Purge            = $Purge.ToBool()
				Recurse          = $Recurse.ToBool()
				CheckHash        = $CheckHash.ToBool()
				SkipFiles        = $SkipFiles.ToBool()
				SkipCreateTarget = $SkipCreateTarget.ToBool()
				CopyToCluster    = $CopyToCluster.ToBool()
			}
			$json_data | ConvertTo-Json | Set-Content -Path $Json
			Write-Output "`nAdded '$Source' to configuration file: '$Json'"
			$json_data | Format-Table
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Copy {
		Try {
			# define transcript file from script path and start transcript
			Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt') -Force

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Output "`nERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			:json_datum ForEach ($json_datum in $json_data) {
				If ([string]::IsNullOrEmpty($json_datum.Source) -or [string]::IsNullOrEmpty($json_datum.Target)) {
					Write-Output "`nERROR: invalid entry found in configuration file: $Json"
				}
				Else {
					Copy-FilesFromSourceToTarget -Source $json_datum.Source -Target $json_datum.Target -Purge:$json_datum.Purge -Recurse:$json_datum.Recurse -CheckHash:$json_datum.CheckHash -SkipFiles:$json_datum.SkipFiles -SkipCreateTarget:$json_datum.SkipCreateTarget
					If ($json_datum.CopyToCluster) {
						Try {
							$cluster_nodes = (Get-ClusterNode).Name | Where-Object { $_ -ne [System.Environment]::MachineName }
						}
						Catch {
							Write-Output "`nERROR: could not retrieve cluster nodes from local host"
							Continue :json_datum
						}
						ForEach ($cluster_node in $cluster_nodes) {
							Invoke-Command -ComputerName $cluster_node -ScriptBlock ${function:Copy-FilesFromSourceToTarget} -ArgumentList $json_datum.Source, $json_datum.Target, $json_datum.Purge, $json_datum.Recurse, $json_datum.CheckHash, $json_datum.SkipFiles, $json_datum.SkipCreateTarget
						}
					}
				}
			}
		}
		Finally {
			Write-Output ([string]::Empty)
			Stop-Transcript
		}
	}
	Default {
		Write-Output "`nDisplaying configuration file: '$Json'"
		$json_data | Format-Table
	}
}
