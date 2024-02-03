<#
.SYNOPSIS
Retrieves the Scheduled Tasks defined in a GPO as an XML object.

.DESCRIPTION
Retrieves the Scheduled Tasks defined in a GPO as an XML object.

.PARAMETER GPO
A reference to the GPO. Must be a GPO object from Get-GPO, the GUID of a GPO, or the name of a GPO.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Get-ScheduledTaskXmlFromGpo.ps1 -GPO $GPO

.EXAMPLE
.\Get-ScheduledTaskXmlFromGpo.ps1 -GPO 'Scheduled Tasks GPO'

.EXAMPLE
.\Get-ScheduledTaskXmlFromGpo.ps1 -GPO 00000000-0000-0000-0000-000000000000
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object]$GPO,
	[Parameter()]
	[switch]$Text,
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

Begin {
	# if input object is not a GPO...
	If ($GPO -isnot [Microssoft.Gpo]) {
		# ...and input object is a GUID...
		If ($GPO -is [guid] -or [guid]::TryParse($GPO, [ref][guid]::Empty)) {
			# ...get GPO by GUID
			Try {
				$GPO = Get-GPO -Guid $GPO
			}
			Catch {
				Throw $_
			}
		}
		# ...and input object is not a GUID...
		Else {
			# ...get GPO by Name
			Try {
				$GPO = Get-GPO -Name $GPO
			}
			Catch {
				Throw $_
			}
		}
	}
}

Process {
	# define GPO path
	$Path = "\\$Server\SYSVOL\$Domain\Policies\{$($GPO.Id)}"

	# test path
	If (!(Test-Path -Path $Path -PathType Container)) {
		Write-Warning "GPO SYSVOL path not found: $Path"
		Return
	}

	# define scheduled tasks path
	$Path = Join-Path -Path $Path -ChildPath "Machine\Preferences\ScheduledTasks\ScheduledTasks.xml"

	# test path
	If (!(Test-Path -Path $Path -PathType Leaf)) {
		Write-Warning "could not find GPO Scheduled Tasks file: $Path"
		Return
	}

	# create XML object
	$Xml = [System.Xml.XmlDocument]::new()

	# load GPO scheduled task file into XML object
	Try {
		$Xml.Load($Path)
	}
	Catch {
		Write-Warning "could not populate XML object from path: $Path"
		Return $_
	}

	# return XML
	If ($Text) {
		$Xml.Save([System.Console]::Out)
	}
	Else {
		Return $Xml
	}
}
