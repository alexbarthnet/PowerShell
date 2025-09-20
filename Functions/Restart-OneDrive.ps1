Function Restore-ForegroundWindow {
	Param(
		# integer of window handle
		[Parameter(Position = 0, Mandatory = $true)]
		[int32]$WindowHandleId,
		# value for nCmdShow parameter of ShowWindow method: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow
		[Parameter(Position = 1)][ValidateRange(0, 11)]
		[int32]$ShowCommand = 5 # default value is 'SW_SHOW'
	)

	# define string builder for type definition
	$StringBuilder = [System.Text.StringBuilder]::new()

	# quietly add opening block to string builder
	[void]$StringBuilder.Append('using System;using System.Runtime.InteropServices;public static class User32 {')

	# quietly add DefaultDllImportSearchPaths struct to string builder
	[void]$StringBuilder.Append('[DefaultDllImportSearchPaths(DllImportSearchPath.System32)]')

	# quietly add GetForegroundWindow function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern IntPtr GetForegroundWindow();')

	# quietly add GetWindowThreadProcessId function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern int GetWindowThreadProcessId( IntPtr hWnd, int lpdwProcessId );')

	# quietly add AttachThreadInput function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern bool AttachThreadInput( uint idAttach, uint idAttachTo, bool fAttach );')

	# quietly add BringWindowToTop function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern bool BringWindowToTop( IntPtr hWnd );')

	# quietly add ShowWindow function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern bool ShowWindow( IntPtr hWnd, int nCmdShow );')

	# quietly define closing block of string builder
	[void]$StringBuilder.Append('}')

	# create type definition from stringbuilder
	$TypeDefinition = $StringBuilder.ToString()

	# start job
	$Job = Start-Job -ScriptBlock {
		# add type definition to session
		Try {
			Add-Type -TypeDefinition $using:TypeDefinition -IgnoreWarnings
		}
		Catch {
			Throw $_
		}

		# get handle of foreground window until foreground window handle is not provided window handle
		Do { [int32]$ForegroundWindowsHandleId = [User32]::GetForegroundWindow() } Until ( $ForegroundWindowsHandleId -ne $using:WindowHandleId )

		# get process id of new foreground window
		[int32]$WindowThreadProcessId = [User32]::GetWindowThreadProcessId($ForegroundWindowsHandleId, 0)

		# retrieve current thread id
		[int32]$CurrentThreadId = ([System.AppDomain]::GetCurrentThreadId())

		# if current thread is not foreground window thread...
		If ($CurrentThreadId -ne $WindowThreadProcessId) {
			# attach current thread to foreground window process
			$CallResult = [User32]::AttachThreadInput( $WindowThreadProcessId, $CurrentThreadId, $true )

			# report any errors
			If ($CallResult -eq $false) {
				Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
			}
		}

		# bring original window to top of Z-order
		$CallResult = [User32]::BringWindowToTop( $using:WindowHandleId )

		# report any errors
		If ($CallResult -eq $false) {
			Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		}

		# show original window by handle
		$CallResult = [User32]::ShowWindow( $using:WindowHandleId, $using:ShowCommand )

		# report any errors
		If ($CallResult -eq $false) {
			Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
		}

		# if current thread is not foreground window thread...
		If ($CurrentThreadId -ne $WindowThreadProcessId) {
			# detach current thread from foreground window process
			$CallResult = [User32]::AttachThreadInput( $WindowThreadProcessId, $CurrentThreadId, $false )

			# report any errors
			If ($CallResult -eq $false) {
				Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
			}
		}
	}

	# wait then receive and remove job
	$Job | Receive-Job -Wait -AutoRemoveJob
}

Function Restart-OneDrive {
	# get path to OneDrive executable
	$OneDriveExe = Join-Path -Path ([System.Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Microsoft\OneDrive\OneDrive.exe'

	# get path to RunAs executable
	$RunAsExe = Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'runas.exe'

	# get current window handle
	$MainWindowHandle = [System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle

	# if current window handle is 0...
	If ($MainWindowHandle -eq 0) {
		# define filter to retrieve process via Cim
		$Filter = 'ProcessId = {0}' -f $PID

		# get current process via Cim
		$ParentProcessId = (Get-CimInstance -ClassName 'Win32_Process' -Filter $Filter).ParentProcessId

		# get parent window handle
		$MainWindowHandle = [System.Diagnostics.Process]::GetProcessById($ParentProcessId).MainWindowHandle
	}

	# get current session id
	$CurrentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SI

	# get any OneDrive processes in current session
	$OneDriveProcess = [System.Diagnostics.Process]::GetProcessesByName('OneDrive').Where({ $_.Path -eq $OneDriveExe -and $_.SessionId -eq $CurrentSessionId })

	# shutdown OneDrive via RunAs with the Basic User trust level
	If ($OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDriveExe /shutdown`"" }

	# wait for OneDrive process in current session to close
	Do { $OneDriveProcess = [System.Diagnostics.Process]::GetProcessesByName('OneDrive').Where({ $_.Path -eq $OneDriveExe -and $_.SessionId -eq $CurrentSessionId }) } Until (!$OneDriveProcess)

	# start OneDrive in the background via RunAs with the Basic User trust level
	If (!$OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDriveExe /background`"" }

	# wait for OneDrive process to start in current session
	Do { $OneDriveProcess = [System.Diagnostics.Process]::GetProcessesByName('OneDrive').Where({ $_.Path -eq $OneDriveExe -and $_.SessionId -eq $CurrentSessionId }) } Until ($OneDriveProcess)

	# wait for OneDrive to load initial window
	Start-Sleep -Seconds 1

	# restore current foreground window to address bug with /background switch in OneDrive
	Restore-ForegroundWindow -WindowHandleId $MainWindowHandle
}
