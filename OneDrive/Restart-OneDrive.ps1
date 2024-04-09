Function Invoke-ShowWindow {
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

	# quietly add GetForegroundWindow function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern int GetWindowThreadProcessId( IntPtr hWnd, int lpdwProcessId );')

	# quietly add GetForegroundWindow function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern bool AttachThreadInput( uint idAttach, uint idAttachTo, bool fAttach );')

	# quietly add GetForegroundWindow function to string builder
	[void]$StringBuilder.Append('[DllImport("user32.dll", SetLastError=true)]public static extern bool BringWindowToTop( IntPtr hWnd );')

	# quietly add GetForegroundWindow function to string builder
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

		# get handle of new foreground window
		Do { [int32]$ForegroundWindowsHandleId = [User32]::GetForegroundWindow() } Until ( $ForegroundWindowsHandleId -ne $using:WindowHandleId )

		# get process id of new foreground window
		[int32]$WindowThreadProcessId = [User32]::GetWindowThreadProcessId($ForegroundWindowsHandleId, 0)

		# retrieve current thread id
		[int32]$CurrentThreadId = ([System.AppDomain]::GetCurrentThreadId())

		# if current thread is not attached to new foreground window process...
		If ($CurrentThreadId -ne $WindowThreadProcessId) {
			# attach current thread to foreground window process
			$CallResult = [User32]::AttachThreadInput( $WindowThreadProcessId, $CurrentThreadId, $true )

			# report any errors
			If ($CallResult -eq $false) {
				Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
			}
		}

		# bring original window to top
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

		# if current thread was not attached to foreground window process...
		If ($CurrentThreadId -ne $WindowThreadProcessId) {
			# detach current thread from foreground window process
			$CallResult = [User32]::AttachThreadInput( $WindowThreadProcessId, $CurrentThreadId, $false )

			# report any errors
			If ($CallResult -eq $false) {
				Throw [System.ComponentModel.Win32Exception][System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
			}
		}
	}

	# receive job
	$Job | Receive-Job -Wait -AutoRemoveJob
}

Function Restart-OneDrive {
	Param(
		[string]$OneDrive = (Join-Path -Path ([System.Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Microsoft\OneDrive\OneDrive.exe'),
		[string]$RunAsExe = (Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'runas.exe'),
		[int32]$CurrentSessionId = ([System.Diagnostics.Process]::GetCurrentProcess().SI),
		[int32]$MainWindowHandle = ([System.Diagnostics.Process]::GetCurrentProcess().MainWindowHandle)
	)

	# check for OneDrive process before shutdown
	$OneDriveProcess = Get-Process | Where-Object { $_.Name -eq 'OneDrive' -and $_.SessionId -eq $CurrentSessionId }

	# shutdown OneDrive and wait for the shutdown to complete
	If ($OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDrive /shutdown`"" }

	# wait for OneDrive process to exit
	Do { $OneDriveProcess = Get-Process | Where-Object { $_.Name -eq 'OneDrive' -and $_.SessionId -eq $CurrentSessionId } } Until (!$OneDriveProcess)

	# start OneDrive in the background via RunAs with the basic user trust level
	If (!$OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDrive /background`"" }

	# wait for OneDrive process to start
	Do { $OneDriveProcess = Get-Process | Where-Object { $_.Name -eq 'OneDrive' -and $_.SessionId -eq $CurrentSessionId } } Until ($OneDriveProcess)

	# wait for OneDrive to load initial window
	Start-Sleep -Seconds 1

	# address OneDrive not restoring previous foreground window on start
	Invoke-ShowWindow -WindowHandleId $MainWindowHandle
}

Restart-OneDrive