Begin {
	Function Rename-VirtualMachine {
		Param(
			[string]$NewName
		)

		# declare and begin
		Write-Host "Renaming computer to: $NewName"

		# define variables for loop
		$HasSucceeded = $false
		$Counter = 1

		# define parameters for Rename-Computer
		$RenameComputer = @{
			NewName  = $NewName
			Force    = $true
			Passthru = $true
		}

		# make 5 attempsts at renaming computer
		Do {
			# sleep to allow for domain replication of new computer objects
			Start-Sleep -Seconds 5
			# rename computer
			Try {
				$HasSucceeded = Rename-Computer @RenameComputer | Select-Object 'HasSucceeded' -ExpandProperty 'HasSucceeded'
				Write-Host "...renamed computer on try #$($Counter)"
			}
			Catch {
				Write-Host "...error renaming computer on try #$($Counter)..."
			}
			Finally {
				$Counter++
			}
		}
		Until ($HasSucceeded -or $Counter -gt 5)

		# return
		If ($HasSucceeded) {
			Return $true
		}
		Else {
			Return $false
		}
	}

	# create path from environment
	Try {
		$LogFolderPath = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
	}
	Catch {
		Exit 101
	}

	# create name from command path
	Try {
		$LogName = (Split-Path -Path $PSCommandPath -Leaf).Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
	}
	Catch {
		Exit 102
	}

	# join paths
	Try {
		$LogPath = Join-Path -Path $LogFolderPath -Child $LogName
	}
	Catch {
		Exit 103
	}

	# start transcript
	Try {
		$TestPath = Test-Path -Path $LogPath -PathType Leaf
	}
	Catch {
		Exit 104
	}

	# start transcript
	Try {
		Start-Transcript -Path $LogPath -Append
	}
	Catch {
		Exit 105
	}

	# get computer name
	Try {
		Write-Host 'Getting ComputerName'
		$ComputerName = (Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').GetValue('ComputerName')
	}
	Catch {
		Throw $_
	}

	# get virtual machine name
	Try {
		Write-Host 'Getting VirtualMachineName'
		$VirtualMachineName = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName')
	}
	Catch {
		Throw $_
	}
}

Process {
	# get computer machine name
	If ([string]::IsNullOrEmpty($ComputerName)) {
		Write-Host 'Computer Name not found'
		Return
	}
	Else {
		Write-Host "Found active computer name: $ComputerName"
	}

	# get virtual machine name
	If ([string]::IsNullOrEmpty($VirtualMachineName)) {
		Write-Host 'Virtual Machine Name not found'
		Return
	}
	Else {
		Write-Host "Found virtual machine name: $VirtualMachineName"
	}

	# declare pass
	If (-not $TestPath) {
		Write-Host 'First pass at renaming...'
	}
	Else {
		Write-Host 'Second pass at renaming...'
	}

	# call function
	Try {
		$HasSucceeded = Rename-VirtualMachine -NewName $VirtualMachineName
	}
	Catch {
		Throw $_
	}
	
	# restart computer on success in either pass or on failure in first pass
	If ($HasSucceeded -or -not $TestPath) {
		Restart-Computer -Force
	}
}

End {
	Stop-Transcript
}
