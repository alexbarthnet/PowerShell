Function Restart-OneDrive {
	Param(
		[string]$OneDrive = (Join-Path -Path ([System.Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'Microsoft\OneDrive\OneDrive.exe'),
		[string]$RunAsExe = (Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'runas.exe')
	)

	# shutdown OneDrive and wait for the shtudown to complete
	Start-Process -WindowStyle Hidden -FilePath $OneDrive -ArgumentList '/shutdown' -Wait

	# start OneDrive in the background via RunAs with the basic user trust level
	Start-Process -WindowStyle Hidden -FilePath $RunAsExe -ArgumentList "/trustlevel:0x20000 `"$OneDrive /background`""
}
