[CmdletBinding(SupportsShouldProcess)]
Param(
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$Filter
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

# retrieve backup xml files...
Try {
    $BackupXmlFiles = Get-ChildItem -Path $Path -Include 'Backup.xml' -Recurse -ErrorAction 'Stop' | Where-Object { $_.Parent.FullName -eq $Path.FullName }
}
Catch {
    Write-Warning -Message "could not retrieve 'Backup.xml' files from path: $Path"
    Return $_
}

# report count of backup XML files
Write-Verbose -Message "found backup XML files: $($BackupXmlFiles.Count)"

# define hashtable for GPO IDs
$GpoIdHashtable = @{}

# loop through each backup xml file
:NextBackupXmlFile ForEach ($BackupXmlFile in $BackupXmlFiles) {
    # define XML document
    $Xml = [System.Xml.XmlDocument]::new()

    # load backup XML file into XML document
    Try {
        $Xml.Load($BackupXmlFile)
    }
    Catch {
        Write-Warning -Message "could not load XML document from existing file: $($BackupXmlFile.FullName)"
        Return $_
    }

    # get GPO GUID from XML document
    $Guid = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.ID.InnerText

    # get GPO name from XML document
    $TargetName = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.DisplayName.InnerText

    # create hashtable for GPO backup
    $GpoBackupHashtable = @{
        LastWriteTime = $BackupXmlFile.LastWriteTime
        BackupId      = $BackupXmlFile.Name
        TargetName    = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.GroupPolicyCoreSettings.DisplayName.InnerText
    }

    # if GPO GUID found in GPO IDs hashtable...
    If ($GpoIdHashtable.ContainsKey($Guid)) {
        # if LastWriteTime of existing hashtable value is newer than current GPO backup LastWriteTime...
        If ($GpoIdHashtable[$Guid].LastWriteTime -ge $GpoBackupHashtable.LastWriteTime) {
            Continue NextBackupXmlFile
        }
    }

    # add GPO GUID to hashtable with value 
    $GpoIdHashtable[$Guid] = $GpoBackupHashtable
}

# report count of backup XML files
Write-Verbose -Message "found unqiue GPOs in backup XML files: $($GpoIdHashtable.Keys.Count)"

ForEach ($GpoId in $GpoIdHashtable.Keys) {
    # retrieve values from hashtable
    $BackupId = $GpoIdHashtable[$GpoId].BackupId
    $TargetName = $GpoIdHashtable[$GpoId].TargetName

    # import GPO
    Try {
        Import-GPO -BackupId $BackupId -Path $Path -TargetName $TargetName -CreateIfNeeded -WhatIf:$WhatIfPreference
    }
    Catch {
        Write-Warning -Message "could not import GPO with '$BackupId' backup ID to GPO with name: $TargetName"
        Return $_
    }
}