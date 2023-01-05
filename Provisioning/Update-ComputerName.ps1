# define logging
$log_root = [System.Environment]::GetFolderPath('CommonApplicationData')
$log_file = (Split-Path -Path $PSCommandPath -Leaf).Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
$log_path = Join-Path -Path $log_root -Child $log_file
# retrieve computer and virtual machine names
$os_name = (Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').GetValue('ComputerName')
$vm_name = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName')
# check computer name
If ($os_name -ne $vm_name -and -not [string]::IsNullOrEmpty($vm_name)) {
	Start-Transcript -Path $log_path -Append
	Write-Output "Found active computer name: $os_name"
	Write-Output "Found virtual machine name: $vm_name"
	Write-Output "Renaming computer to: $vm_name"
	# define variables for loop
	$vm_renamed = $false
	$loop_count = 1
	# make 5 attempsts at renaming computer
	Do {
		Try {
			# sleep to allow for domain replication of new computer objects
			Start-Sleep -Seconds 5
			# get boolean from returned object
			$vm_renamed = Rename-Computer -NewName $vm_name -Force -PassThru | Select-Object 'HasSucceeded' -ExpandProperty 'HasSucceeded'
		}
		Catch {
			Write-Output "...error renaming computer on try #$($loop_count): $($_.ToString())"
		}
		Finally {
			$loop_count++
		}
	}
	Until ($vm_renamed -or $loop_count -gt 5)
	If ($vm_renamed) {
		Write-Output "...renamed computer on try #$($loop_count)"
		Restart-Computer -Force
	}
	Stop-Transcript
}
