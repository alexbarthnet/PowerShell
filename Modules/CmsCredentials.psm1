Function Get-ComputersFromParams {
	<#
	.SYNOPSIS
	Creates a list of computers from inputs.

	.DESCRIPTION
	Creates a list of computers from inputs. Called by multiple functions in this module.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies one or more remote clusters.

	.PARAMETER Cluster
	Instructs the command to check if the local machine is a cluster and, if so, to execute on all members of the cluster.

	.INPUTS
	None.

	.OUTPUTS
	An array of computer hostnames.

	#>

	[CmdletBinding()]
	param (
		[Parameter(Position = 0)][AllowEmptyCollection()]
		[string[]]$ComputerName,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$ClusterName,
		[Parameter(Position = 2)]
		[switch]$Cluster
	)

	# define empty array
	$ComputersFromParams = @()

	# retrieve local cluster name if requested
	If ($Cluster) {
		$ClusSvc = $null
		$ClusSvc = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
		If ($null -ne $ClusSvc) {
			Try { $ClusterName += (Get-Cluster).Name }
			Catch { Write-Host 'ERROR: could not retrieve local cluster name' }
		}
		Else {
			Write-Host 'ERROR: cluster service is not running on local host'
		}
	}

	# add computers to array from ClusterName argument
	If ($ClusterName.Count) {
		ForEach ($cluster_name in $ClusterName) {
			Try {
				$cluster_nodes = $null
				$cluster_nodes = Invoke-Command -ComputerName $cluster_name -ScriptBlock { (Get-ClusterNode).Name }
				$cluster_nodes | ForEach-Object { $ComputersFromParams += $_ }
			}
			Catch {
				Write-Host "ERROR: could not retrieve list of cluster nodes from '$cluster_name'"
			}
		}
	}

	# add computers to array from ComputerName argument
	If ($ComputerName) {
		$ComputerName | ForEach-Object { $ComputersFromParams += $_ }
	}

	# remove duplicate computers
	$ComputersFromParams | Select-Object -Unique
}

Function New-CmsCredentialCertificate {
	<#
	.SYNOPSIS
	Internal function for creating a self-signed certificate.

	.DESCRIPTION
	Internal function for creating a self-signed certificate. This function is called by Protect-CmsCredentialSecret.

	.PARAMETER Identity
	Specifies the identity for the CMS credential.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.INPUTS
	None.

	.OUTPUTS
	System.Security.Cryptography.X509Certificates.X509Certificate2

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# define datetimes
	$cms_date = [datetime]::Now
	$cms_date_100years = $cms_date.AddYears(100)
	$cms_date_tostring = $cms_date.ToUniversalTime().ToString('yyyyMMddTHHmmssffffZ')

	# define certificate subject
	$cms_subject = "CN=$($Hostname.ToLowerInvariant(), $Identity.ToLowerInvariant(), $cms_date_tostring -join '-')"

	# define certificate values
	$SelfSignedCertificate = @{
		Subject         = $cms_subject
		Type            = 'DocumentEncryptionCert'
		KeyExportPolicy = 'NonExportable'
		HashAlgorithm   = 'SHA512'
		KeyLength       = 4096
		NotBefore       = $cms_date
		NotAfter        = $cms_date_100years
	}

	# create self-signed certificate
	New-SelfSignedCertificate @SelfSignedCertificate
}

