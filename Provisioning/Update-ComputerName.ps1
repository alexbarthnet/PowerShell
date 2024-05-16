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

		# make 5 attempts to rename computer
		Do {
			# sleep to allow for domain replication of new computer objects
			Start-Sleep -Seconds 5
			# rename computer
			Try {
				$HasSucceeded = Rename-Computer @RenameComputer | Select-Object -ExpandProperty 'HasSucceeded'
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

	# create log folder path from environment
	Try {
		$LogFolderPath = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'PowerShell_transcript'
	}
	Catch {
		Exit 101
	}

	# create log file name from command path
	Try {
		$LogFileName = (Get-Item -Path $PSCommandPath).Name.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
	}
	Catch {
		Exit 102
	}

	# join paths
	Try {
		$Path = Join-Path -Path $LogFolderPath -ChildPath $LogFileName
	}
	Catch {
		Exit 103
	}

	# start transcript
	Try {
		$SecondPass = Test-Path -Path $Path -PathType Leaf
	}
	Catch {
		Exit 104
	}

	# start transcript
	Try {
		Start-Transcript -Path $Path -Append
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
		Return $_
	}

	# get virtual machine name
	Try {
		Write-Host 'Getting VirtualMachineName'
		$VirtualMachineName = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName')
	}
	Catch {
		Return $_
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
	If (!$SecondPass) {
		Write-Host 'First pass at renaming...'
	}
	Else {
		Write-Host 'Second pass at renaming...'
	}

	# call rename function
	Try {
		$HasSucceeded = Rename-VirtualMachine -NewName $VirtualMachineName
	}
	Catch {
		Return $_
	}
	
	# if rename succeeded or the first pass...
	If ($HasSucceeded -or -not $SecondPass) {
		# restart computer
		Restart-Computer -Force
	}
}

End {
	Try {
		Stop-Transcript
	}
	Catch {
		Exit 201
	}
}
