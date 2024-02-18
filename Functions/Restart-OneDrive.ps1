Function Restart-OneDrive {
	Param(
		[string]$OneDrive = (Join-Path -Path ([System.Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Microsoft\OneDrive\OneDrive.exe'),
		[string]$RunAsExe = (Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'runas.exe'),
		[int32]$SessionId = ([System.Diagnostics.Process]::GetCurrentProcess().SI)
	)

	# check for OneDrive process before shutdown
	$OneDriveProcess = Get-Process | Where-Object { $_.Name -eq 'OneDrive' -and $_.SessionId -eq $SessionId }

	# shutdown OneDrive and wait for the shutdown to complete
	If ($OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDrive /shutdown`"" }

	# wait for OneDrive process to exit
	Do { $OneDriveProcess = Get-Process | Where-Object { $_.Name -eq 'OneDrive' -and $_.SessionId -eq $SessionId } } Until (!$OneDriveProcess)

	# start OneDrive in the background via RunAs with the basic user trust level
	If (!$OneDriveProcess) { Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDrive /background`"" }
}