Function Protect-CmsCredentialSecret {
	<#
	.SYNOPSIS
	Internal function for protecting a credential with CMS.

	.DESCRIPTION
	Internal function for protecting a credential with CMS. This function is called by Protect-CmsCredentials.

	.PARAMETER Identity
	Specifies the identity for the CMS credential.

	.PARAMETER Cred
	Specifies the PSCredential object to protect with CMS.

	.PARAMETER Template
	Specifies the certificate template for the CMS certificate.

	.PARAMETER Reset
	Specifies that a new CMS certificate is required.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.PARAMETER ParentPath
	Specifies the parent path of the CMS credential folder. Set to the ProgramData folder by default.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Position = 0)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[pscredential]$Cred,
		[Parameter(Position = 2)]
		[string]$Template,
		[Parameter(Position = 3)]
		[bool]$Reset,
		[Parameter(Position = 4)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 5)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
		[Parameter(Position = 6)][ValidateScript({ Test-Path -Path $_ })]
		[string]$ParentPath = [System.Environment]::GetFolderPath('CommonApplicationData'),
		[Parameter(Position = 7)]
		[bool]$Cleanup = $true
	)

	# define required objects
	$cms_cert = $null
	$cms_make = $true
	$cms_path = Join-Path -Path $ParentPath -ChildPath ($Prefix, $Hostname -join '_').ToLowerInvariant()

	# verify cms folder
	Write-Host "Checking CMS directory: $cms_path"
	If (!(Test-Path -Path $cms_path)) { New-Item -ItemType Directory -Path $cms_path | Out-Null }

	# check a matching certificate already exists
	If (-not $Reset) {
		# define required strings
		$cms_date_regex = '[0-9TZ]+'
		$cms_cert_regex = ("CN=$Hostname", $Identity, $cms_date_regex) -join '-'

		# retrieve any certificates matching regex
		$cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_cert_regex } | Sort-Object NotBefore | Select-Object -Last 1

		# check certificates
		If ($cms_cert) {
			# skip creating certificate
			$cms_make = $false

			# declare certificate found
			Write-Host "CMS certificate found, subject: '$($cms_cert.Subject)'"
		}
	}

	# create the certificate
	If ($cms_make) {
		Try {
			$cms_cert = New-CmsCredentialCertificate -Identity $Identity -Hostname $Hostname
		}
		Catch {
			Return $_
		}
		# declare certificate created
		Write-Host "CMS certificate created, subject: '$($cms_cert.Subject)'"
	}

	# if a CMS cert exists...
	If ($cms_cert) {
		# define required strings
		$cms_name = $cms_cert.Subject.Replace('CN=', $null)
		$cms_file = Join-Path -Path $cms_path -ChildPath "$cms_name.txt"

		# create custom object for export
		$cms_cred = $null
		$cms_cred = [pscustomobject]@{
			Username = $Cred.Username
			Password = $Cred.GetNetworkCredential().Password
		}

		# encrypt credentials to local certificate
		Try {
			$cms_cred | ConvertTo-Json | Protect-CmsMessage -To $cms_cert.Thumbprint -OutFile $cms_file
			$cms_made = $true
			Write-Host "CMS file created: '$($cms_file)'"
		}
		Catch {
			Write-Error 'could not encrypt the CMS file'
			Return $_
		}

		# if CMS was made, clean up files and certificates
		If ($cms_made -and $Cleanup) {
			Write-Host 'Removing old CMS certificates and credenials...'
			$RemoveCmsCredentialSecret = @{
				Identity   = $Identity
				Prefix     = $Prefix
				Hostname   = $Hostname
				ParentPath = $ParentPath
				SkipLast   = 1
			}
			Try {
				Remove-CmsCredentialSecret @RemoveCmsCredentialSecret
			}
			Catch {
				Write-Error 'could not remove old CMS certificates and files'
			}
		}
	}
}

Function Remove-CmsCredentialSecret {
	<#
	.SYNOPSIS
	Internal function for removing a CMS credential.

	.DESCRIPTION
	Internal function for removing a CMS credential. This function is called by Remove-CmsCredentials.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.PARAMETER ParentPath
	Specifies the parent path of the CMS credential folder. Set to the ProgramData folder by default.

	.PARAMETER SkipLast
	Specifies the number of objects to skip when removing CMS credential certificates and files. Set to 0 by default.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Position = 0)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
		[Parameter(Position = 3)][ValidateScript({ Test-Path -Path $_ })]
		[string]$ParentPath = [System.Environment]::GetFolderPath('CommonApplicationData'),
		[Parameter(Position = 4)]
		[uint16]$SkipLast = 0
	)

	# define strings
	$cms_path = Join-Path -Path $ParentPath -ChildPath ($Prefix, $Hostname -join '_').ToLowerInvariant()
	$cms_date_regex = '[0-9TZ]+'
	If ([string]::IsNullOrEmpty($Identity)) {
		$cms_cert_regex = ("CN=$Hostname", '\w+', $cms_date_regex) -join '-'
		$cms_file_regex = ($Prefix, $Hostname, '\w+', $cms_date_regex) -join '_'
	}
	Else {
		$cms_cert_regex = ("CN=$Hostname", $Identity, $cms_date_regex) -join '-'
		$cms_file_regex = ($Prefix, $Hostname, $Identity, $cms_date_regex) -join '_'
	}

	# remove certificates
	$cms_cert_old = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_cert_regex } | Sort-Object -Property 'NotBefore' | Select-Object -SkipLast $SkipLast
	$cms_cert_old | ForEach-Object {
		Write-Host "Removing CMS certificate: '$($_.Subject)'"
		$_ | Remove-Item -Force
	}

	# test credential files path
	If (-not (Test-Path -Path $cms_path -PathType Container)) {
		Write-Host "CMS credential folder not found: '$cms_path'"
		Return
	}

	# remove credential files
	$cms_file_old = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $cms_file_regex } | Sort-Object -Property 'BaseName' | Select-Object -SkipLast $SkipLast
	$cms_file_old | ForEach-Object {
		Write-Host "Removing CMS credential: '$($_.FullName)'"
		$_ | Remove-Item -Force
	}
}

