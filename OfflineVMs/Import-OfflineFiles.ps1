#Requires -Modules CmsCredentials

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Import')]
	[switch]$Import,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$VMName,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Source,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Target,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Purge,
	[Parameter()]
	[string]$Json,
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Function Import-OfflineFilesToVM {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Source,
		[string]$Target,
		[boolean]$Purge
	)

	# check for VM on local system
	$vm_check = $null
	$vm_check = Get-VM | Where-Object { $_.Name -eq $VMName }
	If ($vm_check) {
		# retrieve VM credentials
		$Credential = $null
		$Credential = Unprotect-CmsCredentials -Target $VMName
		If ($Credential) {
			# connect to VM
			$vm_direct = $null
			$vm_direct = New-PSSession -VMName $VMName -Credential $Credential
			If ($vm_direct) {
				# verify source
				If (Test-Path -Path $Source) {
					# retrieve files from source
					$file_list = $null
					$file_list = Get-ChildItem -Path $Source
					If ($file_list) {
						# verify target on VM
						$target_check = $null
						$target_check = Invoke-Command -Session $vm_direct -ScriptBlock { If ( Test-Path -Path $using:Target ) { Get-Item -Path $using:Target } Else { New-Item -ItemType Directory -Path $using:Target } }
						If ($target_check) {
							# determine if target should be cleaned before writing files
							If ($Purge) {
								Write-Output "Clearing '$Target' before copy"
								Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:Target -Recurse -Force | Remove-Item -Force }
							}
							# copy files from source to VM
							$file_list.FullName | Copy-Item -ToSession $vm_direct -Destination $Target -Force -Verbose
						}
						Else {
							Write-Output "Could not find or create '$Target' on VM"
						}
					}
					Else {
						Write-Output "Could not retrieve files in '$Source' on host"
					}
				}
				Else {
					Write-Output "Could not find '$Source' on host"
				}
				# disconnect from VM
				$vm_direct | Remove-PSSession
			}
			Else {
				Write-Output "Could not create PowerShell Direct session for VM: '$VMName'"
			}
		}
		Else {
			Write-Output "Could not locate credentials for VM: '$VMName'"
		}
	}
	Else {
		Write-Output "Could not locate VM: '$VMName'"
	}
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
			Write-Warning -Message "Continuing will remove the configuration file '$Json'"
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
				$_.VMName -ne $VMName
			}
			If ($null -eq $json_data) {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
			}
			Else {
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
			}
			$json_data | Select-Object VMName, Source, Target, Purge
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Add {
		# create custom object from parameters then add to object
		$json_data += [pscustomobject]@{
			VMName = $VMName
			Purge  = $Purge.ToBool()
			Source = $Source
			Target = $Target
		}
		$json_data | ConvertTo-Json | Set-Content -Path $Json
		Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
		$json_data | Select-Object VMName, Source, Target, Purge
	}
	$Import {
		Try {
			# define transcript file from script path and start transcript
			Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			ForEach ($json_datum in $json_data) {
				If ([string]::IsNullOrEmpty($json_datum.VMName) -or [string]::IsNullOrEmpty($json_datum.Source) -or [string]::IsNullOrEmpty($json_datum.Target)) {
					Write-Host "ERROR: invalid entry found in configuration file: $Json"
				}
				Else {
					Import-OfflineFilesToVM -VMName $json_datum.VMName -Source $json_datum.Source -Target $json_datum.Target -Purge $json_datum.Purge
				}
			}
		}
		Finally {
			Write-Host ([string]::Empty)
			Stop-Transcript
		}
	}
	Default {
		Write-Output "`nDisplaying '$Json':"
		$json_data | Select-Object VMName, Source, Target, Purge
	}
}
