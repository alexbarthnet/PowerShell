#Requires -Modules CmsCredentials,WebApplicationProxy,TranscriptWithHostAndDate

<#
.SYNOPSIS
Updates the Web Application Proxy configuration from ADFS.

.DESCRIPTION
Updates the Web Application Proxy configuration from ADFS. The CmsCredentials module is used to store credentials for connecting to the ADFS farm. A separate process must install any required certificates on each server in the farm.

.PARAMETER Json
The path to a JSON file containing the configuration for the ADFS service. The following values are required:
 - FQDN - the FQDN of the ADFS service
 - Hash - the thumbprint hash of the ADFS SSL certificate

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsProxy.ps1 -Json C:\Content\adfs\config.json
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
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
	Function Install-WebApplicationProxyWithCMS {
		[CmdletBinding()]
		Param (
			[Parameter(Mandatory = $true)]
			[string]$CertificateThumbprint,
			[Parameter(Mandatory = $true)]
			[string]$FederationServiceName
		)

		# retrieve ADFS credentials from CMS
		Try {
			$FederationServiceTrustCredential = Unprotect-CmsCredentials -Identity $FederationServiceName
		}
		Catch {
			Write-Warning "error retrieving CMS credentials: $($_.ToString())"
			Return $_
		}

		# install WAP configuration
		If ($FederationServiceTrustCredential -isnot [System.Management.Automation.PSCredential]) {
			Write-Warning 'required CMS credential not found'
			Return
		}

		# define parameters for Install-WebApplicationProxy
		$InstallWebApplicationProxy = @{
			CertificateThumbprint            = $CertificateThumbprint
			FederationServiceName            = $FederationServiceName
			FederationServiceTrustCredential = $FederationServiceTrustCredential
			Verbose                          = $true
			ErrorAction                      = [System.Management.Automation.ActionPreference]::Stop
		}

		# install web application proxy with CMS credentials
		Try {
			Install-WebApplicationProxy @InstallWebApplicationProxy
		}
		Catch {
			Return $_
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
				Write-Warning "could not get service: '$Name'"
				Return $_
			}
			# if service already running...
			If ($Service.Status -eq 'Running') {
				Write-Host "found service already running: '$Name'"
				Continue
			}
			# if service start type not automatic...
			If ($Service.StartType -ne 'Automatic') {
				Write-Host "found service without automatic start type: '$Name'"
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
			Write-Host "started service: '$Name'"
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
				Write-Warning "could not get service: '$Name'"
				Return $_
			}
			# if service already stopped...
			If ($Service.Status -eq 'Stopped') {
				Write-Host "found service already stopped: '$Name'"
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
			Write-Host "stopped service: '$Name'"
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

	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $PSBoundParameters['TranscriptName'] }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $PSBoundParameters['TranscriptPath'] }
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# define JSON properties
	$JsonProperties = 'Primary', 'Fqdn', 'Hash'

	# get JSON data
	$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)

	# create variables from JSON properties
	ForEach ($Property in $JsonProperties) {
		If ($null -eq $JsonData.$Property) {
			Write-Warning "could not find '$Property' in JSON file"
			Return
		}
		Else {
			New-Variable -Name $Property -Value $JsonData.$Property
		}
	}

	# verify connectivity
	ForEach ($AdfsServer in $Primary, $Fqdn) {
		# build ADFS probe URI from hostname
		$Uri = "http://$AdfsServer/adfs/probe"

		# query ADFS server
		Try {
			$WebRequest = Invoke-WebRequest -Uri $Uri -UseBasicParsing
		}
		Catch {
			Write-Warning "could not connect to '$AdfsServer' probe URI: $($_.Exception.Message)"
			Return
		}

		# if web request status code is 200...
		If ($WebRequest.StatusCode -eq 200) {
			Write-Host "Validated ADFS probe on hostname: '$AdfsServer'"
		}
		Else {
			Write-Warning "could not connect to ADFS probe on hostname: '$AdfsServer'"
			Return
		}
	}


	# verify services are running
	Write-Host 'Verifying WAP services'
	Try {
		Start-WebApplicationProxyServices
	}
	Catch {
		Write-Warning "could not start WAP services: $($_.Exception.Message)"
		Return
	}

	# check WAP health (try 1)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Retrieving WAP configuration from ADFS'
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning "could not retrieve WAP configuration: '$($_.Exception.Message)"
		}
	}

	# address WAP health (try 1)
	If ($null -eq $WebApplicationProxyConfiguration) {
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
		Write-Host 'Retrieving WAP configuration from ADFS after restart'
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning "could not retrieve WAP configuration after restart: $($_.Exception.Message)"
		}
	}

	# address WAP health (try 2)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Installing WAP with CmsCredentials'
		# get WAP configuration
		Try {
			Install-WebApplicationProxyWithCMS -CertificateThumbprint $Hash -FederationServiceName $Fqdn
		}
		Catch {
			Write-Warning "could not reinstall WAP configuration: $($_.Exception.Message)"
			Return
		}
	}

	# check WAP health (try 3)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Retrieving WAP configuration from ADFS after reinstall'
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

End {
	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
