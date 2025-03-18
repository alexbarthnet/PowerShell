[CmdletBinding(SupportsShouldProcess)]
Param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [string]$DestinationPath,
    [Parameter(DontShow)]
    [string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
    [Parameter(DontShow)]
    [string[]]$DomainControllers = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers.Name,
    [Parameter(DontShow)]
    [string[]]$FileNamesToRemove = @(
        'bkupInfo.xml'
        'gpreport.xml'
    ), 
    [Parameter(DontShow)]
    [string[]]$GroupsToPreserve = @(
        'Domain Admins'
        'Enterprise Admins'
    )
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

# remove manifet file
$FileToRemove = Join-Path -Path $Path -ChildPath 'manifest.xml'

# if manifest file exists...
If ([System.IO.File]::Exists($FileToRemove)) {
    Try {
        Remove-Item -Path $FileToRemove -Confirm:$false -WhatIf:$WhatIfPreference
    }
    Catch {
        Write-Warning -Message "could not remove file: $FileToRemove"
        Return $_
    }
}

# retrieve GPO backup folders...
Try {
    $GPOBackupFolders = Get-ChildItem -Directory -Path $Path -ErrorAction 'Stop' | Select-Object -ExpandProperty FullName
}
Catch {
    Write-Warning -Message "could not retrieve 'Backup.xml' files from path: $Path"
    Return $_
}

# report count of GPO backup folders
Write-Verbose -Message "found GPO backup folders: $($GPOBackupFolders.Count)"

# loop through each GPO backup folders - remove files
:NextGPOBackupFolder ForEach ($GPOBackupFolder in $GPOBackupFolders) {
    # retrieve files to remove
    Try {
        $FilesToRemove = Get-ChildItem -Path $GPOBackupFolder | Where-Object { $_.Name -in $FileNamesToRemove } | Select-Object -ExpandProperty FullName
    }
    Catch {
        Write-Warning -Message "could not retrieve 'Backup.xml' files from path: $Path"
        Return $_
    }

    # loop through files to remove
    ForEach ($FileToRemove in $FilesToRemove) {
        # remove file
        Try {
            Remove-Item -Path $FileToRemove -Confirm:$false -WhatIf:$WhatIfPreference
        }
        Catch {
            Write-Warning -Message "could not remove file: $FileToRemove"
            Return $_
        }
    }
}

# loop through each GPO backup folders - replace text
:NextGPOBackupFolder ForEach ($GPOBackupFolder in $GPOBackupFolders) {
    # define backup XML file
    $BackupXmlPath = Join-Path -Path $GPOBackupFolder -ChildPath 'Backup.xml'

    # retrieve original content of backup XML file
    Try {
        $Content = Get-Content -Path $BackupXmlPath -Raw
    }
    Catch {
        Write-Warning -Message "could not retrieve content of XML file: $BackupXmlPath"
        Return $_
    }

    # loop through domain controllers
    ForEach ($DomainController in $DomainControllers) {
        # replace domain controller with generic domain controller
        $Content = $Content.Replace($DomainController, 'dc.domain.local')
    }

    # replace domain name with generic domain name
    $Content = $Content.Replace($Domain, 'domain.local')

    # # retrieve original content of backup XML file
    # Try {
    #     $Content | Set-Content -Path $BackupXmlPath
    # }
    # Catch {
    #     Write-Warning -Message "could not save XML document from existing file: $($BackupXmlPath.FullName)"
    #     Return $_
    # }
# }

# # loop through each GPO backup folders - update XML
# :NextGPOBackupFolder ForEach ($GPOBackupFolder in $GPOBackupFolders) {
#     # define backup XML file
#     $BackupXmlPath = Join-Path -Path $GPOBackupFolder -ChildPath 'Backup.xml'

#     # define XML document
#     $Xml = [System.Xml.XmlDocument]::new()

    # load backup XML file into XML document
    # load updated content into XML document
    Try {
        $Xml.LoadXml($Content)
        # $Xml.Load($BackupXmlPath)
    }
    Catch {
        Write-Warning -Message "could not load XML document from existing file: $($BackupXmlPath.FullName)"
        Return $_
    }

    # retrieve group nodes that are not default values
    $Nodes = $Xml.GroupPolicyBackupScheme.GroupPolicyObject.SecurityGroups.Group | Where-Object { $_.SamAccountName.'#cdata-section' -notin $GroupsToPreserve }

    # loop through nodes
    ForEach ($Node in $Nodes) {
        $Xml.GroupPolicyBackupScheme.GroupPolicyObject.SecurityGroups.RemoveChild($Node)
    }

    # save XML document to backup XML file 
    Try {
        $Xml.Save($BackupXmlPath)
    }
    Catch {
        Write-Warning -Message "could not load XML document from existing file: $($BackupXmlPath.FullName)"
        Return $_
    }

    # report state
    Write-Verbose -Message "updated XML file: $BackupXmlPath"
}

# create archive
Get-ChildItem -Path $Path | Compress-Archive -DestinationPath $DestinationPath
