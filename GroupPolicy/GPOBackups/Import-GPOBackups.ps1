[CmdletBinding(SupportsShouldProcess)]
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

	# report absolute path
	Write-Warning -Message "converted relative path in provided Path parameter to absolute path: $Path"
}

# if path does not exists...
If (![System.IO.Directory]::Exists($Path)) {
	# report state
	Write-Verbose -Message 'Path not found; creating...'

}

# retrieve GPO backups...
Try {
	$GPOBackups = Get-ChildItem -Path $Path -Directory -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not retrieve directories in path: $Path"
	Return $_
}

# report count of GPO backups
Write-Verbose -Message "found GPO backup folders: $($GPOBackups.Count)"

# loop through GPO backups
:NextGPOBackup ForEach ($GPOBackup in $GPOBackups) {
	# define backup id from folder name
	$BackupId = $GPOBackup.Name

	# if GPO backup is not a GUID...
	If (![System.Guid]::TryParse($BackupId, [ref][System.Guid]::Empty)) {
		# report state and continue to next GPO backup
		Write-Warning -Message "found directory that does not parse as a GUID: $BackupId"
		Continue NextGPOBackup
	}

	# define XML file for GPO backup
	$BackupXml = Join-Path -Path $GPOBackup.FullName -ChildPath 'Backup.xml'

	# if XML file not found...
	If (![System.IO.File]::Exists($BackupXml)) {
		# report state and continue to next GPO backup
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

	# get GPO GUID from XML document
	$TargetGuid = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.ID.InnerText

	# if GPO GUID is empty...
	If ([System.String]::IsNullOrEmpty($TargetGuid)) {
		# report state and continue to next GPO backup
		Write-Warning -Message "could not locate GUID for GPO in XML file at path: $BackupXml"
		Continue NextGPOBackup
	}

	# get GPO name from XML document
	$TargetName = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.DisplayName.InnerText

	# if GPO name is empty...
	If ([System.String]::IsNullOrEmpty($TargetName)) {
		# report state and continue to next GPO backup
		Write-Warning -Message "could not locate name for GPO in XML file at path: $BackupXml"
		Continue NextGPOBackup
	}

	# import GPO
	Try {
		$GPO = Import-GPO -BackupId $BackupId -Path $Path -TargetGuid $TargetGuid -TargetName $TargetName -CreateIfNeeded -WhatIf:$WhatIfPreference
	}
	Catch {
		Write-Warning -Message "could not import GPO with '$BackupId' backup ID to GPO with name: $TargetName"
		Return $_
	}

	# create objects for GPO properties
	$DisplayName = $GPO.DisplayName
	$Guid = $GPO.Id

	# report state
	Write-Host "$Guid; imported GPO: $DisplayName"
}