Function Show-CmsCredentialSecret {
	<#
	.SYNOPSIS
	Internal function for retrieving a CMS credential.

	.DESCRIPTION
	Internal function for retrieving a CMS credential. This function is called by Show-CmsCredentials.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.PARAMETER ParentPath
	Specifies the parent path of the CMS credential folder. Set to the ProgramData folder by default.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Position = 0)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
		[Parameter(Position = 3)][ValidateScript({ Test-Path -Path $_ })]
		[string]$ParentPath = [System.Environment]::GetFolderPath('CommonApplicationData')
	)

	# define strings
	$cms_path = Join-Path -Path $ParentPath -ChildPath ($Prefix, $Hostname -join '_').ToLowerInvariant()
	$cms_date_regex = '[0-9TZ]+'
	If ([string]::IsNullOrEmpty($Identity)) {
		$cms_cert_regex = ("CN=$Hostname", '\w+', $cms_date_regex) -join '-'
		$cms_file_regex = ($Prefix, $Hostname, '\w+', $cms_date_regex) -join '_'
	}
	Else {
		$cms_cert_regex = ("CN=$Hostname", $Identity, $cms_date_regex) -join '-'
		$cms_file_regex = ($Prefix, $Hostname, $Identity, $cms_date_regex) -join '_'
	}

	# display certificates
	$cms_cert_current = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_cert_regex }
	$cms_cert_current | ForEach-Object {
		Write-Host "Found CMS certificate: '$($_.Subject)'"
	}

	# test credential files path
	If (-not (Test-Path -Path $cms_path -PathType Container)) {
		Write-Host "CMS credential folder not found: '$cms_path'"
		Return
	}

	# display credential files
	$cms_file_current = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $cms_file_regex }
	$cms_file_current | ForEach-Object {
		Write-Host "Found CMS credential: '$($_.FullName)'"
	}
}

