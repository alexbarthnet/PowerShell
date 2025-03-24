[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 1, Mandatory)]
	[string]$Path,
	[Parameter(Position = 2)]
	[string[]]$Include,
	[Parameter(Position = 3)]
	[string[]]$Exclude,
	[Parameter(Position = 4)]
	[string]$StagingPath,
	[Parameter(Position = 5)]
	[switch]$EmptyStagingPath,
	[Parameter(Position = 6)]
	[switch]$Specialize,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name,
	[Parameter(DontShow)]
	[string]$PartitionsDN = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Schema.Name.Replace('CN=Schema', 'CN=Partitions'),
	[Parameter(DontShow)]
	[string]$DomainNCName = [System.DirectorySErvices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(DontShow)]
	[string]$DomainNBName = [System.DirectoryServices.DirectorySearcher]::new("LDAP://$PartitionsDN", "(nCName=$DomainNCName)", 'CN', 'OneLevel').FindOne().Properties['CN'],
	[Parameter(DontShow)]
	[string]$GenericServer = 'dc-1.generic.local',
	[Parameter(DontShow)]
	[string]$GenericDomain = 'generic.local',
	[Parameter(DontShow)]
	[string]$GenericDomainNBName = 'GENERIC'
)

Begin {
	Function ConvertFrom-GenericGroupPolicyPolFile {
		Param(
			[Parameter(Mandatory)]
			$Path,
			$Guid = [System.Guid]::Empty
		)

		# read text of POL file as bytes
		Try {
			$Bytes = [System.IO.File]::ReadAllBytes($Path)
		}
		Catch {
			Return $_
		}

		# convert bytes to hex string as text
		$OriginalText = [System.BitConverter]::ToString($Bytes)

		# define modified text to preserve original text
		$ModifiedText = $OriginalText

		# replace generic server name with current server name
		$ModifiedText = $ModifiedText.Replace($GenericServerAsPaddedHex, $CurrentServerAsPaddedHex)
		
		# replace generic domain name with current domain name
		$ModifiedText = $ModifiedText.Replace($GenericDomainAsPaddedHex, $CurrentDomainAsPaddedHex)

		# if text is the same...
		If ($ModifiedText -eq $OriginalText) {
			Write-Verbose -Message "$Guid; specialization not required for POL file: $Path"
			Return
		}

		# format modified text for conversation to byte array then cast to byte array
		$Bytes = $ModifiedText -split '-' -replace '..', '0x$&' -as [System.Byte[]]

		# write modified text as bytes to POL file
		Try {
			[System.IO.File]::WriteAllBytes($Path, $Bytes)
		}
		Catch {
			Return $_
		}

		# report state
		Write-Verbose -Message "$Guid; specialized POL file: $Path"
	}

	Function ConvertFrom-GenericGroupPolicyXmlFile {
		Param(
			[Parameter(Mandatory)]
			$Path,
			$Guid = [System.Guid]::Empty
		)

		# read original text of XML file
		Try {
			$OriginalText = [System.IO.File]::ReadAllText($Path)
		}
		Catch {
			Return $_
		}

		# define modified text to preserve original text
		$ModifiedText = $OriginalText

		# replace bracketed NetBIOS domain name with bracketed generic NetBIOS domain name
		$ModifiedText = $ModifiedText.Replace("[CDATA[$DomainNBName]]", "[CDATA[$GenericDomainNBName]]")

		# replace suffixed NetBIOS domain name with suffixed generic NetBIOS domain name
		$ModifiedText = $ModifiedText.Replace("$DomainNBName\", "$GenericDomainNBName\")

		# replace domain controller with generic domain controller
		$ModifiedText = $ModifiedText.Replace($Server, $GenericServer)

		# replace DNS domain name with generic DNS domain name
		$ModifiedText = $ModifiedText.Replace($Domain, $GenericDomain)

		# if text is the same...
		If ($ModifiedText -eq $OriginalText) {
			Write-Verbose -Message "$Guid; specialization not required for XML file: $Path"
			Return
		}

		# write modified text to XML file
		Try {
			[System.IO.File]::WriteAllText($Path, $ModifiedText)
		}
		Catch {
			Return $_
		}

		# report state
		Write-Verbose -Message "$Guid; specialized XML file: $Path"
	}

	Function New-TemporaryFolder {
		Param(
			[switch]$ForMachine
		)

		# if temporary folder for machine requested...
		If ($ForMachine) {
			# retrieve TEMP environment variable for machine
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		}
		Else {
			# retrieve TEMP environment variable for user
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'User')
		}

		# clear

		# define path for temporary folder
		Do {
			# define temporary folder name
			$NameForTemporaryFolder = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
			# combine TEMP path and temporary folder name
			$PathForTemporaryFolder = Join-Path -Path $PathForTEMP -ChildPath $NameForTemporaryFolder
		}
		Until (![System.IO.Directory]::Exists($PathForTemporaryFolder))

		# create temporary folder
		Try {
			$TemporaryFolder = New-Item -Force -ItemType Directory -Path $PathForTemporaryFolder
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# return temporary folder
		Return $TemporaryFolder
	}

	# if specialize requested...
	If ($Specialize) {
		# define padded hex strings for .pol files
		$CurrentServerAsPaddedHex = [System.BitConverter]::ToString([System.Text.Encoding]::ASCII.GetBytes($Server.ToLowerInvariant())) -split '-' -join '-00-'
		$CurrentDomainAsPaddedHex = [System.BitConverter]::ToString([System.Text.Encoding]::ASCII.GetBytes($Domain.ToLowerInvariant())) -split '-' -join '-00-'
		$GenericServerAsPaddedHex = [System.BitConverter]::ToString([System.Text.Encoding]::ASCII.GetBytes($GenericServer.ToLowerInvariant())) -split '-' -join '-00-'
		$GenericDomainAsPaddedHex = [System.BitConverter]::ToString([System.Text.Encoding]::ASCII.GetBytes($GenericDomain.ToLowerInvariant())) -split '-' -join '-00-'
	}
	
}

Process {
	# if staging path defined...
	If ($PSBoundParameters.ContainsKey('StagingPath')) {
		# if StagingPath is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($StagingPath)) {
			# get unresolved absolute path
			Try {
				$StagingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingPath)
			}
			Catch {
				Write-Warning -Message "could not create absolute path from the provided Path parameter: $StagingPath"
				Return
			}

			# report absolute path
			Write-Warning -Message "converted relative path in provided StagingPath parameter to absolute path: $StagingPath"
		}

		# if staging path not found...
		If (![System.IO.Directory]::Exists($StagingPath)) {
			Write-Warning -Message "could not locate directory for provided StagingPath: $StagingPath"
			Return
		}

		# retrieve child items in StagingPath
		Try {
			$StagingPathItems = Get-ChildItem -Path $StagingPath -Force -Recurse
		}
		Catch {
			Write-Warning -Message 'could not check StagingPath for existing files and folders'
			Return $_
		}

		# if child items found in StagingPath...
		If ($null -ne $StagingPathItems) {
			# if EmptyStagingPath not requested...
			If (!$EmptyStagingPath) {
				# warn and inquire
				Write-Warning -Message 'found existing files or folders in provided StagingPath. Continue to empty StagingPath.' -WarningAction Inquire
			}

			# remove child items in StagingPath
			Try {
				Get-ChildItem -Path $StagingPath -Force -Recurse | Remove-Item -Force -Recurse
			}
			Catch {
				Return $_
			}
		}
	}
	# if staging path not defined...
	Else {
		# create temporary folder
		Try {
			$TemporaryFolder = New-TemporaryFolder
		}
		Catch {
			Return $_
		}

		# define staging path from temporary folder full name
		$StagingPath = $TemporaryFolder.FullName
	}

	# if Path is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Path)) {
		# get unresolved absolute path
		Try {
			$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided Path parameter: $Path"
			Return
		}

		# report absolute path
		Write-Warning -Message "converted relative path in provided Path parameter to absolute path: $Path"
	}

	# if Path is not an existing file...
	If (![System.IO.File]::Exists($Path)) {
		# warn and return
		Write-Warning -Message "could not locate file with provided Path: $Path"
		Return
	}

	# expand archive to staging path
	Try {
		Expand-Archive -Path $Path -DestinationPath $StagingPath -Force
	}
	Catch {
		Write-Warning "could not expand archive at provided Path to staging directory: $StagingPath"
		Return $_
	}

	# retrieve GPO backups...
	Try {
		$GPOBackups = Get-ChildItem -Path $StagingPath -Directory -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve directories in staging path: $StagingPath"
		Return $_
	}

	# report count of GPO backups
	Write-Verbose -Message "found GPO backup folders: $($GPOBackups.Count)"

	# retrieve all GPOs
	Try {
		$GPOs = Get-GPO -Server $Server -All
	}
	Catch {
		Return $_
	}

	# report count of GPO backups
	Write-Verbose -Message "found existing GPOs: $($GPOs.Count)"

	# loop through GPO backups
	:NextGPOBackup ForEach ($GPOBackup in $GPOBackups) {
		# if GPO backup is not a GUID...
		If (![System.Guid]::TryParse($GPOBackup.Name, [ref][System.Guid]::Empty)) {
			# warn and continue to next GPO backup
			Write-Warning -Message "found GPO backup folder that does not parse as a GUID: $($GPOBackup.Name)"
			Continue NextGPOBackup
		}

		# convert GPO backup id to GUID
		$BackupId = [System.Guid]::Parse($GPOBackup.Name).Guid

		# define XML file for GPO backup
		$BackupXml = Join-Path -Path $GPOBackup.FullName -ChildPath 'Backup.xml'

		# if XML file not found...
		If (![System.IO.File]::Exists($BackupXml)) {
			# warn and continue to next GPO backup
			Write-Warning -Message "could not locate expected XML file at path: $BackupXml"
			Continue NextGPOBackup
		}

		# define XML document
		$Xml = [System.Xml.XmlDocument]::new()

		# load backup XML file into XML document
		Try {
			$Xml.Load($BackupXml)
		}
		Catch {
			Write-Warning -Message "could not load XML document from file: $BackupXml"
			Return $_
		}

		# retrieve GPO GUID from XML document
		$Guid = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.Id.InnerText

		# if GPO GUID is empty...
		If ([System.String]::IsNullOrEmpty($Guid)) {
			# report state and continue to next GPO backup
			Write-Warning -Message "could not locate previous ID for GPO in XML file at path: $BackupXml"
			Continue NextGPOBackup
		}

		# retrieve  GPO display name from XML document
		$DisplayName = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.DisplayName.InnerText

		# if GPO display name is empty...
		If ([System.String]::IsNullOrEmpty($DisplayName)) {
			# report state and continue to next GPO backup
			Write-Warning -Message "could not locate display name for GPO in XML file at path: $BackupXml"
			Continue NextGPOBackup
		}

		# if include defined...
		If ($PSBoundParameters.ContainsKey('Include')) {
			# declare include match not found
			$IncludeNotFound = $true

			# loop through include strings...
			ForEach ($IncludeString in $Include) {
				# if GPO display name matches include string...
				If ($DisplayName -like $IncludeString) {
					# update boolean to false
					$IncludeNotFound = $false
				}
			}

			# if include not found...
			If ($IncludeNotFound) {
				Write-Verbose -Message "$BackupId; skipping GPO backup: display name of '$DisplayName' does not match one of the provided Include strings: '$($Include -join ', ')'"
				Continue NextGPOBackup
			}
		}

		# if exclude defined...
		If ($PSBoundParameters.ContainsKey('Exclude')) {
			# loop through exclude strings...
			ForEach ($ExcludeString in $Exclude) {
				# if GPO display name matches exclude string...
				If ($DisplayName -like $ExcludeString) {
					Write-Verbose -Message "$BackupId; skipping GPO backup: display name of '$DisplayName' matches Exclude string: '$ExcludeString'"
					Continue NextGPOBackup
				}
			}
		}

		# if specialize requested...
		If ($Specialize) {
			# define GPO backup XML files
			$XMLFilePaths = @('Backup.xml', 'bkupInfo.xml', 'DomainSysvol\GPO\Machine\Preferences\Groups\Groups.xml')

			# loop through GPO backup XML files
			ForEach ($ChildPath in $XMLFilePaths) {
				# define path for GPO backup XML file
				$PathToXmlFile = Join-Path -Path $GPOBackup.FullName -ChildPath $ChildPath

				# if XML file exists...
				If ([System.IO.File]::Exists($PathToXmlFile)) {
					# specialize XML file
					Try {
						ConvertFrom-GenericGroupPolicyXmlFile -Path $PathToXmlFile -Guid $BackupId
					}
					Catch {
						Return $_
					}
				}
			}

			# define GPO backup POL files
			$POLFilePaths = @('DomainSysvol\GPO\Machine\registry.pol', 'DomainSysvol\GPO\User\registry.pol')

			# loop through GPO backup POL files
			ForEach ($ChildPath in $POLFilePaths) {
				# define path for GPO backup POL file
				$PathToPolFile = Join-Path -Path $GPOBackup.FullName -ChildPath $ChildPath

				# if POL file exists...
				If ([System.IO.File]::Exists($PathToPolFile)) {
					# specialize POL file
					Try {
						ConvertFrom-GenericGroupPolicyPolFile -Path $PathToPolFile -Guid $BackupId
					}
					Catch {
						Return $_
					}
				}
			}
		}

		# define base parameters for Import-GPO
		$ImportGPO = @{
			Server      = $Server
			BackupId    = $BackupId
			Path        = $StagingPath
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# if GUID matches an existing GPO...
		If ($Guid -in $GPOs.Id) {
			# define should process adjective
			$Adjective = 'existing'

			# update parameters for Import-GPO
			$ImportGPO.Add('TargetGuid', $Guid)
		}
		# if GUID does not match an existing GPO...
		Else {
			# define should process adjective
			$Adjective = 'new'

			# update parameters for Import-GPO
			$ImportGPO.Add('TargetName', $DisplayName)
			$ImportGPO.Add('CreateIfNeeded', $true)
		}

		# define should process strings
		$ShouldProcessTarget = $BackupId
		$ShouldProcessAction = "import GPO into $Adjective GPO with display name: $DisplayName"

		# if WhatIf provided...
		If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
			# import GPO
			Try {
				$GPO = Import-GPO @ImportGPO
			}
			Catch {
				Write-Warning -Message "could not import GPO with '$BackupId' backup ID into $Adjective GPO with name: $DisplayName"
				Return $_
			}

			# report state
			Write-Host "$BackupId; imported GPO into $Adjective GPO with '$($GPO.Id)' GUID and display name: $DisplayName"
		}
	}
}

End {
	# if TemporaryFolder created...
	If ($script:TemporaryFolder) {
		# remove temporary folder and all child items
		Try {
			Remove-Item -Path $TemporaryFolder -Recurse -Force
		}
		Catch {
			Return $_
		}
	}
}
