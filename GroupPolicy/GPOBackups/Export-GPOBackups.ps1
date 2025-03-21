[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Mandatory)]
	[string]$Path,
	[Parameter()]
	[string]$Destination,
	[Parameter()]
	[switch]$Reset,
	[Parameter()]
	[switch]$Generalize,
	[Parameter()]
	[switch]$Minimize,
	[Parameter()]
	[string[]]$Include,
	[Parameter()]
	[string[]]$Exclude,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name,
	[Parameter(DontShow)]
	[string]$PartitionsDN = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Schema.Name.Replace('CN=Schema', 'CN=Partitions'),
	[Parameter(DontShow)]
	[string]$DomainNCName = [System.DirectorySErvices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(DontShow)]
	[string]$DomainNBName = [System.DirectoryServices.DirectorySearcher]::new("LDAP://$PartitionsDN", "(nCName=$DomainNCName)", 'CN', 'OneLevel').FindAll().Properties['CN'],
	[Parameter(DontShow)]
	[string]$GenericServer = 'DC-1.domain.local',
	[Parameter(DontShow)]
	[string]$GenericDomain = 'domain.local',
	[Parameter(DontShow)]
	[string]$GenericDomainNBName = 'LOCAL',
	[Parameter(DontShow)]
	[string]$ExpandedServer = [System.String]::Join(' ', [System.Char[]]$Server),
	[Parameter(DontShow)]
	[string]$ExpandedDomain = [System.String]::Join(' ', [System.Char[]]$Domain),
	[Parameter(DontShow)]
	[string]$ExpandedGenericServer = [System.String]::Join(' ', [System.Char[]]$GenericServer),
	[Parameter(DontShow)]
	[string]$ExpandedGenericDomain = [System.String]::Join(' ', [System.Char[]]$GenericDomain)
)

# define function for generalizing GPO XML file
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

	# replace NetBIOS domain name with NetBIOS domain name
	$Text = $Text.Replace("[CDATA[$DomainNBName]]", "[CDATA[$GenericDomainNBName]]")

	# replace domain controller with generic domain controller
	$Text = $Text.Replace($Server, $GenericServer)

	# replace domain name with generic domain name
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
		$Path
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

# define function for generalizing GPO POL file
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
		[System.IO.File]::WriteAllText($Path, $Text)
	}
	Catch {
		Return $_
	}

	# report state
	Write-Host "$Guid; generalized POL file: $Path"
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

# if Destination is not an absolute path...
If (![System.IO.Path]::IsPathRooted($Destination)) {
	# get unresolved absolute path
	Try {
		$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
	}
	Catch {
		Write-Warning -Message "could not create absolute path from the provided Path parameter: $Destination"
		Return
	}

	# report absolute path
	Write-Warning -Message "converted relative path in provided Path parameter to absolute path: $Path"
}

# if path does not exists...
If (![System.IO.Directory]::Exists($Path)) {
	# report state
	Write-Verbose -Message 'Path not found; creating...'

	# create path
	Try {
		$null = New-Item -ItemType Directory -Path $Path
	}
	Catch {
		Return $_
	}
}

# if reset requested...
If ($Reset) {
	# remove items in path
	Try {
		Get-ChildItem -Path $Path | Remove-Item -Force -Recurse
	}
	Catch {
		Return $_
	}

	# if destination exists...
	If ([System.IO.File]::Exists($Destination)) {
		# remove destination
		Try {
			Get-Item -Path $Destination | Remove-Item -Force
		}
		Catch {
			Return $_
		}
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

	# export GPO to path
	Try {
		$Backup = Backup-GPO -Server $Server -Guid $Guid -Path $Path
	}
	Catch {
		Return $_
	}

	# report state
	Write-Host "$Guid; exported GPO: $DisplayName"

	# define path to GPO backup
	$BackupPath = Join-Path -Path $Path -ChildPath "{$($Backup.Id)}"

	# define path to backup information file
	$PathToInfoFile = Join-Path -Path $BackupPath -ChildPath 'bkupInfo.xml'

	# clear the hidden attribute on backup information file
	Try {
		Clear-HiddenFileAttribute -Path $PathToInfoFile
	}
	Catch {
		Return $_
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
		$ChildPaths = @('Backup.xml', 'bkupInfo.xml')

		# loop through GPO backup XML files
		ForEach ($ChildPath in $ChildPaths) {
			# define path for GPO backup XML file
			$PathToXmlFile = Join-Path -Path $BackupPath -ChildPath $ChildPath

			# retrieve content of XML file
			Try {
				ConvertTo-GenericGroupPolicyXmlFile -Path $PathToXmlFile -Guid $Guid
			}
			Catch {
				Return $_
			}
		}

		# define GPO backup POL files
		$ChildPaths = @('\DomainSysvol\GPO\Machine\registry.pol', '\DomainSysvol\GPO\User\registry.pol')

		# loop through GPO backup POL files
		ForEach ($ChildPath in $ChildPaths) {
			# define path for GPO backup POL file
			$PathToPolFile = Join-Path -Path $BackupPath -ChildPath $ChildPath

			# if POL file exists...
			If ([System.IO.File]::Exists($PathToPolFile)) {
				# retrieve content of POL file
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
$PathToManifest = Join-Path -Path $Path -ChildPath 'manifest.xml'

# clear the hidden attribute on manifest file
Try {
	Clear-HiddenFileAttribute -Path $PathToManifest
}
Catch {
	Return $_
}

# if generalize requested...
If ($Generalize) {
	# retrieve content of XML file
	Try {
		ConvertTo-GenericGroupPolicyXmlFile -Path $PathToManifest
	}
	Catch {
		Return $_
	}
}

# if destination provided...
If ($PSBoundParameters.ContainsKey('Destination')) {
	# create path for archive
	$PathForArchive = Join-Path -Path $Path -ChildPath '*'

	# compress backups
	Try {
		Get-ChildItem -Path $PathForArchive -Force | Compress-Archive -DestinationPath $Destination -Force
	}
	Catch {
		Return $_
	}
}