Function Update-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Internal function for updating access to a CMS credential.

	.DESCRIPTION
	Internal function for updating access to a CMS credential. Utilized by Grant-CmsCredentialAccess, Revoke-CmsCredentialAccess, and Reset-CmsCredentialAccess.

	.PARAMETER Mode
	Specifies the mode for the function.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Principals
	Specifies one or more Active Directory principals.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0)]
		[string]$Mode,
		[Parameter(Position = 1)]
		[string]$Identity,
		[Parameter(Position = 2)]
		[string[]]$Principals,
		[Parameter(Position = 3)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# create regex to match expected CMS certificate name of machinename followed by the Identity name then either a simple date or a FileDateTimeUniversal
	$cms_regx = "CN=$Hostname-$Identity-\d{8}"

	# retrieve SIDs for principals
	$cms_sids = @()
	If ($Mode -eq 'Reset') {
		$cms_sids += [System.Security.Principal.SecurityIdentifier]('S-1-5-18') # add NT AUTHORITY\SYSTEM
		$cms_sids += [System.Security.Principal.SecurityIdentifier]('S-1-5-32-544') # add BUILTIN\Administrators
	}
	Else {
		ForEach ($cms_principal in $Principals) {
			# verify the input
			If ($cms_principal -isnot [System.String] -and $cms_principal -is [System.Security.Principal.SecurityIdentifier]) {
				$cms_sids += $cms_principal
			}
			Else {
				Try {
					# check for specific well-known SIDs or translate the SID
					switch ($cms_principal) {
						# well-known built-in SID that only translates on a domain controller
						{ ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
							$cms_sids += [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
						}
						# a SID in string format
						{ ($_ -match 'S-1-\d{1,2}-\d+') } {
							$cms_sids += [System.Security.Principal.SecurityIdentifier]($_)
						}
						# a principal with domain prefix or suffix
						{ ($_ -match '^[\w\s\.-]+\\[\w\s\.-]+$') -or ($_ -match '^[\w\.-]+@[\w\.-]+$') } {
							$cms_sids += ([System.Security.Principal.NTAccount]($_)).Translate([System.Security.Principal.SecurityIdentifier])
						}
						# any other username
						Default {
							$cms_sids += ([System.Security.Principal.NTAccount]("$([System.Environment]::UserDomainName)\$_")).Translate([System.Security.Principal.SecurityIdentifier])
						}
					}
				}
				Catch {
					Write-Output "Could not translate principal to SID: '$cms_principal'"
					Return
				}
			}
		}
	}

	# check local machine store for existing certificate
	$cms_cert = $null
	$cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_regx } | Sort-Object 'NotBefore' | Select-Object -Last 1
	If ($cms_cert) {
		# declare certificate subject
		Write-Host "CMS certificate found, subject: '$($cms_cert.Subject)'"
		# retrieve private key
		$cms_key = Join-Path -Path 'C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys' -ChildPath $cms_cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
		# retrieve private key permissions
		$cms_acl = Get-Acl -Path $cms_key
		# process SIDs
		switch ($Mode) {
			'Grant' {
				# create ACE then add to ACL
				ForEach ($cms_sid in $cms_sids) {
					$cms_ace = New-Object System.Security.AccessControl.FileSystemAccessRule @($cms_sid, 'Read', 'Allow')
					$cms_acl.AddAccessRule($cms_ace)
				}
				# declare actions
				Write-Host "Granting read access to $($cms_sids.Count) principals..."
			}
			'Revoke' {
				# find ACEs with provided SIDs then remove from ACL
				ForEach ($cms_sid in $cms_sids) {
					$cms_ace = $cms_acl.Access | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -match $cms_sid }
					$cms_ace | ForEach-Object { $cms_acl.RemoveAccessRule($_) } | Out-Null
				}
				# declare actions
				Write-Host "Revoking read access for $($cms_sids.Count) principals..."
			}
			'Reset' {
				# remove all ACEs from ACL
				$cms_acl.Access | ForEach-Object { $cms_acl.RemoveAccessRule($_) } | Out-Null
				# create ACEs then add to ACL
				ForEach ($cms_sid in $cms_sids) {
					$cms_ace = New-Object System.Security.AccessControl.FileSystemAccessRule @($cms_sid, 'FullControl', 'Allow')
					$cms_acl.AddAccessRule($cms_ace)
				}
				# declare actions
				Write-Host "Removing previous access and granting full control to: 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators'"
			}
		}
		# update ACL on private key
		Try {
			If ($PSCmdlet.ShouldProcess($cms_cert.Subject, "$cms_mode access to CMS certificate")) {
				# update ACL on private key
				Set-Acl -Path $cms_key -AclObject $cms_acl
				# declare actions
				Write-Host "CMS certificate permissions updated: '$($cms_cert.Subject)'"
			}
		}
		Catch {
			Return $_
		}
	}
	Else {
		Write-Output "CMS certificate not found: '$($cms_cert.Subject)'"
		Return
	}
}

Function Protect-CmsCredentials {
	<#
	.SYNOPSIS
	Protects a credential with CMS.

	.DESCRIPTION
	Creates a CMS certificate and encrypts the credential with the certificate using CMS. The calling user must have read access to the public key of the certificate that will protect the credential.

	.PARAMETER Cred
	Specifies a PSCredential object to be protected with CMS.

	.PARAMETER Username
	Specifies the username of a new credential to be protected with CMS.

	.PARAMETER Password
	Specifies the password of a new credential to be protected with CMS.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" AsPlainText

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" -Prefix "private" -AsPlainText

	#>

	[CmdletBinding(DefaultParameterSetName = 'Cred')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Mandatory = $True, ParameterSetName = 'Cred', ValueFromPipeline = $true)]
		[pscredential]$Cred,
		[Parameter(Mandatory = $True, ParameterSetName = 'Pass')]
		[string]$Username,
		[Parameter(Mandatory = $True, ParameterSetName = 'Pass')]
		[securestring]$Password,
		[Parameter()]
		[string]$Prefix = 'cms',
		[Parameter()]
		[string[]]$ComputerName,
		[Parameter()]
		[string[]]$ClusterName,
		[Parameter()]
		[switch]$Cluster,
		[Parameter()]
		[switch]$Reset,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# check credentials
	If ($null -eq $Cred) {
		Try {
			$Cred = New-Object System.Management.Automation.PSCredential -ArgumentList $Username, $Password
		}
		Catch {
			Write-Error 'could not create credential from username and password'
			Return
		}
	}

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$ProtectParameters = @{
		Identity = $Identity
		Cred     = $Cred
		Prefix   = $Prefix
		Reset    = $Reset
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# protect credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# protect credentials on local computer
			Try {
				Protect-CmsCredentialSecret @ProtectParameters
			}
			Catch {
				Write-Error "could not protect credentials on '$CmsComputer'"
			}
		}
		Else {
			# protect credentials on remote computer
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					# create objects in session
					$ProtectParameters = $using:ProtectParameters
					$ModuleFunctions = $using:ModuleFunctions
					$ModuleAliases = $using:ModuleAliases
					$CmsComputer = $using:CmsComputer

					# load functions of local modules in remote session
					ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
						Try {
							. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
						}
						Catch {
							Write-Host "ERROR: could not define function '$ModuleFunction' on '$CmsComputer'"
							Return
						}
					}

					# load aliases of local modules in remote session
					ForEach ($ModuleAlias in $ModuleAliases.Keys) {
						Try {
							New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
						}
						Catch {
							Write-Host "ERROR: could not define alias '$ModuleAlias' on '$CmsComputer'"
							Return
						}
					}

					# run commands in remote session
					Try {
						Protect-CmsCredentialSecret @using:ProtectParameters
					}
					Catch {
						Write-Error "could not protect credentials on '$CmsComputer'"
					}
				}
			}
			Catch {
				Write-Error "could not connect to '$CmsComputer'"
			}
		}
	}
}

