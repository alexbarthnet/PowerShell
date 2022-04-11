[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$ComputerName
)

Function Get-CimInstanceFunction {
	[CmdletBinding()]
	param (
		[Parameter()]
		[string]$CimClassName
	)
	Get-CimInstance -ClassName $CimClassName | Format-List
}

# define objects
$RemoteFunction = "function Get-CimInstanceFunction {${function:Get-CimInstanceFunction}}"
$RemoteParameters = @{
	CimClassName = 'Win32_ComputerSystem'
}

# try to run function
Try {
	Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		. ([ScriptBlock]::Create($using:RemoteFunction))
		Get-CimInstanceFunction @using:RemoteParameters
	}
}
Catch {
	Write-Host "ERROR: could not retrieve CIM instance on '$ComputerName'"
	$_
}
