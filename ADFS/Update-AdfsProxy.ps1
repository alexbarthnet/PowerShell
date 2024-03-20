#Requires -Modules CmsCredentials,WebApplicationProxy

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
			Throw $_
		}

		# install WAP configuration
		If ($FederationServiceTrustCredential -isnot [System.Management.Automation.PSCredential]) {
			Write-Warning 'required CMS credential not found'
			Throw
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
			Throw $_
		}
	}

	Function Start-WebApplicationProxyServices {
		# start services in forward order:
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
				Throw $_
			}
			# test service
			If ($Service.Status -eq 'Running') {
				Write-Host "found service running: '$Name'"
				Continue
			}
			# start service
			Try {
				Start-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not start service: '$Name'"
				Throw $_
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
				Throw $_
			}
			# test service
			If ($Service.Status -eq 'stopped') {
				Write-Host "found service stopped: '$Name'"
				Continue
			}
			# stop service
			Try {
				Stop-Service @ServiceParameters
			}
			Catch {
				Write-Warning "could not stop service: '$Name'"
				Throw $_
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

	Function Start-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path for transcript file
			[Parameter()]
			[string]$TranscriptPath,
			# log start time
			[Parameter(DontShow)]
			[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
		}

		# verify transcript path
		If (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
			# define parameters for New-Item
			$NewItem = @{
				Path        = $TranscriptPath
				ItemType    = 'Directory'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create transcript path
			Try {
				$null = New-Item @NewItem
			}
			Catch {
				Throw $_
			}
		}

		# build transcript file name with defined prefix, hostname, transcript name and current datetime
		$TranscriptFile = "PowerShell_transcript.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

		# define parameters for Start-Transcript
		$StartTranscript = @{
			Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start transcript
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path of transcript files
			[Parameter()]
			[string]$TranscriptPath,
			# minimum number of transcript files for removal
			[Parameter(DontShow)]
			[uint16]$TranscriptCount = 7,
			# minimum age of transcript files for removal
			[Parameter(DontShow)]
			[double]$TranscriptDays = 7,
			# datetime for transcript files for removal
			[Parameter(DontShow)]
			[datetime]$TranscriptDate = ([datetime]::Now.AddDays(-$TranscriptDays)),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
			# LEGACY: re-define default transcript path as string array containing current path and original path in common application data folder
			[string[]]$TranscriptPath = @([System.Environment]::GetFolderPath('CommonApplicationData'), $TranscriptPath)
		}

		# define filter using default transcript prefix, hostname, and script name
		$TranscriptFilter = "PowerShell_transcript.$TranscriptHost.$TranscriptName*"

		# get transcript files matching filter
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'SilentlyContinue'

		# split transcript files on transcript date
		$NewFiles, $OldFiles = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

		# if count of files after transcript date is less than to cleanup threshold...
		If ($NewFiles.Count -lt $TranscriptCount) {
			# declare skip
			Write-Verbose -Message "Skipping transcript file cleanup; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
		}
		Else {
			# declare cleanup
			Write-Verbose -Message "Removing any transcript files matching '$TranscriptFilter' that are older than '$TranscriptDays' days from: $TranscriptPath" -Verbose
			# remove old transcript files
			ForEach ($OldFile in ($OldFiles | Sort-Object -Property FullName)) {
				Try {
					Remove-Item -Path $OldFile.FullName -Force -Verbose -ErrorAction Stop
				}
				Catch {
					$_
				}
			}
		}

		# stop transcript
		Try {
			$null = Stop-Transcript
		}
		Catch {
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
	$JsonProperties = 'Fqdn', 'Hash'

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

	# verify services are running
	Write-Host 'Verifying WAP services'
	Try {
		Start-WebApplicationProxyServices
	}
	Catch {
		Return $_
	}

	# check WAP health (try 1)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Retrieving WAP configuration from ADFS'
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning 'could not retrieve WAP configuration'
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
			Return $_
		}
		# start services
		Try {
			Start-WebApplicationProxyServices
		}
		Catch {
			Return $_
		}
	}

	# check WAP health (try 2)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Retrieving WAP configuration from ADFS after restart'
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning 'could not retrieve WAP configuration after restart'
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
			Return $_
		}
	}

	# check WAP health (try 3)
	If ($null -eq $WebApplicationProxyConfiguration) {
		Write-Host 'Retrieving WAP configuration from ADFS after reinstall'
		Try {
			$WebApplicationProxyConfiguration = Get-WebApplicationProxyConfiguration
		}
		Catch {
			Write-Warning 'could not retrieve WAP configuration after reinstall'
			Return $_
		}
	}

	# check WAP applications
	Try {
		$WebApplicationProxyApplications = Get-WebApplicationProxyApplication
	}
	Catch {
		Write-Warning 'could not retrieve WAP applications'
		Return $_
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
			Write-Warning "could not update WAP application certificate for: $($WebApplicationProxyApplication.Name)"
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
