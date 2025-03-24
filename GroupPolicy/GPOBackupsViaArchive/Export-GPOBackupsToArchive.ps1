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
	[switch]$Generalize,
	[Parameter(Position = 7)]
	[switch]$Minimize,
	[Parameter(Position = 8)]
	[switch]$Force,
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
	[string]$GenericServer = 'DC-1.domain.local',
	[Parameter(DontShow)]
	[string]$GenericDomain = 'domain.local',
	[Parameter(DontShow)]
	[string]$GenericDomainNBName = 'LOCAL'
)

Begin {
	Function ConvertTo-GenericGroupPolicyPolFile {
		Param(
			[Parameter(Mandatory)]
			$Path,
			$Guid = [System.Guid]::Empty
		)

		# retrieve content of XML file
		Try {
			$Text = [System.IO.File]::ReadAllText($Path)
		}
		Catch {
			Return $_
		}

		# replace domain controller with generic domain controller
		$Text = $Text.Replace($ExpandedServer, $ExpandedGenericServer)

		# replace expanded domain name with generic expanded domain name
		$Text = $Text.Replace($ExpandedDomain, $ExpandedGenericDomain)

		# update content of XML file
		Try {
			[System.IO.File]::WriteAllText($Path, $Text, [System.Text.Encoding]::ASCII)
		}
		Catch {
			Return $_
		}

		# report state
		Write-Host "$Guid; generalized POL file: $Path"
	}

	Function ConvertTo-GenericGroupPolicyXmlFile {
		Param(
			[Parameter(Mandatory)]
			$Path,
			$Guid = [System.Guid]::Empty
		)

		# retrieve content of XML file
		Try {
			$Text = [System.IO.File]::ReadAllText($Path)
		}
		Catch {
			Return $_
		}

		# replace bracketed NetBIOS domain name with bracketed generic NetBIOS domain name
		$Text = $Text.Replace("[CDATA[$DomainNBName]]", "[CDATA[$GenericDomainNBName]]")

		# replace suffixed NetBIOS domain name with suffixed generic NetBIOS domain name
		$Text = $Text.Replace("$DomainNBName\", "$GenericDomainNBName\")

		# replace domain controller with generic domain controller
		$Text = $Text.Replace($Server, $GenericServer)

		# replace DNS domain name with generic DNS domain name
		$Text = $Text.Replace($Domain, $GenericDomain)

		# update content of XML file
		Try {
			[System.IO.File]::WriteAllText($Path, $Text)
		}
		Catch {
			Return $_
		}

		# report state
		Write-Host "$Guid; generalized XML file: $Path"
	}

	Function Clear-HiddenFileAttribute {
		Param(
			[Parameter(Mandatory)]
			[string]$Path
		)

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
		}

		# retrieve file attributes
		$Attributes = [System.IO.File]::GetAttributes($Path)

		# if file is not hidden...
		If (($Attributes -band [System.IO.FileAttributes]::Hidden) -ne [System.IO.FileAttributes]::Hidden) {
			Return
		}

		# remove hidden attribute from file attributes
		$Attributes = $Attributes -bxor [System.IO.FileAttributes]::Hidden

		# set file attributes
		Try {
			[System.IO.File]::SetAttributes($Path, $Attributes)
		}
		Catch {
			Write-Warning -Message "could not clear Hidden attribute on file: $Path"
			Return $_
		}
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

	# if generalize requested...
	If ($Generalize) {
		# define expanded strings for .pol files
		$ExpandedServer = [System.String]::Join(' ', [System.Char[]]$Server)
		$ExpandedDomain = [System.String]::Join(' ', [System.Char[]]$Domain)
		$ExpandedGenericServer = [System.String]::Join(' ', [System.Char[]]$GenericServer)
		$ExpandedGenericDomain = [System.String]::Join(' ', [System.Char[]]$GenericDomain)
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
				Get-ChildItem -Path $StagingPath -Force -Recurse | Remove-Item -Force
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

	# if Path is an existing directory...
	If ([System.IO.Directory]::Exists($Path)) {
		# warn and return
		Write-Warning -Message 'The provided Path is an existing folder. Provide a Path that is not an existing folder.'
		Return
	}

	# if Path is an existing file...
	If ([System.IO.File]::Exists($Path)) {
		# if Force provided...
		If ($Force) {
			Write-Warning -Message 'The provided Path is an existing file. Overwriting existing file' -WarningAction Continue
		}
		Else {
			# warn and inquire
			Write-Warning -Message 'The provided Path is an existing file. Continue to overwrite existing file' -WarningAction Inquire
		}
	}

	# retrieve all GPOs
	Try {
		$GPOs = Get-GPO -Server $Server -All
	}
	Catch {
		Return $_
	}

	# loop through GPOs
	:NextGPO ForEach ($GPO in $GPOs) {
		# create objects for GPO properties
		$DisplayName = $GPO.DisplayName
		$Guid = $GPO.Id

		# if include defined...
		If ($PSBoundParameters.ContainsKey('Include')) {
			# declare include match not found
			$IncludeNotFound = $true

			# loop through include strings...
			ForEach ($IncludeString in $Include) {
				# if GPO display name matches include string...
				If ($GPO.DisplayName -like $IncludeString) {
					# update boolean to false
					$IncludeNotFound = $false
				}
			}

			# if include not found...
			If ($IncludeNotFound) {
				Write-Host "$Guid; skipping GPO: display name of '$DisplayName' does not match one of the provided Include strings: '$($Include.Join(', '))'"
				Continue NextGPO
			}
		}

		# if exclude defined...
		If ($PSBoundParameters.ContainsKey('Exclude')) {
			# loop through exclude strings...
			ForEach ($ExcludeString in $Exclude) {
				# if GPO display name matches exclude string...
				If ($GPO.DisplayName -like $ExcludeString) {
					Write-Host "$Guid; skipping GPO: display name of '$DisplayName' matches Exclude string: '$ExcludeString'"
					Continue NextGPO
				}
			}
		}

		# backup GPO to path
		Try {
			$Backup = Backup-GPO -Server $Server -Guid $Guid -Path $StagingPath
		}
		Catch {
			Return $_
		}

		# report state
		Write-Host "$Guid; exported GPO: $DisplayName"

		# define path to GPO backup
		$BackupPath = Join-Path -Path $StagingPath -ChildPath "{$($Backup.Id)}"

		# get hidden files in GPO backup path
		$HiddenFiles = Get-ChildItem -Path $BackupPath -Hidden -File -Recurse

		# loop through hidden files
		ForEach ($HiddenFile in $HiddenFiles) {
			# clear the hidden attribute on hidden file
			Try {
				Clear-HiddenFileAttribute -Path $HiddenFile.FullName
			}
			Catch {
				Return $_
			}
		}

		# if minimum requested...
		If ($Minimize) {
			# define path to report file
			$PathToReportFile = Join-Path -Path $BackupPath -ChildPath 'gpreport.xml'

			# remove the report file
			Try {
				Remove-Item -Path $PathToReportFile -Force
			}
			Catch {
				Return $_
			}
		}

		# if generalize requested...
		If ($Generalize) {
			# define GPO backup XML files
			$XMLFilePaths = @('Backup.xml', 'bkupInfo.xml', 'DomainSysvol\GPO\Machine\Preferences\Groups\Groups.xml')

			# loop through GPO backup XML files
			ForEach ($ChildPath in $XMLFilePaths) {
				# define path for GPO backup XML file
				$PathToXmlFile = Join-Path -Path $BackupPath -ChildPath $ChildPath

				# if XML file exists...
				If ([System.IO.File]::Exists($PathToXmlFile)) {
					# generalize XML file
					Try {
						ConvertTo-GenericGroupPolicyXmlFile -Path $PathToXmlFile -Guid $Guid
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
				$PathToPolFile = Join-Path -Path $BackupPath -ChildPath $ChildPath

				# if POL file exists...
				If ([System.IO.File]::Exists($PathToPolFile)) {
					# generalize POL file
					Try {
						ConvertTo-GenericGroupPolicyPolFile -Path $PathToPolFile -Guid $Guid
					}
					Catch {
						Return $_
					}
				}
			}
		}
	}

	# define path to manifest file
	$PathToManifestFile = Join-Path -Path $StagingPath -ChildPath 'manifest.xml'

	# clear the hidden attribute on manifest file
	Try {
		Clear-HiddenFileAttribute -Path $PathToManifestFile
	}
	Catch {
		Return $_
	}

	# if generalize requested...
	If ($Generalize) {
		# generalize manifest file
		Try {
			ConvertTo-GenericGroupPolicyXmlFile -Path $PathToManifestFile
		}
		Catch {
			Return $_
		}
	}

	# create archive of GPO backups
	Try {
		Get-ChildItem -Path $StagingPath -Force | Compress-Archive -DestinationPath $Path -Force
	}
	Catch {
		Return $_
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
