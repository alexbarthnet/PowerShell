Param(  
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmCsv,
	[Parameter(Mandatory = $True)]
	[string]$DestinationHost,
	[string]$DestinationPath,
	[string]$VmHost,
	[string[]]$VmNames,
	[bool]$Reverse = $false
)

# create global objects
$env_comp_name = $env:computername.ToLower()

# import VM information
$vm_list = @()
If ($VmNames) {
	# process single VM
	Write-Host ("$env_comp_name - importing single VM for move: " + $VmNames)
	$vm_list = Import-Csv -Path $VmCsv | Where-Object { $_.Name -eq $VmNames }

	# process requested VMs
	$VmName | ForEach-Object {
		$vm_temp = $null
		$vm_temp = $_
		$vm_list += Import-Csv -Path $VmCsv | Where-Object { $_.Name -eq $vm_temp }
	}
	If ($vm_list.Name -notcontains $vm_temp) {
		Write-Host ("$env_comp_name - VM not found in CSV, exiting!")
		Return
	}
} 
ElseIf ($VmHost) {
	# process single VM
	Write-Host ("$env_comp_name - importing all VM from host: " + $VmHost)
	$vm_list = Import-Csv -Path $VmCsv | Where-Object { $_.Host -eq $VmHost }
} 
Else {
	# process all VMs
	Write-Host ("$env_comp_name - importing all VMs for move...")
	$vm_list = Import-Csv -Path $VmCsv
}

# process CSV
If ($null -eq $vm_list) {
	Write-Host '...no VMs found in VM list!'
}
Else {
	Write-Host ("$env_comp_name - starting move for " + $vm_list.count + ' VMs')
	$vm_list | ForEach-Object {
		# define required objects from CSV
		$vm_name = $_.Name
		Write-Host ("$env_comp_name - validating move for VM: " + $vm_name)
		
		# clear variables
		$vm_host = $null
		$vm_host_dest = $null
		$vm_path_dest = $null

		# define host information
		If ($Reverse) {
			$vm_host = $DestinationHost
			$vm_host_dest = $_.Host
			$vm_path_dest = $_.Path
		}
		Else {
			$vm_host = $_.Host
			$vm_host_dest = $DestinationHost
			$vm_path_dest = $DestinationPath
		}

		# validate host configuration
		If ($vm_host -match 'cloud') {
			Write-Host ("$env_comp_name - ...source or destination host is 'cloud', exiting!")
			Exit
		}
		ElseIf ($null -eq $vm_host -or $null -eq $vm_host_dest) {
			Write-Host ("$env_comp_name - ...missing source or destination host, exiting!")
			Exit
		}
		Else {
			# set destination path
			If (!($vm_path_dest)) {
				$vm_path_dest = (Get-VMHost -ComputerName $vm_host_dest).VirtualMachinePath
				# Write-Host ("$env_comp_name - ...using default VM path: " + $vm_path_dest)
			}

			# create the VM specific path
			$vm_path_vm = Invoke-Command -ComputerName $vm_host_dest -ScriptBlock { Join-Path -Path $using:vm_path_dest -ChildPath $using:vm_name }
			
			# check if dest is clustered
			$vm_dest_cl = $null
			$vm_dest_cl = Get-Service -ComputerName $vm_host_dest | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
			If ($vm_dest_cl) {
				# check for VM on cluster
				$vm_dest_cluster = Invoke-Command -ComputerName $vm_host_dest { (Get-Cluster).Name }
				$vm_to_cl = Get-ClusterGroup -Cluster $vm_dest_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
				If ($vm_to_cl) {
					Write-Host ("$env_comp_name - ...cluster resource for VM found on destination cluster: " + $vm_dest_cluster)
					Write-Host ("$env_comp_name - ...skipping!")
					Return
				}
			}

			# check for VM on destination host
			$vm_on_dest = Get-VM -ComputerName $vm_host_dest | Where-Object { $_.Name -eq $vm_name }
			If ($vm_on_dest) {
				Write-Host ("$env_comp_name - ....VM found on destination: " + $vm_host_dest)
				Write-Host ("$env_comp_name - ...skipping!")
				Return
			}

			# check if source is clustered
			$vm_host_cl = $null
			$vm_host_cl = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
			If ($vm_host_cl) {
				# check for VM on cluster
				$vm_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
				$vm_on_cl = Get-ClusterGroup -Cluster $vm_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
				If ($vm_on_cl) {
					# verify the resource group is on the local node
					$vm_node = $vm_on_cl.OwnerNode.NodeName
					If ($vm_host -ne $vm_node) {
						Write-Host ("$env_comp_name - ...cluster resource for VM found on different host, changing host to: " + $vm_node)
						$vm_host = $vm_node
					}
				}
			}

			# check for VM on source host
			$vm_on_host = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
			If (!($vm_on_host)) {
				Write-Host ("$env_comp_name - ....VM not found on host: " + $vm_host)
				Write-Host ("$env_comp_name - ...skipping!")
				Return
			}

			# remove VM from source cluster
			If ($vm_on_cl) {
				# remove resource group from the cluster
				Write-Host ("$env_comp_name - ...removing cluster resource on source: " + $vm_cluster)
				$vm_on_cl | Remove-ClusterGroup -RemoveResources -Force
			}

			# move VM
			If ($vm_dest_cl) {
				Write-Host ("$env_comp_name - moving VM ...")
				Write-Host ("$env_comp_name - ...to cluster member: " + $vm_host_dest)
			}
			Else {
				Write-Host ("$env_comp_name - moving VM ...")
				Write-Host ("$env_comp_name - ...to Hyper-V server: " + $vm_host_dest)
			}
			try {
				Move-VM -ComputerName $vm_host -Name $vm_name -DestinationHost $vm_host_dest -IncludeStorage -DestinationStoragePath $vm_path_vm
				Write-Host ("$env_comp_name - ...move complete!")
			}
			catch {
				Write-Host ("$env_comp_name - ...move failed!")
			}

			# add VM to cluster
			If ($vm_dest_cl) {
				Write-Host ("$env_comp_name - ...adding to cluster: " + $vm_dest_cluster)
				Add-ClusterVirtualMachineRole -Cluster $vm_dest_cluster -VMName $vm_name | Out-Null
			}
		}
	}
}