Function Remove-CmsCredentials {
	<#
	.SYNOPSIS
	Removes a credential protected by CMS.

	.DESCRIPTION
	Removes the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Prefix "private" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$RemoveParameters = @{
		Identity = $Identity
		Prefix   = $Prefix
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# remove credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# remove credentials on local computer
			Try {
				Remove-CmsCredentialSecret @RemoveParameters
			}
			Catch {
				Write-Error "could not remove credentials on '$CmsComputer''"
			}
		}
		Else {
			# remove credentials on remote computer
			$RemoveFunction = "function Remove-CmsCredentialSecret {${function:Remove-CmsCredentialSecret}}"
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					. ([ScriptBlock]::Create($using:RemoveFunction))
					Remove-CmsCredentialSecret @using:RemoveParameters
				}
			}
			Catch {
				Write-Error "could not remove credentials on '$CmsComputer'"
			}
		}
	}
}

Function Show-CmsCredentials {
	<#
	.SYNOPSIS
	Display a credential protected by CMS.

	.DESCRIPTION
	Display the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Prefix "private" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0)][AllowEmptyString()]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$ShowParameters = @{
		Identity = $Identity
		Prefix   = $Prefix
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# show credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# show credentials on local computer
			Try {
				Show-CmsCredentialSecret @ShowParameters
			}
			Catch {
				Write-Error "could not display credentials on '$CmsComputer''"
			}
		}
		Else {
			# show credentials on remote computer
			$ShowFunction = "function Show-CmsCredentialSecret {${function:Show-CmsCredentialSecret}}"
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					. ([ScriptBlock]::Create($using:ShowFunction))
					Show-CmsCredentialSecret @using:ShowParameters
				}
			}
			Catch {
				Write-Error "could not display credentials on '$CmsComputer'"
			}
		}
	}
}

