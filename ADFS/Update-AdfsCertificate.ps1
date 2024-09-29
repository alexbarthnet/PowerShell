#Requires -Module ADFS

<#
.SYNOPSIS
Updates the configured ADFS SSL certificate.

.DESCRIPTION
Updates the configured ADFS SSL certificate. The secondary servers write a file to a shared location when an update is required. The primary server checks the shared location for the files and updates secondary servers. A separate process must install the certificate on each server in the farm.

.PARAMETER Json
The path to a JSON file containing the configuration for the ADFS service. The following values are required:
 - FQDN - the FQDN of the ADFS service
 - Hash - the thumbprint hash of the ADFS SSL certificate
 - Path - the parent path for the files

.PARAMETER ChildPath
The child path for the certificate update files. The full path is formed by joining the path from the JSON file and the value of this parameter.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsCertificate.ps1 -Json C:\Content\adfs\config.json -ChildPath 'certificates'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$Json,
	# child path to certificates folder
	[Parameter(DontShow)]
	[string]$ChildPath = 'certificates',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
	# local hostname
	[Parameter(DontShow)]
	[string]$Hostname = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	Function Update-AdfsCertificatePrimaryServer {
		Param(
			[string]$Fqdn,
			[string]$Hash,
			[string]$Path,
			[string]$Filter
		)

		# get current certificate hash
		Try {
			$CertificateHash = Get-AdfsSslCertificate | Where-Object { $_.HostName -eq $Fqdn -and $_.PortNumber -eq '443' } | Select-Object -ExpandProperty 'CertificateHash'
		}
		Catch {
			Write-Host "`nERROR: retrieving current ADFS SSL certificate thumbprint`n"
			Return
		}

		# get active certificate
		Try {
			$ActiveSslCertificate = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $CertificateHash }
		}
		Catch {
			Write-Host "`nERROR: current ADFS SSL certificate not found in certificate store`n"
			Return
		}

		# get latest certificate that is at least a day old 
		Try {
			$LatestSslCertificate = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $ActiveSslCertificate.Subject -and $_.NotBefore -lt [datetime]::Now.AddDays(-1) } | Sort-Object NotBefore | Select-Object -Last 1
		}
		Catch {
			Write-Host "`nERROR: retrieving latest ADFS SSL certificate by subject`n"
			Return
		}

		# check certificate
		If ($null -eq $LatestSslCertificate) {
			Write-Host "`nERROR: latest ADFS SSL certificate not found in certificate store`n"
			Return
		}

		# check thumbprints
		If ($ActiveSslCertificate.Thumbprint -ne $LatestSslCertificate.Thumbprint) {
			Write-Host 'active and latest ADFS SSL certificate do not match; updating ADFS certificate'
			# update certicate
			Try {
				Set-AdfsSslCertificate -Thumbprint $LatestSslCertificate.Thumbprint
				$Updated = $true
			}
			Catch {
				Write-Host "`nERROR: updating ADFS SSL certificate by thumbprint`n"
				Return
			}
		}
		Else {
			Write-Host 'ADFS SSL certificate is current: latest SSL certificate and active SSL certificate match'
		}

		# retrieve ADFS service communications certificate
		Try {
			$ActiveServiceCertificate = Get-AdfsCertificate -CertificateType 'Service-Communications' | Select-Object -ExpandProperty 'Certificate'
		}
		Catch {
			Write-Host "`nERROR: retrieving current ADFS service communications certificate`n"
			Return
		}

		# retrieve latest certificate
		Try {
			$LatestServiceCertificate = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $ActiveServiceCertificate.Subject -and $_.NotBefore -lt [datetime]::Now.AddDays(-1) } | Sort-Object NotBefore | Select-Object -Last 1
		}
		Catch {
			Write-Host "`nERROR: retrieving latest ADFS service communications certificate by subject`n"
			Return
		}

		# check certificate
		If ($null -eq $LatestServiceCertificate) {
			Write-Host "`nERROR: latest ADFS service communications certificate not found in certificate store`n"
			Return
		}

		# check thumbprints
		If ($ActiveServiceCertificate.Thumbprint -ne $LatestServiceCertificate.Thumbprint) {
			Write-Host 'active and latest ADFS service communications certificate do not match; updating ADFS service communications certificate'
			# update certicate
			Try {
				Set-AdfsCertificate -CertificateType 'Service-Communications' -Thumbprint $LatestServiceCertificate.Thumbprint
				$Updated = $true
			}
			Catch {
				Write-Host "`nERROR: updating ADFS service communications certificate by thumbprint`n"
				Return
			}
		}
		Else {
			Write-Host 'ADFS service communications certificate is current: latest service communications certificate and active service communications certificate match'
		}

		# check hash in JSON data 
		If ($JsonData.Hash -ne $LatestServiceCertificate.Thumbprint) {
			# update JSON data
			$JsonData.Hash = $LatestServiceCertificate.Thumbprint

			# update JSON file
			Try {
				$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
			}
			Catch {
				Write-Host "`nERROR: updating ADFS JSON file`n"
				Return
			}

			# declare update
			Write-Host "Updated JSON hash with thumbprint: $($LatestServiceCertificate.Thumbprint)"
		}

		# if certificates were updated on the primary...
		If ($Updated) {
			# restart service on primary node
			Try {
				$null = Restart-Service 'adfssrv'
			}
			Catch {
				Write-Host "`nERROR: restarting ADFS service on: '$Hostname'`n"
				Return
			}

			# pause for 30 seconds for service restart
			Write-Host "pausing 30 seconds for service restart on '$fqdn'"
			Start-Sleep -Seconds 30

			# retrieve FQDNs of secondary computers
			Try {
				$secondaries = (Get-AdfsFarmInformation).FarmNodes | Where-Object { $_.NodeType -eq 'SecondaryComputer' }
			}
			Catch {
				Write-Host "`nERROR: retrieving ADFS secondary computers`n"
				Return
			}

			# pause for 60 seconds for replication
			Write-Host 'pausing 1 minute for replication to ADFS secondary computers'
			Start-Sleep -Seconds 60

			# restart service on secondary computers
			ForEach ($fqdn in $secondaries.FQDN) {

				# restart service on secondary computer
				Try {
					Invoke-Command -ComputerName $fqdn -ScriptBlock { $null = Restart-Service -Name 'adfssrv' }
				}
				Catch {
					Write-Host "`nERROR: restarting ADFS service on: '$fqdn'`n"
					Return
				}

				# pause for 30 seconds for service restart
				Write-Host "pausing 30 seconds for service restart on '$fqdn'"
				Start-Sleep -Seconds 30
			}
		}
		Else {
			# get secondary computers in farm
			Try {
				$SecondaryComputers = @((Get-AdfsFarmInformation).FarmNodes | Where-Object { $_.NodeType -eq 'SecondaryComputer' } | Select-Object -ExpandProperty 'FQDN')
			}
			Catch {
				Write-Host "`nERROR: retrieving ADFS secondary servers`n"
				Return
			}

			# get hostname files
			$Files = Get-ChildItem -Path $Path -Filter $Filter

			# if no files found...
			If ($Files.Count -eq 0) {
				Write-Host 'No certificate update files found for secondary servers'
			}

			# process each hostname file
			:Files ForEach ($File in $Files) {
				# get servername from basename of file 
				$Servername = $File.Basename.Replace('adfs_update_', $null)

				# get FQDN for servername
				$Member = $SecondaryComputers | Where-Object { $_ -like "$ServerName*" }

				# test member
				If ($null -eq $Member) {
					Write-Host "`nWARNING: certificate update file found for server that did not match farm nodes: '$ServerName'`n"
					Continue Files
				}

				# update SSL certificate on secondary computer
				Try {
					Set-AdfsSslCertificate -Thumbprint $Hash -Member $Member
				}
				Catch {
					Write-Host "`nERROR: updating ADFS SSL certificate by thumbprint on: '$Member'`n"
					Continue Files
				}

				# remove certificate update file
				Try {
					$File | Remove-Item -Confirm:$false
				}
				Catch {
					Write-Host "`nERROR: removing certificate update file for: '$ServerName'`n"
					Continue Files
				}
			}
		}
	}

	Function Update-AdfsCertificateSecondaryServer {
		Param(
			[string]$Fqdn,
			[string]$Hash,
			[string]$Path,
			[string]$ChildPath
		)

		# get adfs certificate on secondary
		Try {
			$CertificateHash = Get-AdfsSslCertificate | Where-Object { $_.HostName -eq $Fqdn -and $_.PortNumber -eq '443' } | Select-Object -ExpandProperty 'CertificateHash'
		}
		Catch {
			Write-Host 'ERROR: retrieving ADFS SSL certificate'
			Return
		}

		# if hashes match...
		If ($Hash -eq $CertificateHash) {
			Write-Host 'ADFS SSL certificate hash matches JSON hash'
			$Current = $true
		}
		Else {
			Write-Host 'ADFS SSL certificate hash does not match JSON hash'
			$Current = $false
		}

		# define hostname file path
		$FilePath = Join-Path -Path $Path -ChildPath $ChildPath

		# check hostname file path
		$TestPath = Test-Path -Path $FilePath -PathType Leaf

		# if current and hostname file exists...
		If ($Current -and $TestPath) {
			# remove hostname file
			Try {
				Remove-Item -Path $FilePath -Confirm:$false
				Write-Host 'removed certificate update file'
			}
			Catch {
				Write-Host 'ERROR: removing certificate update file'
				Return
			}
		}

		# if not current and hostname file missing...
		If (-not $Current -and -not $TestPath) {
			# create hostname file
			Try {
				New-Item -Path $Path -Name $ChildPath -ItemType File
				Write-Host 'created certificate update file'
			}
			Catch {
				Write-Host 'ERROR: creating certificate update file'
				Return
			}
		}

		# if not current...
		If (-not $Current) {
			# update hostname file
			Try {
				Set-Content -Path $FilePath -Value (Get-Date -Format FileDateTimeUniversal)
				Write-Host 'refreshed certificate update file'
			}
			Catch {
				Write-Host 'ERROR: writing certificate update file'
				Return
			}
		}
	}
}

