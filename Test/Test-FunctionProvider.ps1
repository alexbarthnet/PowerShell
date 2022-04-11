[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]$ComputerName
)

Function Invoke-CimInstanceFunction {
	[CmdletBinding()]
	param (
		[Parameter()]
		[string]$CimClassName
	)
	Get-CimInstanceFunction -CimClassName $CimClassName
}
Function Get-CimInstanceFunction {
	[CmdletBinding()]
	param (
		[Parameter()]
		[string]$CimClassName
	)
	Get-CimInstance -ClassName $CimClassName | Format-List
}


# define objects
$RemoteFunction1 = "function Get-CimInstanceFunction {${function:Get-CimInstanceFunction}}"
$RemoteFunction2 = "function Invoke-CimInstanceFunction {${function:Invoke-CimInstanceFunction}}"
$RemoteParameters = @{
	CimClassName = 'Win32_ComputerSystem'
}

# try to run function
Try {
	Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		. ([ScriptBlock]::Create($using:RemoteFunction1))
		. ([ScriptBlock]::Create($using:RemoteFunction2))
		Invoke-CimInstanceFunction @using:RemoteParameters
	}
}
Catch {
	Write-Host "ERROR: could not retrieve CIM instance on '$ComputerName'"
	$_
}
