	<#
	.SYNOPSIS
	Publishes ADFS SAML-only metadata and token certificates.

	.DESCRIPTION
	Publishes ADFS SAML-only metadata and token certificates. The ADFS metadata is trimmed to remove WS-Fed specific elements and can be further modified to provide better support for SAML Single Logout in specific circumstances.

	.PARAMETER Path
	The folder path for the modified metadata file and token certificate.

	.PARAMETER MetadataFileName
	The file name for the modified metadata file. The default value is 'FederationMetadata.xml'

	.PARAMETER SigningCertificateFileName
	The file name for the token signing certificate. The default value is 'token-signing.crt'

	.PARAMETER EncryptionCertificateFileName
	The file name for the token encryption certificate. The default value is 'token-encryption.crt'

	.PARAMETER Uri
	The optional URI for a remote ADFS metadata file.

	.PARAMETER SkipSigningCertificate
	Switch parameter to skip exporting the token signing certificate.

	.PARAMETER SkipEncryptionCertificate
	Switch parameter to skip exporting the token encryption certificate.

	.PARAMETER IncludeSamlSingleLogoutUpdate
	Switch parameter to update the ADFS metadata with better support for SAML Single Logout

	.INPUTS
	None.

	.OUTPUTS
	None. The script reports the actions taken and does not provide any actionable output.

	.EXAMPLE
	.\Publish-AdfsMetadata.ps1 -Path C:\Content\adfs\metadata
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# local host name
		[Parameter(DontShow)]
		[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
		# local domain name
		[Parameter(DontShow)]
		[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
		# local DNS hostname
		[Parameter(DontShow)]
		[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
		# header for certificate files
		[Parameter(DontShow)]
		[string]$Header = '-----BEGIN CERTIFICATE-----',
		# header for certificate files
		[Parameter(DontShow)]
		[string]$Footer = '-----END CERTIFICATE-----',
		# newline for certificate files
		[Parameter(DontShow)]
		[string]$NewLine = "`n",
		# folder path for metadata files
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Path,
		# file name for metadata file
		[Parameter(Position = 1)]
		[string]$MetadataFileName = 'FederationMetadata.xml',
		# file name for token signing certificate
		[Parameter(Position = 2)]
		[string]$SigningCertificateFileName = 'token-signing.crt',
		# file name for token encryption certificate
		[Parameter(Position = 3)]
		[string]$EncryptionCertificateFileName = 'token-encryption.crt',
		# uri for external metadata file
		[Parameter(Position = 4)]
		[uri]$Uri,
		# switch to skip exporting token signing certificate
		[Parameter(Position = 5)]
		[switch]$SkipSigningCertificate,
		# switch to skip exporting token encryption certificate
		[Parameter(Position = 6)]
		[switch]$SkipEncryptionCertificate,
		# switch to include SAML Single Log Out fix
		[Parameter(Position = 7)]
		[switch]$IncludeSamlSingleLogoutUpdate
	)

	# if path not found...
	If (![System.IO.Directory]::Exists($Path)) {
		# create path
		Try {
			$null = New-Item -Path $Path -Force -ItemType 'Directory' -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not create path: $local:Path"
			Return $_
		}
	}

	# if URI not provided...
	If (!$PSBoundParameters.ContainsKey($Uri)) {
		# create URI using local computer name
		$Uri = "https://$DnsHostName/FederationMetadata/2007-06/FederationMetadata.xml" -as [System.Uri]
	}

	# define parameters for Invoke-WebRequest
	$InvokeRestMethod = @{
		Uri                = $Uri
		Headers            = @{'host' = $Uri.DnsSafeHost }
		UseBasicParsing    = $true
		MaximumRedirection = 0
		ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
	}

	# get local URL for metadata
	Try {
		$XmlFromRestMethod = Invoke-RestMethod @InvokeRestMethod
	}
	Catch {
		Return $_
	}

	################################
	# metadata file
	################################

	# remove WS-Fed sections from ADFS metadata
	ForEach ($XmlNode in $XmlFromRestMethod.EntityDescriptor.RoleDescriptor) {
		Try {
			$null = $XmlFromRestMethod.EntityDescriptor.RemoveChild($XmlNode)
		}
		Catch {
			Write-Warning -Message "could not remove 'RoleDescriptor' nodes from XML"
			Return $_
		}
	}

	# if SAML Single Logout update requested...
	If ($IncludeSamlSingleLogoutUpdate) {
		# define array of descriptors to update
		$DescriptorsToUpdate = @(
			'IDPSSODescriptor'
			'SPSSODescriptor'
		)

		# define hashtable of bindings and location suffixes
		$BindingsAndSuffixes = @{
			'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect' = '?wa=wsignout1.0'
			'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST'     = 'logout.aspx'
		}

		# loop through descriptors
		ForEach ($Descriptor in $DescriptorsToUpdate) {
			# loop through bindings
			ForEach ($Binding in $BindingsAndSuffixes.Keys) {
				# retrieve binding-specific URI for SingleSignOnService
				$SingleSignOnElement = $XmlFromRestMethod.EntityDescriptor.$Descriptor.SingleSignOnService | Where-Object { $_.Binding -eq $Binding }

				# retrieve binding-specific URI for SingleLogoutService
				$SingleLogoutElement = $XmlFromRestMethod.EntityDescriptor.$Descriptor.SingleLogoutService | Where-Object { $_.Binding -eq $Binding }

				# define updated location for SingleLogoutService
				$UpdatedLocation = '{0}{1}' -f $SingleSignOnElement.Location, $BindingsAndSuffixes[$Binding]

				# update SingleLogoutService with updated location
				$SingleLogoutElement.Location = $UpdatedLocation
			}
		}
	}

	# define metadata file path
	$MetadataFilePath = Join-Path -Path $Path -ChildPath $MetadataFileName

	# define metadata file boolean
	$MetadataFileUpdateNeeded = $true

	# if path exists...
	If ([System.IO.File]::Exists($MetadataFilePath)) {
		# create XML object
		$XmlFromFileSystem = [System.Xml.XmlDocument]::new()

		# load XML file
		$XmlFromFileSystem.Load($MetadataFilePath)

		# define XML file comparison boolean
		$XmlFilesMatch = $true

		# compare XML objects for SP SSO Descriptor
		$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.SPSSODescriptor
		$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.SPSSODescriptor
		If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

		# compare XML objects for IDP SSO Descriptor
		$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.IDPSSODescriptor
		$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.IDPSSODescriptor
		If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

		# if XML files match...
		If ($XmlFilesMatch) {
			# update boolean and report state
			$MetadataFileUpdateNeeded = $false
			Write-Host "Found current metadata file at path: $MetadataFilePath"
		}
	}

	# if metadata file needs updating...
	If ($MetadataFileUpdateNeeded) {
		# write metadata file
		Try {
			$XmlFromRestMethod.Save($MetadataFilePath)
		}
		Catch {
			Write-Warning "could not write updated metadata file to path: $MetadataFilePath"
			Return $_
		}

		# report write
		Write-Host "Wrote updated metadata file to path: $MetadataFilePath"
	}

	################################
	# signing certificate
	################################

	# if signing certificate skip not requested...
	If (!$SkipSigningCertificate) {
		# retrieve signing certificate text from ADFS metadata
		Try {
			$SigningCertificateText = $XmlFromRestMethod.EntityDescriptor.IDPSSODescriptor.KeyDescriptor.Where({ $_.use -eq 'signing' })[0].KeyInfo.X509Data.X509Certificate
		}
		Catch {
			Write-Warning "could not retrieve X509Certificate of token signing certificate from metadata file to path: $FilePath"
			Return $_
		}

		# format signing certificate text with unix-style line breaks
		$SigningCertificateTextWithLineBreaks = $SigningCertificateText -replace '.{64}', "`$&$NewLine"

		# create PEM-compatible string from formatted signing certificate text
		$SigningCertificateFileValue = '{0}{1}{2}{3}{4}' -f $Header, $NewLine, $SigningCertificateTextWithLineBreaks, $NewLine, $Footer

		# define signing certificate file path
		$SigningCertificateFilePath = Join-Path -Path $Path -ChildPath $SigningCertificateFileName

		# define signing certificate file boolean
		$SigningCertificateFileUpdateNeeded = $true

		# if signing certificate file path exists...
		If ([System.IO.File]::Exists($SigningCertificateFilePath)) {
			# retrieve content signing certificate file
			$SigningCertificateFileContent = Get-Content -Path $SigningCertificateFilePath -Raw

			# if content and value match...
			If ($SigningCertificateFileContent -eq $SigningCertificateFileValue) {
				# update boolean and report state
				$SigningCertificateFileUpdateNeeded = $false
				Write-Host "Found current signing certificate at path: $SigningCertificateFilePath"
			}
		}

		# if signing certificate file needs updating...
		If ($SigningCertificateFileUpdateNeeded) {
			# write signing certificate file
			Try {
				Set-Content -Path $SigningCertificateFilePath -Value $SigningCertificateFileValue -NoNewline
			}
			Catch {
				Write-Warning "could not write updated signing certificate to path: $SigningCertificateFilePath"
				Return $_
			}

			# report write
			Write-Host "Wrote updated signing certificate to path: $SigningCertificateFilePath"
		}
	}

	################################
	# encryption certificate
	################################

	# if encryption certificate skip not requested...
	If (!$SkipEncryptionCertificate) {
		# retrieve encryption certificate text from ADFS metadata
		Try {
			$EncryptionCertificateText = $XmlFromRestMethod.EntityDescriptor.IDPSSODescriptor.KeyDescriptor.Where({ $_.use -eq 'encryption' })[0].KeyInfo.X509Data.X509Certificate
		}
		Catch {
			Write-Warning "could not retrieve value for X509Certificate of token encryption certificate from metadata file to path: $FilePath"
			Return $_
		}

		# format encryption certificate text with unix-style line breaks
		$EncryptionCertificateTextWithLineBreaks = $EncryptionCertificateText -replace '.{64}', "`$&$NewLine"

		# create PEM-compatible string from formatted encryption certificate text
		$EncryptionCertificateFileValue = '{0}{1}{2}{3}{4}' -f $Header, $NewLine, $EncryptionCertificateTextWithLineBreaks, $NewLine, $Footer

		# define encryption certificate file path
		$EncryptionCertificateFilePath = Join-Path -Path $Path -ChildPath $EncryptionCertificateFileName

		# define encryption certificate file boolean
		$EncryptionCertificateFileUpdateNeeded = $true

		# if encryption certificate file path exists...
		If ([System.IO.File]::Exists($EncryptionCertificateFilePath)) {
			# retrieve content encryption certificate file
			$EncryptionCertificateFileContent = Get-Content -Path $EncryptionCertificateFilePath -Raw

			# if content and value match...
			If ($EncryptionCertificateFileContent -eq $EncryptionCertificateFileValue) {
				# update boolean and report state
				$EncryptionCertificateFileUpdateNeeded = $false
				Write-Host "Found current encryption certificate at path: $EncryptionCertificateFilePath"
			}
		}

		# if encryption certificate file needs updating...
		If ($EncryptionCertificateFileUpdateNeeded) {
			# write encryption certificate file
			Try {
				Set-Content -Path $EncryptionCertificateFilePath -Value $EncryptionCertificateFileValue -NoNewline
			}
			Catch {
				Write-Warning "could not write updated encryption certificate to path: $EncryptionCertificateFilePath"
				Return $_
			}

			# report write
			Write-Host "Wrote updated encryption certificate to path: $EncryptionCertificateFilePath"
		}
	}
