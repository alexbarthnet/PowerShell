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
	[string]$DomainNBName = [System.DirectoryServices.DirectorySearcher]::new("LDAP://$PartitionsDN", "(nCName=$DomainNCName)", 'CN', 'OneLevel').FindAll().Properties['CN']
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
		$Content = Get-Content -Path $Path -Raw
	}
	Catch {
		Return $_
	}

	# replace NetBIOS domain name with NetBIOS domain name
	$Content = $Content.Replace("[CDATA[$DomainNBName]]", '[CDATA[LOCAL]]')

	# replace domain controller with generic domain controller
	$Content = $Content.Replace("\\$Server", '\\DC-1.domain.local')

	# replace domain name with generic domain name
	$Content = $Content.Replace("$Domain", 'domain.local')

	# update content of XML file
	Try {
		$Content | Set-Content -Path $Path -Encoding UTF8 -NoNewline
	}
	Catch {
		Return $_
	}

	# report state
	Write-Host "$Guid; generalized XML file: $Path"
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
	# report state
	Write-Verbose -Message 'Reset requested; emptying folder...'

	# create path
	Try {
		Get-ChildItem -Path $Path | Remove-Item -Recurse -Force
	}
	Catch {
		Return $_
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

	# if generalize requested...
	If ($Generalize) {
		# define path to GPO backup
		$BackupPath = Join-Path -Path $Path -ChildPath "{$($Backup.Id)}"

		# define GPO backup XML files
		$ChildPaths = @('Backup.xml', 'bkupInfo.xml', 'gpreport.xml')

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
	}
}

# if generalize requested...
If ($Generalize) {
	# define path for XML file
	$PathToXmlFile = Join-Path -Path $Path -ChildPath 'manifest.xml'

	# retrieve content of XML file
	Try {
		ConvertTo-GenericGroupPolicyXmlFile -Path $PathToXmlFile
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
		Compress-Archive -Path $PathForArchive -DestinationPath $Destination -Force
	}
	Catch {
		Return $_
	}
}