Process {
	# retrieve JSON data
	Try {
		$JsonData = Get-Content -Path $Json | ConvertFrom-Json
	}
	Catch {
		Write-Host 'ERROR: retrieving JSON file'
		Return
	}

	# test FQDN from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Fqdn)) {
		Write-Host 'FQDN was not found in JSON file'
		Return
	}

	# test hash from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Hash)) {
		Write-Host 'Hash was not found in JSON file'
		Return
	}

	# test path from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Path)) {
		Write-Host 'Path was not found in JSON file'
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
		Write-Host "`nERROR: retrieving ADFS sync properties`n"
		Return $_
	}

	# check ADFS role
	switch ($Role) {
		'PrimaryComputer' {
			Write-Host 'primary ADFS server: checking certificate...'
			Try {
				Update-AdfsCertificatePrimaryServer -Fqdn $JsonData.Fqdn -Hash $JsonData.Hash -Path $Path -Filter 'adfs_update_*'
			}
			Catch {
				Return $_
			}
		}
		'SecondaryComputer' {
			Write-Host 'secondary ADFS server: checking certificate...'
			Try {
				Update-AdfsCertificateSecondaryServer -Fqdn $JsonData.Fqdn -Hash $JsonData.Hash -Path $Path -ChildPath "adfs_update_$Hostname.txt"
			}
			Catch {
				Return $_
			}
		}
		Default {
			Write-Host "unknown ADFS server role: $Role"
		}
	}
}
