<#
.SYNOPSIS
Retrieves a credential protected by CMS.

.DESCRIPTION
Retrieves a credential encrypted by a CMS certificate. The calling user must have read access to the private key of the certificate that protects the credential.

.PARAMETER Privilege
Specifies the privilege to grant to the process. Must be a valid security privilege.

.PARAMETER ProcessId
Specifies the process ID to grant the privilege. The default value is the current process ID.

.PARAMETER Switch
Switch parameter to disable the privilege.

.INPUTS
None.

.OUTPUTS
Boolean

.EXAMPLE
PS> .\Set-TokenPrivilege.ps1 -Privilege SeBackupPrivilege

.LINK
https://learn.microsoft.com/en-us/windows/win32/secauthz/privilege-constants

.LINK
https://www.leeholmes.com/adjusting-token-privileges-in-powershell/

.LINK
https://github.com/gtworek/PSBits/blob/master/Misc/EnableSeBackupPrivilege.ps1

.LINK
https://github.com/gtworek/PSBits/blob/master/Misc/EnableSeRestorePrivilege.ps1
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param (
	[Parameter(Position = 0, Mandatory = $true)][ValidateSet(
		'SeAssignPrimaryTokenPrivilege', 'SeAuditPrivilege', 'SeBackupPrivilege', 'SeChangeNotifyPrivilege', 'SeCreateGlobalPrivilege',
		'SeCreatePagefilePrivilege', 'SeCreatePermanentPrivilege', 'SeCreateSymbolicLinkPrivilege', 'SeCreateTokenPrivilege',
		'SeDebugPrivilege', 'SeEnableDelegationPrivilege', 'SeImpersonatePrivilege', 'SeIncreaseBasePriorityPrivilege',
		'SeIncreaseQuotaPrivilege', 'SeIncreaseWorkingSetPrivilege', 'SeLoadDriverPrivilege', 'SeLockMemoryPrivilege',
		'SeMachineAccountPrivilege', 'SeManageVolumePrivilege', 'SeProfileSingleProcessPrivilege', 'SeRelabelPrivilege',
		'SeRemoteShutdownPrivilege', 'SeRestorePrivilege', 'SeSecurityPrivilege', 'SeShutdownPrivilege', 'SeSyncAgentPrivilege',
		'SeSystemEnvironmentPrivilege', 'SeSystemProfilePrivilege', 'SeSystemtimePrivilege', 'SeTakeOwnershipPrivilege',
		'SeTcbPrivilege', 'SeTimeZonePrivilege', 'SeTrustedCredManAccessPrivilege', 'SeUndockPrivilege', 'SeUnsolicitedInputPrivilege'
	)]
	[string]$Privilege,
	[Parameter(Position = 1)]
	[int32]$ProcessId = ([System.Diagnostics.Process]::GetCurrentProcess().Id),
	[Parameter(Position = 2)]
	[switch]$Disable
)

$TypeDefinition = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct TokenPrivileges
{
	public int PrivilegeCount;
	public long Luid;
	public int Attributes;
}

public static class Advapi32
{
	[DllImport("advapi32.dll", SetLastError = true)]
	public static extern bool OpenProcessToken(
		IntPtr ProcessHandle, 
		int DesiredAccess,
		ref IntPtr TokenHandle
	);

	[DllImport("advapi32.dll", SetLastError = true)]
	public static extern bool LookupPrivilegeValue(
		string SystemName,
		string Name,
		ref long Luid
	);

	[DllImport("advapi32.dll", SetLastError = true)]
	public static extern bool AdjustTokenPrivileges(
		IntPtr TokenHandle,
		bool DisableAllPrivileges,
		ref TokenPrivileges NewState,
		int BufferLength,
		IntPtr PreviousState,
		IntPtr ReturnLength
	);
}

public static class Kernel32
{
	[DllImport("kernel32.dll")]
	public static extern uint GetLastError();
}
'@

# TODO: add Start-Job
# ForEach ($UniquePrivilege in $Privilege) {
# 	# define parameters 
# 	$InputObject = @{
# 		Privilege = $UniquePrivilege
# 		ProcessId = $ProcessId
# 		Disable   = $Disable
# 	}
#	# utilize job to avoid loading type defintions directly into session
# 	Start-Job -InputObject $InputObject -ScriptBlock {
# 		# Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
# 		# rest of script
# 	} | Receive-Job -Wait -AutoRemoveJob
# }

# add type
Try {
	$null = [advapi32]
}
Catch {
	Try {
		Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
	}
	Catch {
		Throw $_
	}
}

# define arguments for OpenProcessToken
$ProcessHandle = Get-Process -Id $ProcessId | Select-Object -ExpandProperty Handle
$DesiredAccess = 0x28 # TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
$TokenHandle = [IntPtr]::Zero

# open process token
# reference: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
Write-Debug "Calling OpenProcessToken for process handle: $Handle"
Try {
	$CallResult = [Advapi32]::OpenProcessToken($ProcessHandle, $DesiredAccess, [ref]$TokenHandle)
}
Catch {
	Throw $_
}

# report results
If ($CallResult) {
	Write-Debug "Token handle: $TokenHandle"
}
Else {
	$LastError = [Kernel32]::GetLastError()
	Write-Debug "GetLastError returned: $LastError"
	Return
}

# define arguments for LookupPrivilegeValue
$SystemName = $null
$Luid = $null

# lookup privilege LUID
# reference: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupprivilegevaluew
Write-Debug "Calling LookupPrivilegeValue for privilege: $Privilege"
Try {
	$CallResult = [Advapi32]::LookupPrivilegeValue($SystemName, $Privilege, [ref]$Luid)
}
Catch {
	Throw $_
}

# report results
If ($CallResult) {
	Write-Debug "LUID for '$Privilege' privilege: $Luid"
}
Else {
	$LastError = [Kernel32]::GetLastError()
	Write-Debug "GetLastError returned: $LastError"
	Return
}

# create TokenPrivileges container
# reference: https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-token_privileges
$TokenPrivileges = [TokenPrivileges]::new()
$TokenPrivileges.PrivilegeCount = 1
$TokenPrivileges.Luid = $Luid

# if Disable is set...
If ($Disable) {
	# ...set privilege will be disabled
	$TokenPrivileges.Attributes = 0x00000000 # SE_PRIVILEGE_DISABLED
}
Else {
	# ...set privilege will be enabled
	$TokenPrivileges.Attributes = 0x00000002 # SE_PRIVILEGE_ENABLED
}

# define arguments for AdjustTokenPrivileges
$DisableAllPrivileges = $false
$BufferLength = 0
$PreviousState = [IntPtr]::Zero
$ReturnLength = [IntPtr]::Zero

# adjust token privileges
# reference: https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges
Write-Debug "Calling AdjustTokenPrivileges for token handle: $TokenHandle"
Try {
	$CallResult = [Advapi32]::AdjustTokenPrivileges($TokenHandle, $DisableAllPrivileges, [ref]$TokenPrivileges, $BufferLength, $PreviousState, $ReturnLength)
}
Catch {
	Throw $_
}

# report results
If ($CallResult) {
	Write-Debug "Updated privileges for token handle: $TokenHandle"
}
Else {
	$LastError = [Kernel32]::GetLastError()
	Write-Debug "GetLastError returned: $LastError"
	Return
}

#0 - OK.
#6 - one of previous steps failed. Observe the output for handles equal to 0 or just re-run entire script.
#1300 - privilege not held
