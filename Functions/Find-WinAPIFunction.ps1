Function Find-WinAPIFunction {
	<#
	.SYNOPSIS
	Searches all loaded assemblies in your PowerShell session for a Windows API function.

	.PARAMETER Module
	Specifies the name of the module that implements the function. This is typically a system dll (e.g. kernel32.dll).

	.PARAMETER FunctionName
	Specifies the name of the function you’re searching for.

	.OUTPUTS
	[System.Reflection.MethodInfo]

	.EXAMPLE
	Find-WinAPIFunction kernel32.dll CopyFile
	#>

	[CmdletBinding()][OutputType([System.Reflection.MethodInfo])]
	Param (
		[Parameter(Mandatory = $True, Position = 0)] [ValidateNotNullOrEmpty()]
		[String]$Module,
		[Parameter(Mandatory = $True, Position = 1)][ValidateNotNullOrEmpty()]
		[String]$FunctionName
	)

	ForEach ($Assembly in ([System.AppDomain]::CurrentDomain.GetAssemblies())) {
		ForEach ($Type in $Assembly.GetTypes()) {
			ForEach ($Method in $Type.GetMethods('NonPublic, Public, Static')) {
				ForEach ($CustomAttribute in $Method.GetCustomAttributes($false)) {
					If ($Method.Name.ToLower() -eq $FunctionName.ToLower() -and $CustomAttribute.Value -eq $Module) {
						$Method
					}
				}
			}
		}
	} 
}
