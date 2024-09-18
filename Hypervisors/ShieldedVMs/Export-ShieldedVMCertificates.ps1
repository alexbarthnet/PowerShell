#requires -Module TranscriptWithHostAndDate

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON file with parameters
	[Parameter(ParameterSetName = 'Json', Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$ParametersFromJson,
	# optional parameter set to load from JSON file
	[Parameter(ParameterSetName = 'Json')]
	[string]$ParameterSetName,
	# path to folder for exported PFX files
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 0)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# one or more Windows domain prinicpals granted access to exported PFX files
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 1)]
	[string[]]$ProtectTo,
	# switch to overwrite existing PFX files
	[Parameter(Mandatory = $false)]
	[switch]$Force,
	# path to certificate store containing Shielded VM certificates
	[Parameter(DontShow)]
	[string]$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
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
	Function Export-PfxCertificateWithDpapi {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(Mandatory = $true)]
			[object]$Certificate,
			[Parameter(Mandatory = $true)]
			[string[]]$ProtectTo,
			[Parameter(Mandatory = $false)]
			[switch]$Force
		)

		# if FilePath found and Force not set...
		If ((Test-Path -Path $FilePath -PathType 'Leaf') -and -not $local:Force) {
			# test PFX certificate matches certificate
			Try {
				$PfxCertificateAlreadyExported = Test-PfxCertificate -FilePath $FilePath -Certificate $Certificate
			}
			Catch {
				Return $_
			}

			# if PFX certificate already exported...
			If ($PfxCertificateAlreadyExported) {
				Return
			}
		}

		# define required parameters for Export-PfxCertificate
		$ExportPfxCertificate = @{
			Cert                  = $Certificate
			FilePath              = $FilePath
			ProtectTo             = $ProtectTo
			ChainOption           = 'EndEntityCertOnly'
			CryptoAlgorithmOption = 'AES256_SHA256'
		}

		# define optional parameters for Export-PfxCertificate
		If ($PSBoundParameters.ContainsKey('Force')) {
			$ExportPfxCertificate['Force'] = $Force
		}

		# export certificate as .pfx
		Try {
			$null = Export-PfxCertificate @ExportPfxCertificate
			Write-Verbose -Verbose -Message "Exported certificate with '$($Certificate.Subject)' subject to PFX file at path: $FilePath"
		}
		Catch {
			Throw $_
		}
	}

	Function Test-PfxCertificate {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(Mandatory = $true)]
			[object]$Certificate,
			[Parameter(Mandatory = $false)]
			[switch]$IsBundle
		)

		# get PFX data from certificate
		Try {
			$PfxData = Get-PfxData -FilePath $FilePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve PFX data from '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# get thumbprints from PFX
		Try {
			$Thumbprints = $PfxData.EndEntityCertificates | Select-Object -ExpandProperty 'Thumbprint'
		}
		Catch {
			Write-Warning -Message "could not retrieve thumbprint from PFX data of '$Path' file: $($_.Exception.Message)"
			Return $_
		}

		# if certificate thumbprint found in PFX file and PFX file is not a bundle...
		If ($Certificate.Thumbprint -eq $Thumbprints -and -not $IsBundle) {
			# declare verified and return true
			Write-Verbose -Verbose -Message "Found '$FilePath' PFX file contains certificate with '$($Certificate.Thumbprint)' thumbprint and subject: $($Certificate.Subject)"
			Return $true
		}

		# if certificate thumbprint found in PFX file and PFX file is bundle...
		If ($Certificate.Thumbprint -in $Thumbprints -and $IsBundle) {
			# declare verified and return true
			Write-Verbose -Verbose -Message "Found '$FilePath' PFX file contains certificate with '$($Certificate.Thumbprint)' thumbprint and subject: $($Certificate.Subject)"
			Return $true
		}

		# declare not found and return false
		Write-Verbose -Verbose -Message "Found '$FilePath' PFX file missing certificate with '$($Certificate.Thumbprint)' thumbprint and subject: $($Certificate.Subject)"
		Return $false
	}

	Function Get-GroupsFromWindowsIdentity {
		Param(
			[Parameter(Mandatory = $true)]
			[System.Security.Principal.WindowsIdentity]$WindowsIdentity
		)

		# if windows identity is system...
		If ($WindowsIdentity.IsSystem) {
			# get computer DN
			$DistinguishedName = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine' -Name 'Distinguished-Name'

			# get directory entry
			$DirectoryEntry = [System.DirectoryServices.DirectoryEntry]::New("LDAP://$DistinguishedName")

			# add token groups to directory entry
			$DirectoryEntry.RefreshCache('tokenGroups')

			# get token groups from directory entry
			$TokenGroups = $DirectoryEntry.Properties['tokenGroups'].Value

			# translate token groups into windows groups
			$Groups = $TokenGroups | ForEach-Object { [System.Security.Principal.SecurityIdentifier]::new($_, 0).Translate([System.Security.Principal.NTAccount]).Value }
		}
		# if windows identity is not system...
		Else {
			# get groups directly from windows identity object
			$Groups = $WindowsIdentity.Groups.Where({ $_.AccountDomainSid }).Translate([System.Security.Principal.NTAccount]).Where({ !$_.Value.StartsWith('NT AUTHORITY') }).Value
		}

		# return groups
		Return $Groups
	}

	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# if parameter from JSON file provided...
	If ($PSBoundParameters.ContainsKey('ParametersFromJson')) {
		# retrieve content of JSON file as PSCustomObject
		Try {
			$ParametersFromJsonObject = Get-Content -Path $ParametersFromJson -ErrorAction 'Stop' | ConvertFrom-Json -ErrorAction 'Stop'
		}
		Catch {
			Return $_
		}

		# retrieve parameter sets for command
		Try {
			$ParameterSets = (Get-Command -Name $PSCommandPath).ParameterSets
		}
		Catch {
			Return $_
		}

		# if named parameter set name defined...
		If ($PSBoundParameters.ContainsKey('ParameterSetName')) {
			# get parameters available in named parameter set
			$ParametersFromScript = $ParameterSets.Where({ $_.Name -eq $ParameterSetName }).Parameters
		}
		# if default parameter set name defined...
		ElseIf ($ParameterSets.IsDefault) {
			# get parameters in default parameter set
			$ParametersFromScript = $ParameterSets.Where({ $_.IsDefault }).Parameters
		}
		Else {
			# get parameters
			$ParametersFromScript = $ParameterSets.Parameters
		}

		# get parameter names from property names in PSCustomObject for parameters not defined at runtime
		$ParameterNames = $ParametersFromScript.Where({ $ParametersFromJsonObject.PSObject.Properties.Name.Contains($_.Name) -and -not $PSBoundParameters.ContainsKey($_.Name) }).Name

		# define parameters from JSON
		ForEach ($ParameterName in $ParameterNames) {
			# add parameter to bound parameters
			Try {
				$PSBoundParameters.Add($ParameterName, $ParametersFromJsonObject.$ParameterName)
			}
			Catch {
				Return $_
			}
			# create variable from parameter
			Try {
				Set-Variable -Name $ParameterName -Value $ParametersFromJsonObject.$ParameterName -Scope 'Script'
			}
			Catch {
				Return $_
			}
		}
	}

	# create CertStoreLocation if not found
	If (!(Test-Path -Path $CertStoreLocation)) {
		Try {
			$null = New-Item -Path $CertStoreLocation -ItemType 'Directory' -ErrorAction 'Stop'
		}
		Catch {
			Return $_
		}
	}

	# get windows identity of current user
	Try {
		$WindowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
	}
	Catch {
		Return $_
	}

	# get groups from windows identity
	Try {
		$Groups = Get-GroupsFromWindowsIdentity -WindowsIdentity $WindowsIdentity
	}
	Catch {
		Return $_
	}

	# validate ProtectTo
	ForEach ($Group in $Groups) {
		# if ProtectTo includes a current group...
		If ($ProtectTo.Contains($Group)) {
			# declare ProtectTo is valid
			$script:ProtectToValid = $true
		}
	}

	# if ProtectTo is not valid and force not set...
	If (!$script:ProtectToValid -and -not $Force) {
		Write-Warning -Message "current user is not a member of any of the provided groups: $ProtectTo"
		Return
	}

	# retrieve shielded VM certificates from certificate store
	Try {
		$ShieldedVMCertificates = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Subject -match $Hostname }
	}
	Catch {
		Write-Warning -Message "could not search '$CertStoreLocation' for certificates: $($_.Exception.Message)"
		Return $_
	}

	# export shielded VM certificates to path
	:NextCertificate ForEach ($Certificate in $ShieldedVMCertificates) {
		# determine certificate type
		switch ($Certificate.Subject) {
			{ $_.StartsWith('CN=Shielded VM Encryption Certificate (UntrustedGuardian)') } {
				$MidFix = 'encrypt'
			}
			{ $_.StartsWith('CN=Shielded VM Signing Certificate (UntrustedGuardian)') } {
				$MidFix = 'signing'
			}
			Default {
				Write-Warning -Message "could not determine certificate type from subject: $($Certificate.Subject)"
				Continue NextCertificate
			}
		}

		# define base name
		$BaseName = 'untrustedguardian', $HostName, $MidFix, $Certificate.NotBefore.ToUniversalTime().ToString('yyyyMMddThhmmssZ') -join '_'

		# define file path
		$FilePath = Join-Path -Path $Path -ChildPath "$BaseName.pfx"

		# define required paramters for Export-PfxCertificateWithDpapi
		$ExportPfxCertificateWithDpapi = @{
			FilePath    = $FilePath
			Certificate = $Certificate
			ProtectTo   = $script:ProtectTo
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Export-PfxCertificateWithDpapi
		If ($local:Force) {
			$ExportPfxCertificateWithDpapi['Force'] = $local:Force
		}

		# export certificate to PFX file
		Try {
			Export-PfxCertificateWithDpapi @ExportPfxCertificateWithDpapi
		}
		Catch {
			Write-Warning -Message "could not export '$($Certificate.Subject)' certificate to '$FilePath' path: $($_.Exception.Message)"
		}
	}
}

End {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
