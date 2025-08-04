<#
.SYNOPSIS
Updates the privileges on an existing process.

.DESCRIPTION
Updates the privileges on an existing process. The privilege must already be assigned to the process.

.PARAMETER Privilege
Specifies the privilege to enable on the process. Must be a valid security privilege.

.PARAMETER ProcessId
Specifies the process ID to enable the privilege. The default value is the current process ID.

.PARAMETER Disable
Switch parameter to disable the privilege.

.INPUTS
None.

.OUTPUTS
Boolean

.EXAMPLE
PS> .\Update-TokenPrivilege.ps1 -Privilege SeBackupPrivilege

.LINK
https://learn.microsoft.com/en-us/windows/win32/secauthz/privilege-constants

.LINK
https://www.leeholmes.com/adjusting-token-privileges-in-powershell/

.LINK
https://github.com/gtworek/PSBits/blob/master/Misc/EnableSeBackupPrivilege.ps1

.LINK
https://github.com/gtworek/PSBits/blob/master/Misc/EnableSeRestorePrivilege.ps1
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param (
	[Parameter(Position = 0, Mandatory = $true)][ValidateSet(
		'SeAssignPrimaryTokenPrivilege',
		'SeAuditPrivilege',
		'SeBackupPrivilege',
		'SeChangeNotifyPrivilege',
		'SeCreateGlobalPrivilege',
		'SeCreatePagefilePrivilege',
		'SeCreatePermanentPrivilege',
		'SeCreateSymbolicLinkPrivilege',
		'SeCreateTokenPrivilege',
		'SeDebugPrivilege',
		'SeEnableDelegationPrivilege',
		'SeImpersonatePrivilege',
		'SeIncreaseBasePriorityPrivilege',
		'SeIncreaseQuotaPrivilege',
		'SeIncreaseWorkingSetPrivilege',
		'SeLoadDriverPrivilege',
		'SeLockMemoryPrivilege',
		'SeMachineAccountPrivilege',
		'SeManageVolumePrivilege',
		'SeProfileSingleProcessPrivilege',
		'SeRelabelPrivilege',
		'SeRemoteShutdownPrivilege',
		'SeRestorePrivilege',
		'SeSecurityPrivilege',
		'SeShutdownPrivilege',
		'SeSyncAgentPrivilege',
		'SeSystemEnvironmentPrivilege',
		'SeSystemProfilePrivilege',
		'SeSystemtimePrivilege',
		'SeTakeOwnershipPrivilege',
		'SeTcbPrivilege',
		'SeTimeZonePrivilege',
		'SeTrustedCredManAccessPrivilege',
		'SeUndockPrivilege',
		'SeUnsolicitedInputPrivilege'
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
	[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

	[DllImport("advapi32", SetLastError = true)]
	public static extern bool OpenProcessToken(
		IntPtr ProcessHandle,
		int DesiredAccess,
		ref IntPtr TokenHandle
	);

	[DllImport("advapi32", SetLastError = true)]
	public static extern bool LookupPrivilegeValue(
		string SystemName,
		string Name,
		ref long Luid
	);

	[DllImport("advapi32", SetLastError = true)]
	public static extern bool AdjustTokenPrivileges(
		IntPtr TokenHandle,
		bool DisableAllPrivileges,
		ref TokenPrivileges NewState,
		int BufferLength,
		IntPtr PreviousState,
		IntPtr ReturnLength
	);
}
'@

# start job to update process token avoid loading type definitions directly into session
$Job = Start-Job -ScriptBlock {
	# define objects
	$VerbosePreference = $using:VerbosePreference
	$TypeDefinition = $using:TypeDefinition
	$Privilege = $using:Privilege
	$ProcessId = $using:ProcessId
	$Disable = $using:Disable

	# add type
	Try {
		Add-Type -TypeDefinition $TypeDefinition -ErrorAction Stop
	}
	Catch {
		Throw $_
	}

	# define arguments for Get-Process
	$GetProcess = @{
		Id          = $ProcessId
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# get process object
	Write-Verbose "Calling Get-Process for process Id: $ProcessId"
	Try {
		$Process = Get-Process @GetProcess
	}
	Catch {
		Throw $_
	}

	# define arguments for OpenProcessToken
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
	$ProcessHandle = $Process.Handle
	$DesiredAccess = 0x28 # TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
	$TokenHandle = [IntPtr]::Zero

	# open process token
	Write-Verbose "Calling OpenProcessToken for process handle: $ProcessHandle"
	Try {
		$CallResult = [Advapi32]::OpenProcessToken($ProcessHandle, $DesiredAccess, [ref]$TokenHandle)
	}
	Catch {
		Throw $_
	}

	# report results
	If ($CallResult) {
		Write-Verbose "Token handle: $TokenHandle"
	}
	Else {
		Write-Warning 'OpenProcessToken returned error'
		$LastWin32Error = [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		Throw $LastWin32Error
	}

	# define arguments for LookupPrivilegeValue
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupprivilegevaluew
	$SystemName = $null
	$Luid = $null

	# lookup privilege LUID
	Write-Verbose "Calling LookupPrivilegeValue for privilege: $Privilege"
	Try {
		$CallResult = [Advapi32]::LookupPrivilegeValue($SystemName, $Privilege, [ref]$Luid)
	}
	Catch {
		Throw $_
	}

	# report results
	If ($CallResult) {
		Write-Verbose "LUID for '$Privilege' privilege: $Luid"
	}
	Else {
		Write-Warning 'LookupPrivilegeValue returned error'
		$LastWin32Error = [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		Throw $LastWin32Error
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
	Write-Verbose "Calling AdjustTokenPrivileges for token handle: $TokenHandle"
	Try {
		$CallResult = [Advapi32]::AdjustTokenPrivileges($TokenHandle, $DisableAllPrivileges, [ref]$TokenPrivileges, $BufferLength, $PreviousState, $ReturnLength)
	}
	Catch {
		Throw $_
	}

	# report results
	If ($CallResult) {
		Write-Verbose "Updated privileges for token handle: $TokenHandle"
	}
	Else {
		Write-Warning 'AdjustTokenPrivileges returned error'
		$LastWin32Error = [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		Throw $LastWin32Error
	}
}

# receive and remove job
$Job | Receive-Job -Wait -AutoRemoveJob
