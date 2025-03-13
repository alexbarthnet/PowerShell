#Requires -Module ADFS

<#
.SYNOPSIS
Publishes ADFS modified metadata and public signing certificate to a folder.

.DESCRIPTION
Publishes ADFS modified metadata and public signing certificate to a folder. The ADFS metadata is modified to provide better support for SAML single logout in specific circumstances.

.PARAMETER Path
The folder path for the modified metadata files and public signing certificate.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Publish-AdfsMetadata.ps1 -Path C:\Content\adfs\metadata
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# folder path for metadata files
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Path,
	# file paths for metadata files
	[Parameter(Position = 1, Mandatory = $False)]
	[string]$ChildPaths = 'saml-single-logout.xml'
)

Begin {
	Function Export-AdfsCertificate {
		Param(
			[Parameter(Mandatory = $true)][ValidateSet('Service-Communications', 'Token-Decrypting', 'Token-Signing')]
			[string]$CertificateType,
			[string]$FilePath
		)

		# retrieve ADFS certificate
		Try {
			$AdfsCertificate = Get-AdfsCertificate -CertificateType $CertificateType | Where-Object { $_.IsPrimary }
		}
		Catch {
			Write-Warning "could not retrieve certificate with type: $CertificateType"
			Return $_
		}

		# if file path exists...
		If ([System.IO.File]::Exists($FilePath)) {
			# create certificate from path
			Try {
				$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($FilePath)
			}
			Catch {
				Write-Warning "found invalid file at file path: $FilePath"
			}

			# if thumbprints match...
			If ($Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -and $Certificate.Thumbprint -eq $AdfsCertificate.Certificate.Thumbprint) {
				Write-Host "Found current '$CertificateType' ADFS certificate already at path: $FilePath"
				Return
			}
		}

		# export ADFS certificate
		Try {
			$null = Export-Certificate -FilePath $FilePath -Cert $AdfsCertificate.Certificate
		}
		Catch {
			Return $_
		}

		# declare state and return
		Write-Host "Exported '$CertificateType' ADFS certificate to path: $FilePath"
		Return
	}

	Function Get-AdfsEndpointLocalUrl {
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
			# ADFS endpoint address path
			[Parameter(Mandatory = $true)]
			[string]$AddressPath
		)

		# retrieve ADFS endpoint
		Try {
			$AdfsEndpoint = Get-AdfsEndpoint -AddressPath $AddressPath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not retrieve ADFS endpoint for address path: $AddressPath"
			Return $_
		}

		# retrieve URL from ADFS endpoint
		If ($AdfsEndpoint.FullUrl -isnot [System.Uri]) {
			Write-Warning 'found FullUrl on requested endpoint is not a Uri object'
			Return
		}

		# get URL for metadata against local server
		Try {
			$Uri = $AdfsEndpoint.FullUrl.OriginalString.Replace($AdfsEndpoint.FullUrl.DnsSafeHost, $DnsHostName) -as [System.Uri]
		}
		Catch {
			Write-Warning "could not create local URL for 'Federation Metadata' endpoint"
			Return $_
		}

		# return URL
		Return $Uri
	}
}

Process {
	# retrieve ADFS role
	Try {
		$Role = Get-AdfsSyncProperties | Select-Object -ExpandProperty 'Role'
	}
	Catch {
		Write-Warning 'could not retrieve ADFS sync properties'
		Return $_
	}

	# check ADFS role
	switch ($Role) {
		'PrimaryComputer' {
			Write-Host 'Primary ADFS server: updating metadata...'
		}
		'SecondaryComputer' {
			Write-Host 'Secondary ADFS server: skipping metadata update'
			Return
		}
		Default {
			Write-Warning "found unknown ADFS server role: $Role"
			Return
		}
	}

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

	# define certificate type
	$CertificateType = 'Token-Signing'

	# define file path from certificate type
	$ChildPath = '{0}.crt' -f $CertificateType.ToLower()
	$FilePath = Join-Path -Path $Path -ChildPath $ChildPath

	# export token signing certificate
	Try {
		Export-AdfsCertificate -CertificateType $CertificateType -FilePath $FilePath
	}
	Catch {
		Return $_
	}

	# retrieve primary endpoint
	Try {
		$AdfsEndpoint = Get-AdfsEndpoint -AddressPath '/adfs/ls/'
	}
	Catch {
		Write-Warning 'could not retrieve ADFS primary endpoint'
		Return
	}

	# retrieve URL from primary endpoint
	$Uri = $AdfsEndpoint.FullUrl

	# retrieve metadata endpoint
	Try {
		$UriForRestMethod = Get-AdfsEndpointLocalUrl -AddressPath '/FederationMetadata/2007-06/FederationMetadata.xml'
	}
	Catch {
		Write-Warning 'could not retrieve ADFS metadata endpoint with local hostname'
		Return $_
	}

	# define parameters for Invoke-WebRequest
	$InvokeRestMethod = @{
		Uri                = $UriForRestMethod
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

	# define hashtable of bindings and location suffixes
	$BindingLocations = @{
		'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect' = '{0}{1}' -f $Uri, '?wa=wsignout1.0'
		'urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST'     = '{0}{1}' -f $Uri, 'logout.aspx'
	}

	# process custom metadata
	ForEach ($Binding in $BindingLocations.Keys) {
		# retrieve binding-specific URI for SingleLogoutService
		$XmlElement = $XmlFromRestMethod.EntityDescriptor.IDPSSODescriptor.SingleLogoutService | Where-Object { $_.Binding -eq $Binding }

		# update location for binding-specific URI
		$XmlElement.Location = $BindingLocations[$Binding]
	}

	# process child paths for XML files
	:NextChildPath ForEach ($ChildPath in $ChildPaths) {
		# create file path
		$FilePath = Join-Path -Path $Path -ChildPath $ChildPath

		# if path exists...
		If ([System.IO.File]::Exists($FilePath)) {
			# create XML object
			$XmlFromFileSystem = [System.Xml.XmlDocument]::new()

			# load XML file
			$XmlFromFileSystem.Load($FilePath)

			# define comparison boolean
			$XmlFilesMatch = $true

			# compare XML objects for Application Service Role Descriptor
			$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.RoleDescriptor | Where-Object { $_.type -eq 'fed:ApplicationServiceType' }
			$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.RoleDescriptor | Where-Object { $_.type -eq 'fed:ApplicationServiceType' }
			If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

			# compare XML objects for Security Token Service Role Descriptor
			$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.RoleDescriptor | Where-Object { $_.type -eq 'fed:SecurityTokenServiceType' }
			$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.RoleDescriptor | Where-Object { $_.type -eq 'fed:SecurityTokenServiceType' }
			If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

			# compare XML objects for SP SSO Descriptor
			$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.SPSSODescriptor
			$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.SPSSODescriptor
			If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

			# compare XML objects for IDP SSO Descriptor
			$XmlElement1 = $XmlFromFileSystem.EntityDescriptor.IDPSSODescriptor
			$XmlElement2 = $XmlFromRestMethod.EntityDescriptor.IDPSSODescriptor
			If ($XmlElement1.OuterXML -ne $XmlElement2.OuterXML) { $XmlFilesMatch = $false }

			# if XML update required
			If ($XmlFilesMatch) {
				Write-Host "Found current metadata file at path: $FilePath"
				Continue NextChildPath
			}
		}

		# write XML file
		Try {
			$XmlFromRestMethod.Save($FilePath)
		}
		Catch {
			Write-Warning "could not write updated metadata file to path: $FilePath"
			Return $_
		}

		# report write
		Write-Host "Wrote updated metadata file to path: $FilePath"
	}
}
