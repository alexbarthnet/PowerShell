#Requires -Modules WebApplicationProxy

<#
.SYNOPSIS
Updates the Web Application Proxy configuration from ADFS.

.DESCRIPTION
Updates the Web Application Proxy configuration from ADFS. The thumbprint and path to the ADFS SSL certificate are retrieved from the provided JSON file. The credential must be manually provided.

.PARAMETER Json
The path to a JSON file containing the configuration for the ADFS service. The following values are required:
 - FQDN - the FQDN of the ADFS service
 - PfxFile - the path to the ADFS SSL certificate PFX file
 - Thumbprint - the thumbprint of the ADFS SSL certificate

.PARAMETER Credential
A credential with administrative rights to the ADFS farm.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsProxy.ps1 -Json C:\Content\adfs\config.json -Credential $Credential
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	# credential for connecing WAP to ADFS
	[Parameter(Mandatory = $True)]
	[pscredential]$Credential
)

Begin {
	Function Import-PfxCertificateWithDpapi {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
			[string]$FilePath,
			[Parameter(Mandatory = $false)]
			[switch]$Force,
			[Parameter(DontShow)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
		)

		# define required parameters for Import-PfxCertificate
		$ImportPfxCertificate = @{
			FilePath          = $FilePath
			CertStoreLocation = $CertStoreLocation
			ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
		}

		# import certificate
		Try {
			$null = Import-PfxCertificate @ImportPfxCertificate
		}
		Catch {
			Write-Warning -Message "could not import certificate to '$CertStoreLocation' store from '$FilePath' PFX file: $($_.Exception.Message)"
			Return $_
		}

		# report imported and return
		Write-Verbose -Message "Imported certificates to '$CertStoreLocation' store from '$FilePath' PFX file"
	}

	Function Test-PfxCertificateImportedToStore {
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(Mandatory = $false)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
			[Parameter(DontShow)]
			[boolean]$CertificateFound = $false
		)

		# get PFX data from certificate
		Try {
			$PfxData = Get-PfxData -FilePath $FilePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve PFX data from '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# get end entity certificates from PFX data
		Try {
			$EndEntityCertificates = $PfxData.EndEntityCertificates
		}
		Catch {
			Write-Warning -Message "could not retrieve end entity certificates from PFX data of '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# get certificates with private keys in store
		Try {
			$Certificates = Get-ChildItem -Path $CertStoreLocation -ErrorAction 'Stop' | Where-Object { $_.HasPrivateKey }
		}
		Catch {
			Write-Warning -Message "could not retrieve certificates from '$CertStoreLocation' path: $($_.Exception.Message)"
			Return $_
		}

		# process thumbprints
		ForEach ($EndEntityCertificate in $EndEntityCertificates) {
			# if thumbprint found in thumbprints of certificates with private keys in store...
			If ($EndEntityCertificate.Thumbprint -in $Certificates.Thumbprint) {
				# declare verified and record found
				Write-Verbose -Message "Found '$CertStoreLocation' store contains certificate with '$($EndEntityCertificate.Thumbprint)' thumbprint and subject: $($EndEntityCertificate.Subject)"
				Return $true
			}
			# if thumbprint not found in thumbprints of certificates with private keys in store...
			Else {
				# immediately return false
				Write-Verbose -Message "Found '$CertStoreLocation' store missing certificate with '$($EndEntityCertificate.Thumbprint)' thumbprint and subject: $($EndEntityCertificate.Subject)"
				Return $false
			}
		}
	}

	Function Start-WebApplicationProxyServices {
		# start services in forward order if :
		#  1. proxy controller (retrieves configuration from ADFS for proxy service)
		#  2. proxy service (proxies requests to destination)
		#  3. "ADFS" service (extends proxy service to support tokens)
		ForEach ($Name in 'appproxyctrl', 'appproxysvc', 'adfssrv') {
			# define parameters
			$ServiceParameters = @{
				Name        = $Name
				Verbose     = $True
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# get service
			Try {
				$Service = Get-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not retrieve service: '$Name'"
				Return $_
			}

			# if service already running...
			If ($Service.Status -eq 'Running') {
				Write-Host "...found service already running: '$Name'"
				Continue
			}

			# if service start type not automatic...
			If ($Service.StartType -ne 'Automatic') {
				Write-Host "...found service without automatic start type: '$Name'"
				Continue
			}

			# start service
			Try {
				Start-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not start service: '$Name'"
				Return $_
			}

			# declare started
			Write-Host "...started service: '$Name'"
		}
	}

	Function Stop-WebApplicationProxyServices {
		# stop services in reverse order:
		#  1. "ADFS" service (extends proxy service to support tokens)
		#  2. proxy service (proxies requests to destination)
		#  3. proxy controller (retrieves configuration from ADFS for proxy service)
		ForEach ($Name in 'adfssrv', 'appproxysvc', 'appproxyctrl') {
			# define parameters
			$ServiceParameters = @{
				Name        = $Name
				Verbose     = $True
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# get service
			Try {
				$Service = Get-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not retrieve service: '$Name'"
				Return $_
			}

			# if service already stopped...
			If ($Service.Status -eq 'Stopped') {
				Write-Host "...found service already stopped: '$Name'"
				Continue
			}

			# stop service
			Try {
				Stop-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not stop service: '$Name'"
				Return $_
			}

			# declare stopped
			Write-Host "...stopped service: '$Name'"
		}
	}

	Function Update-WebApplicationProxyApplicationCertificate {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Name,
			[Parameter(Mandatory = $true)]
			[string]$Id,
			[Parameter(Mandatory = $true)]
			[string]$Thumbprint,
			[string]$CertStorePath = 'Cert:\LocalMachine\My'
		)

		# get certificate
		Try {
			$CurrentCertificate = Get-Item -Path (Join-Path -Path $CertStorePath -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning "could not retrieve external certificate for '$Name' by thumbprint: $Thumbprint"
			Throw $_
		}

		# get latest certificate with same subject as current certificate
		$LatestCertificate = Get-ChildItem -Path $CertStorePath | Where-Object { $_.Subject -eq $CurrentCertificate.Subject } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1

		# if current certificate is latest certificate...
		If ($CurrentCertificate.Thumbprint -eq $LatestCertificate.Thumbprint) {
			Write-Host "Verified external certificate for '$Name' with thumbprint: $($CurrentCertificate.Thumbprint)"
			Return
		}

		# define parameters
		$SetWebApplicationProxyApplication = @{
			Id                            = $Id
			ExternalCertificateThumbprint = $LatestCertificate.Thumbprint
			Verbose                       = $true
			ErrorAction                   = [System.Management.Automation.ActionPreference]::Stop
		}

		# update application with latest certificate
		Try {
			Set-WebApplicationProxyApplication @SetWebApplicationProxyApplication
			Write-Host "Updated external certificate for '$Name' with thumbprint: $($LatestCertificate.Thumbprint)"
		}
		Catch {
			Write-Warning "could not update external certificate for '$Name' with thumbprint: $($LatestCertificate.Thumbprint)"
			Throw $_
		}
	}
}

Process {
	# get JSON data
	Try {
		$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
	}
	Catch {
		Write-Warning -Message "could not retrieve content from JSON file: $Json"
		Return $_
	}

	# define JSON properties
	$JsonProperties = 'FQDN', 'PfxFile', 'Thumbprint'

	# create variables from JSON properties
	ForEach ($Property in $JsonProperties) {
		If ($null -eq $JsonData.$Property) {
			Write-Warning "could not find named property in JSON file: $Property"
			Return
		}
		Else {
			New-Variable -Name $Property -Value $JsonData.$Property
		}
	}

	# test if certificate imported
	Try {
		$PfxFileImported = Test-PfxCertificateImportedToStore -FilePath $PfxFile -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not test if '$PfxFile' file was already imported: $($_.Exception.Message)"
		Return $_
	}

	# if PFX file not imported...
	If (!$PfxFileImported) {
		Try {
			Import-PfxCertificateWithDpapi -FilePath $PfxFile -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not import certificate from '$PfxFile' file: $($_.Exception.Message)"
			Return $_
		}
	}

	# resolve FQDN to IP address
	Try {
		$DnsName = Resolve-DnsName -Name $FQDN -Type A -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not resolve '$FQDN' to IP Address: $($_.Exception.Message)"
		Return
	}

	# report state
	Write-Host 'Verifying ADFS probe...'

	# build ADFS probe URI from hostname
	$Uri = 'http://{0}/adfs/probe' -f $DnsName.IPAddress

	# define counter
	$Counter = 0

	# check probe URI
	While ($Counter -lt 5) {
		# query ADFS server
		Try {
			$WebRequest = Invoke-WebRequest -Uri $Uri -UseBasicParsing -DisableKeepAlive -TimeoutSec 1 -ErrorAction 'SilentlyContinue'
		}
		Catch {
			#
		}

		# if web request found...
		If ($WebRequest) {
			# break out of loop
			Break
		}
		# if web request not found...
		Else {
			# increment counter
			$Counter++
			# wait before next loop
			Start-Sleep -Seconds 2
		}
	}


	# if web request has a status code...
	If ($WebRequest) {
		# if status code is 200...
		If ($WebRequest.StatusCode -eq 200) {
			Write-Host '...verified ADFS probe'
		}
		# if status code is not 200...
		Else {
			Write-Warning "found unexpected status code from ADFS probe URI: $($WebRequest.StatusCode)"
			Return
		}
	}
	# if web request has a status code...
	Else {
		Write-Warning "could not query ADFS probe URI: $($Error[0].Exception.Message)"
		Return
	}

	# verify services are running before checking WAP health
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Verifying WAP services'

		# start services
		Try {
			Start-WebApplicationProxyServices
		}
		Catch {
			Write-Warning "could not start WAP services: $($_.Exception.Message)"
			Return
		}
	}

	# check WAP health (try 1)
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Retrieving WAP configuration from ADFS'

		# retrieve WAP configuration
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning "could not retrieve WAP configuration: '$($_.Exception.Message)"
		}
	}

	# address WAP health (try 1)
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Restarting WAP services'

		# stop services
		Try {
			Stop-WebApplicationProxyServices
		}
		Catch {
			Write-Warning "could not stop WAP services: '$($_.Exception.Message)"
			Return
		}

		# start services
		Try {
			Start-WebApplicationProxyServices
		}
		Catch {
			Write-Warning "could not start WAP services: '$($_.Exception.Message)"
			Return
		}
	}

	# check WAP health (try 2)
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Retrieving WAP configuration from ADFS after restart'

		# retrieve WAP configuration
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning "could not retrieve WAP configuration after restart: $($_.Exception.Message)"
		}
	}

	# address WAP health (try 2)
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Installing WAP with Credential'

		# define parameters for Install-WebApplicationProxy
		$InstallWebApplicationProxy = @{
			CertificateThumbprint            = $Thumbprint
			FederationServiceName            = $Fqdn
			FederationServiceTrustCredential = $Credential
			Verbose                          = $true
			ErrorAction                      = [System.Management.Automation.ActionPreference]::Stop
		}

		# install web application proxy with CMS credentials
		Try {
			Install-WebApplicationProxy @InstallWebApplicationProxy
		}
		Catch {
			Write-Warning "could not install WAP configuration: $($_.Exception.Message)"
			Return $_
		}
	}

	# check WAP health (try 3)
	If ($null -eq $WebApplicationProxyConfiguration) {
		# report state
		Write-Host 'Retrieving WAP configuration from ADFS after reinstall'

		# retrieve WAP configuration
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning "could not retrieve WAP configuration after reinstall: $($_.Exception.Message)"
			Return
		}
	}

	# check WAP applications
	Try {
		$WebApplicationProxyApplications = Get-WebApplicationProxyApplication
	}
	Catch {
		Write-Warning "could not retrieve WAP applications: $($_.Exception.Message)"
		Return
	}

	# check each WAP application
	ForEach ($WebApplicationProxyApplication in $WebApplicationProxyApplications) {
		# if application is http only...
		If ($WebApplicationProxyApplication.ExternalUrl.StartsWith('http://') -and -not $WebApplicationProxyApplication.EnableHTTPRedirect) {
			Write-Warning "skipping HTTP-only application: $($WebApplicationProxyApplication.Name)"
			Continue
		}

		# define parameters
		$UpdateWebApplicationProxyApplicationCertificate = @{
			Name       = $WebApplicationProxyApplication.Name
			Id         = $WebApplicationProxyApplication.Id
			Thumbprint = $WebApplicationProxyApplication.ExternalCertificateThumbprint
		}

		# update web application
		Try {
			Update-WebApplicationProxyApplicationCertificate @UpdateWebApplicationProxyApplicationCertificate
		}
		Catch {
			Write-Warning "could not update '$($WebApplicationProxyApplication.Name)' WAP application certificate: $($_.Exception.Message)"
			Return $_
		}
	}
}
