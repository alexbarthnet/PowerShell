Param(
	[Parameter()]
	[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'PowerShell_GPOReports'),
	[Parameter()]
	[switch]$Reset,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(DontShow)]
	[string]$DomainDistinguishedName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(DontShow)]
	[timespan]$TimeSpan = (New-TimeSpan -Seconds 5)
)

Begin {
	# set error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	Function Get-GPOReportXML {
		Param(
			[Parameter(Mandatory)]
			[guid]$Guid,
			[Parameter(Mandatory)]
			[string]$Path,
			[Parameter(Mandatory)]
			[datetime]$Time
		)

		# create XML object
		$Xml = [System.Xml.XmlDocument]::new()

		# if XML file found...
		If (Test-Path -Path $Path -PathType Leaf) {
			# load file contents into XML object
			Try {
				$Xml.Load($Path)
			}
			Catch {
				Write-Warning "could not load XML from existing file: $Path"
				Throw $_
			}

			# get datetime from XML
			Try {
				$ModifiedTime = [datetime]::Parse($Xml.GPO.ModifiedTime)
			}
			Catch {
				Write-Warning "could not parse ModifiedTime from XML: $Guid"
				Throw $_
			}

			# if difference between GPO whenChanged time and XML modified time is within allowed timespan...
			If (($Time - $ModifiedTime) -le $TimeSpan) {
				Return $Xml
			}
		}

		# define parameters
		$GetGPOReport = @{
			Guid        = $Guid
			ReportType  = 'Xml'
			Domain      = $Domain
			Server      = $Server
		}

		# get GPO report as XML string
		Try {
			$GPOReport = Get-GPOReport @GetGPOReport
		}
		Catch {
			Write-Warning "could not get XML string from Get-GPOReport: $Guid"
			Throw $_
		}

		# load GPO report into XML object
		Try {
			$Xml.LoadXml($GPOReport)
		}
		Catch {
			Write-Warning "could not load XML string from Get-GPOReport: $Guid"
			Throw $_
		}

		# save GPO report to file
		Try {
			$Xml.Save($Path)
		}
		Catch {
			Write-Warning "could not save XML object to file: $Guid"
			Throw $_
		}

		# return XML
		Return $Xml
	}

	# if reset requested...
	If ($PSBoundParameters.ContainsKey('Reset')) {
		Write-Warning 'All cached GPO report objects will be removed.' -WarningAction Inquire
		$global:GPOReports = $null
	}

	# create list for GPO reports if not found
	If ($global:GPOReports -isnot [System.Collections.Generic.Dictionary[System.Guid, System.Xml.XmlDocument]]) {
		$global:GPOReports = [System.Collections.Generic.Dictionary[System.Guid, System.Xml.XmlDocument]]::new()
	}

	# create collections for GPO displayName and whenChanged properties
	$GPONames = [System.Collections.Generic.Dictionary[System.Guid, System.String]]::new()
	$GPOTimes = [System.Collections.Generic.Dictionary[System.Guid, System.DateTime]]::new()

	# create lists for GPO GUIDs in domain and GPO GUIDs to remove 
	$GPOGuidsInDomain = [System.Collections.Generic.List[System.Guid]]::new()
	$GPOGuidsToRemove = [System.Collections.Generic.List[System.Guid]]::new()

	# define initial values for Write-Progress
	$ParentId = 0
	$CurrentId = 1

	# verify path
	If (!(Test-Path -Path $Path -PathType Container)) {
		Try {
			$null = New-Item -Path $Path -ItemType Directory -Force
		}
		Catch {
			Write-Warning "could not create GPOReports folder: $Path"
			Throw $_
		}
	}

	# create parent progress
	Write-Progress -Id $CurrentId -ParentId $ParentId -Activity 'Processing GPOs'

	# define parameters
	$GetADObject = @{
		Server      = $Server
		LDAPFilter  = "(objectClass=groupPolicyContainer)"
		SearchBase  = "CN=Policies,CN=System,$DomainDistinguishedName"
		SearchScope = 'OneLevel'
		Properties  = 'displayName', 'whenChanged'
	}

	# get all GPOs
	Try {
		$GPOs = Get-ADObject @GetADObject
	}
	Catch {
		Write-Warning "could not retrieve GPO objects"
		Throw $_
	}
}

