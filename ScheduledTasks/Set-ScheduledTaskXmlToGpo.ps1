<#
.SYNOPSIS
Updates the Scheduled Tasks defined in a GPO from an XML object.

.DESCRIPTION
Updates the Scheduled Tasks defined in a GPO from an XML object.

.PARAMETER GPO
A reference to the GPO. Must be a GPO object from Get-GPO, the GUID of a GPO, or the name of a GPO.

.PARAMETER XML
The XML object, the GPO GUID, or the GPO name.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Set-ScheduledTaskXmlFromGpo.ps1 -GPO $GPO -Xml $Xml

.EXAMPLE
.\Set-ScheduledTaskXmlFromGpo.ps1 -GPO 'Scheduled Tasks GPO'  -Xml $Xml

.EXAMPLE
.\Set-ScheduledTaskXmlFromGpo.ps1 -GPO 00000000-0000-0000-0000-000000000000 -Xml $Xml
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object]$Gpo,
	[Parameter(Mandatory = $true)]
	[object]$Xml,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

Begin {
	# if GPO parameter is not a GPO...
	If ($Gpo -isnot [Microssoft.Gpo]) {
		# ...and input object is a GUID...
		If ($Gpo -is [guid] -or [guid]::TryParse($Gpo, [ref][guid]::Empty)) {
			# ...get GPO by GUID
			Try {
				$Gpo = Get-GPO -Guid $Gpo
			}
			Catch {
				Throw $_
			}
		}
		# ...and input object is not a GUID...
		Else {
			# ...get GPO by Name
			Try {
				$Gpo = Get-GPO -Name $Gpo
			}
			Catch {
				Throw $_
			}
		}
	}

	# if XML parameter is not an XML object...
	If ($Xml -isnot [System.Xml.XmlDocument]) {
		Try {
			$Xml = [xml]$Xml
		}
		Catch {
			Throw $_
		}
	}

}

Process {
	# define GPO path
	$Path = "\\$Server\SYSVOL\$Domain\Policies\{$($Gpo.Id)}"

	# test path
	If (!(Test-Path -Path $Path -PathType Container)) {
		Write-Warning "GPO SYSVOL path not found: $Path"
		Return
	}

	# define scheduled tasks path
	$Path = Join-Path -Path $Path -ChildPath "Machine\Preferences\ScheduledTasks\ScheduledTasks.xml"

	# load GPO scheduled task into XML
	Try {
		$Xml.Save($Path)
	}
	Catch {
		Return $_
	}
}