Function Unprotect-CmsCredentials {
	<#
	.SYNOPSIS
	Retrieves a credential protected by CMS.

	.DESCRIPTION
	Retrieves a credential encrypted by a CMS certificate. The calling user must have read access to the private key of the certificate that protects the credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER AsPlainText
	Specifies the credential should be returned as a plain-text password. This changes the output to a PSCustomObject with Username and Password properties.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER Hostname
	Specifies the hostname in the CMS credential. Set to the local hostname by default.

	.PARAMETER ParentPath
	Specifies the parent path of the CMS credential folder. Set to the ProgramData folder by default.

	.INPUTS
	None.

	.OUTPUTS
	System.Management.Automation.PSCredential or System.Management.Automation.PSCustomObject.

	.EXAMPLE
	PS> Unprotect-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Unprotect-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Unprotect-CmsCredentials -Identity "testcredential" AsPlainText

	.EXAMPLE
	PS> Unprotect-CmsCredentials -Identity "testcredential" -Prefix "private" -AsPlainText

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[switch]$AsPlainText,
		[Parameter(Position = 2)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 3)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
		[Parameter(Position = 4)][ValidateScript({ Test-Path -Path $_ })]
		[string]$ParentPath = [System.Environment]::GetFolderPath('CommonApplicationData')
	)

	# define required strings
	$cms_path = Join-Path -Path $ParentPath -ChildPath ($Prefix, $Hostname -join '_').ToLowerInvariant()

	# verify cms folder
	If (Test-Path -Path $cms_path) {
		# get cms file matching the host and Identity
		$cms_file = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $Identity -and $_.BaseName -match $Hostname } | Sort-Object BaseName | Select-Object -Last 1
		If ($cms_file) {
			# convert the encrypted file into an object
			Try {
				$cms_object = Get-Content -Path $cms_file.FullName | Unprotect-CmsMessage | ConvertFrom-Json
			}
			Catch {
				Write-Host 'ERROR: could not decrypt the CMS file'
				Throw $_
			}
			# return the credentials based upon the params
			If ($cms_object.Username -and $cms_object.Password) {
				If ($AsPlainText) {
					# return a PSCustomObject with username and password
					[PSCustomObject]@{Username = $cms_object.Username; Password = $cms_object.Password }
				}
				Else {
					# return a PSCredential
					New-Object 'System.Management.Automation.PSCredential' -ArgumentList $cms_object.Username, ($cms_object.Password | ConvertTo-SecureString -AsPlainText -Force)
				}
			}
			Else {
				Write-Host 'could not find required objects in CMS file'
				Throw [System.Management.Automation.ItemNotFoundException]
			}
		}
		Else {
			Write-Host "could not find a CMS file for Identity: $Identity"
			Throw [System.Management.Automation.ItemNotFoundException]
		}
	}
	Else {
		Write-Host "could not find the CMS folder: $cms_path"
		Throw [System.Management.Automation.ItemNotFoundException]
	}
}

Function Grant-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Grants read access to the private key protecting a CMS credential

	.DESCRIPTION
	Grants read access to the private key protecting a CMS credential. This allows the permitted principal to decrypt the CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Principals
	Specifies one or more Active Directory principals.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -Cluster

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $True)]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode       = 'Grant'
		Identity   = $Identity
		Principals = $Principals
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# grant credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# grant credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not grant credential access on '$CmsComputer''"
			}
		}
		Else {
			# grant credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Host "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return $_
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Host "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return $_
					}
				}

				# run commands in remote session
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not grant credential access on '$CmsComputer'"
				}
			}
		}
	}
}

Function Reset-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Resets read access to the private key protecting a CMS credential.

	.DESCRIPTION
	Resets read access to the private key protecting a CMS credential. Only the built-in Administrators and SYSTEM will have access to the private key after this command is run against a CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string[]]$ComputerName,
		[Parameter(Position = 2)]
		[string[]]$ClusterName,
		[Parameter(Position = 3)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode     = 'Reset'
		Identity = $Identity
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# reset credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# reset credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not reset credential access on '$CmsComputer''"
			}
		}
		Else {
			# reset credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Error "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Error "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return
					}
				}

				# run commands in remote session
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not reset credential access on '$CmsComputer'"
				}
			}
		}
	}
}

Function Revoke-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Revokes read access to the private key protecting a CMS credential

	.DESCRIPTION
	Revokes read access to the private key protecting a CMS credential. This function cannot revoke access to SYSTEM or the built-in Administrators.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Principals
	Specifies one or more Active Directory principals.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -Cluster

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $True)]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode       = 'Revoke'
		Identity   = $Identity
		Principals = $Principals
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# revoke credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# revoke credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not revoke credential access on '$CmsComputer''"
			}
		}
		Else {
			# revoke credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Error "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Error "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return
					}
				}

				# update credential access on remote computer
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not revoke credential access on '$CmsComputer'"
				}
			}
		}
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'New-CmsCredentialCertificate'
$functions_to_export += 'Protect-CmsCredentialSecret'
$functions_to_export += 'Remove-CmsCredentialSecret'
$functions_to_export += 'Show-CmsCredentialSecret'
$functions_to_export += 'Protect-CmsCredentials'
$functions_to_export += 'Remove-CmsCredentials'
$functions_to_export += 'Show-CmsCredentials'
$functions_to_export += 'Unprotect-CmsCredentials'
$functions_to_export += 'Grant-CmsCredentialAccess'
$functions_to_export += 'Reset-CmsCredentialAccess'
$functions_to_export += 'Revoke-CmsCredentialAccess'
$functions_to_export += 'Update-CmsCredentialAccess'

# export module members
Export-ModuleMember -Function $functions_to_export