Process {
	# define values for Write-Progress
	$Counter = 0
	$Maximum = $GPOs.Count
	$Activity = 'Retrieving GPO Properties'
	$CurrentId++

	# get GPO values
	ForEach ($GPO in $GPOs) {
		# increment counter for Write-Progress
		$Counter++

		# declare progress
		Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / $Maximum * 100)

		# get GUID from GPO Name
		Try {
			$Guid = [guid]$GPO.Name
		}
		# if get GUID from GPO fails...
		Catch {
			Write-Warning "could not create GUID from GPO object name: $($GPO.Name)"
			Throw $_
		}

		# assign guid
		Try {
			$GPOGuidsInDomain.Add($Guid)
		}
		Catch {
			Write-Warning "could not get add GUID to GUIDs list: $Guid"
			Throw $_
		}

		# assign name
		Try {
			$GPONames[$Guid] = $GPO.displayName
		}
		Catch {
			Write-Warning "could not add GPO displayName to Names collection: $Guid"
			Throw $_
		}

		# assign time
		Try {
			$GPOTimes[$Guid] = $GPO.whenChanged.ToUniversalTime()
		}
		Catch {
			Write-Warning "could not add GPO whenChanged to Times collection: $Guid"
			Throw $_
		}
	}

	# define values for Write-Progress
	$Counter = 0
	$Maximum = $GPOGuidsInDomain.Count
	$Activity = 'Retrieving GPO Reports'
	$CurrentId++

	# get GPO reports
	:NextGPO ForEach ($Guid in $GPOGuidsInDomain) {
		# increment counter for Write-Progress
		$Counter++

		# declare progress
		Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / $Maximum * 100)

		# get GPO whenChanged time
		Try {
			[datetime]$Time = $GPOTimes[$Guid]
		}
		Catch {
			Write-Warning "could not get whenChanged from Times collection: $Guid"
			Throw $_
		}

		# if GPO report collection contains Guid...
		If ($global:GPOReports.ContainsKey($Guid)) {
			# get XML object
			Try {
				$Xml = $global:GPOReports[$Guid]
			}
			Catch {
				Write-Warning "could not get XML from Reports collection: $Guid"
				Throw $_
			}

			# get datetime from XML
			Try {
				$ModifiedTime = [datetime]::Parse($Xml.GPO.ModifiedTime)
			}
			# if get datetime from XML fails...
			Catch {
				Write-Warning "could not get parse ModifiedTime from XML: $Guid"
				Throw $_
			}

			# if difference between GPO whenChanged time and XML modified time is within allowed timespan...
			If (($Time - $ModifiedTime) -le $TimeSpan) {
				Continue NextGPO
			}
		}

		# define required parameters
		$GetGPOReportXML = @{
			Guid = $Guid
			Path = (Join-Path $Path -ChildPath "$Guid.xml")
			Time = $Time
		}

		# get XML from GPO report
		Try {
			$Xml = Get-GPOReportXML @GetGPOReportXML
		}
		Catch {
			Write-Warning "could not get XML object from Get-GPOReportXML: $Guid"
			Throw $_
		}

		# add XML to GPO report collection
		Try {
			$global:GPOReports[$Guid] = $Xml
		}
		Catch {
			Write-Warning "could not add XML object to Reports collection: $Guid"
			Throw $_
		}
	}

	# get GPO report files
	Try {
		$GPOReportFiles = Get-ChildItem -Path $Path -Filter '*.xml'
	}
	Catch {
		Write-Warning "could not retrieve XML files from path: $Path"
		Throw $_
	}

	If (!$PSBoundParameters.ContainsKey('Reset')) {
		# define values for Write-Progress
		$Counter = 0
		$Maximum = $global:GPOReports.Keys.Count
		$Activity = 'Checking GPO Report objects'
		$CurrentId++

		# review GPO report files
		ForEach ($Guid in $global:GPOReports.Keys) {
			# increment counter for Write-Progress
			$Counter++

			# declare progress
			Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / $Maximum * 100)

			# if GUID not in list of GPO GUIDs...
			If ($Guid -notin $GPOGuidsInDomain) {
				Try {
					$GPOGuidsToRemove.Add($Guid)
				}
				Catch {
					Write-Warning "could not add GUID to Remove list: $Guid"
					Throw $_
				}
			}
		}

		# define values for Write-Progress
		$Counter = 0
		$Maximum = $GPOGuidsToRemove.Count
		$Activity = 'Trimming GPO Report objects'
		$CurrentId++
		
		# review GPO report files
		ForEach ($Guid in $GPOGuidsToRemove) {
			# increment counter for Write-Progress
			$Counter++
		
			# declare progress
			Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / $Maximum * 100)
		
			# remove GUID from GPOReports
			Try {
				$null = $global:GPOReports.Remove($Guid)
			}
			Catch {
				Write-Warning "could not remove GPO report object from collection: $Guid"
				Throw $_
			}
		}
	}

	# define values for Write-Progress
	$Counter = 0
	$Maximum = $GPOReportFiles.Count
	$Activity = 'Trimming GPO Report files'
	$CurrentId++

	# review GPO report files
	ForEach ($GPOReportFile in $GPOReportFiles) {
		# increment counter for Write-Progress
		$Counter++

		# declare progress
		Write-Progress -Id $CurrentId -ParentId $ParentId -Activity $Activity -Status "$Counter of $Maximum" -PercentComplete ($Counter / $Maximum * 100)

		# if GPO report file name not in list of GPO GUIDs...
		If ($GPOReportFile.BaseName -notin $GPOGuidsInDomain) {
			# remove GPO report file
			Try {
				$GPOReportFile.Delete()
			}
			Catch {
				Write-Warning "could not remove GPO report file from folder: $Guid"
				Throw $_
			}
		}
	}
}
