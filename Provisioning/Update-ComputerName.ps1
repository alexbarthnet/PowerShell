Begin {
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
		Write-Output "Found active computer name: $ComputerName"
	}

	# get virtual machine name
	If ([string]::IsNullOrEmpty($VirtualMachineName)) {
		Write-Host 'Virtual Machine Name not found'
		Return
	}
	Else {
		Write-Output "Found virtual machine name: $VirtualMachineName"
	}

	If ($ComputerName -ne $VirtualMachineName) {
		# if transcript not previously started...
		If (-not $TestPath) {
			# sleep and restart
			Write-Output 'Restarting computer in first pass...'
			Restart-Computer -Force
		}
		Else {
			# 
			Write-Output 'Renaming computer in second pass...'
			Write-Output "Renaming computer to: $VirtualMachineName"
			# define variables for loop
			$HasSucceeded = $false
			$Counter = 0
			# make 5 attempsts at renaming computer
			Do {
				Try {
					# sleep to allow for domain replication of new computer objects
					Start-Sleep -Seconds 5
					# get boolean from returned object
					$HasSucceeded = Rename-Computer -NewName $VirtualMachineName -Force -PassThru | Select-Object 'HasSucceeded' -ExpandProperty 'HasSucceeded'
				}
				Catch {
					Write-Output "...error renaming computer on try #$($Counter)..."
				}
				Finally {
					$Counter++
				}
			}
			Until ($HasSucceeded -or $Counter -gt 5)
			If ($HasSucceeded) {
				Write-Output "...renamed computer on try #$($Counter)"
				Restart-Computer -Force
			}
		}
	}
}

End {
	Stop-Transcript
}