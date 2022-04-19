Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmJson,
	[Parameter()]
	[string[]]$VmName,
	[Parameter()]
	[string]$VMHost,
	[Parameter()]
	[string]$VMHostPath,
	[Parameter(Mandatory = $True)]
	[string]$DestinationHost,
	[Parameter()]
	[string]$DestinationPath,
	[Parameter()]
	[switch]$Reverse,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

# create VM list from parameters
$vm_list = @()
If ($VmHost -and $VmName) {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -eq $VMHost -and $_.VMName -in $VMName }
}
ElseIf ($VmHost) {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -eq $VMHost -and $_.VMName }
}
ElseIf ($VmName) {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName -in $VMName }
}
Else {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName }
}

# check VM list
If ($vm_list.Count -eq 0) {
	Write-Host ("$Hostname - VM(s) not found in Json, exiting!")
	Return
}

Write-Host ("$Hostname - starting move for " + $vm_list.count + ' VMs')
ForEach ($VmParams in $vm_list) {
	# define required objects from CSV
	$vm_name = $VmParams.Name
	Write-Host ("$Hostname - validating move for VM: " + $vm_name)

	# clear variables
	$vm_host = $null
	$vm_host_dest = $null
	$vm_path_dest = $null

	# set host information
	If ($Reverse) {
		$vm_host = $DestinationHost
		$vm_host_dest = $VmParams.Host
		$vm_path_dest = $VmParams.Path
	}
	Else {
		$vm_host = $VmParams.Host
		$vm_host_dest = $DestinationHost
		$vm_path_dest = $DestinationPath
	}

	# check source host
	switch ($vm_host) {
		'cloud' {
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname - ERROR: source host not defined for VM")
			Return
		}
		Default {
			Try {
				$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
				Write-Host ("$Hostname - connected to source host: $vm_host")
			}
			Catch {
				Write-Host ("$Hostname - ERROR: could not connect to source host: $vm_host")
				Return
			}
		}
	}

	# check destination host
	switch ($vm_host_dest) {
		'cloud' {
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname - ERROR: destination host not defined for VM")
			Return
		}
		Default {
			Try {
				$null = Test-WSMan -ComputerName $vm_host_dest -Authentication 'Default'
				Write-Host ("$Hostname - connected to destination host: $vm_host_dest")
			}
			Catch {
				Write-Host ("$Hostname - ERROR: could not connect to destination host: $vm_host_dest")
				Return
			}
		}
	}

	# validate host configuration
	If ($vm_in_the_cloud) {
		Write-Host ("$Hostname - ERROR: source or destination host is 'cloud', cannot move VM between cloud and local hosts")
		Return
	}

	# set destination path
	If (!($vm_path_dest)) {
		$vm_path_dest = (Get-VMHost -ComputerName $vm_host_dest).VirtualMachinePath
		Write-Host ("$Hostname - ...using default VM path: $vm_path_dest")
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
			Write-Host ("$Hostname - ...cluster resource for VM found on destination cluster: $vm_dest_cluster")
			Write-Host ("$Hostname - ...skipping!")
			Return
		}
	}

	# check for VM on destination host
	$vm_on_dest = Get-VM -ComputerName $vm_host_dest | Where-Object { $_.Name -eq $vm_name }
	If ($vm_on_dest) {
		Write-Host ("$Hostname - ....VM found on destination: $vm_host_dest")
		Write-Host ("$Hostname - ...skipping!")
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
				Write-Host ("$Hostname - ...cluster resource for VM found on different host, changing host to: $vm_node")
				$vm_host = $vm_node
			}
		}
	}

	# check for VM on source host
	$vm_on_host = $null
	$vm_on_host = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
	If ($null -eq $vm_on_host) {
		Write-Host ("$Hostname - ....VM not found on host: $vm_host")
		Write-Host ("$Hostname - ...skipping!")
		Return
	}

	# remove VM from source cluster
	If ($vm_on_cl) {
		# remove resource group from the cluster
		Write-Host ("$Hostname - ...removing cluster resource on source: " + $vm_cluster)
		$vm_on_cl | Remove-ClusterGroup -RemoveResources -Force
	}

	# move VM
	If ($vm_dest_cl) {
		Write-Host ("$Hostname - moving VM ...")
		Write-Host ("$Hostname - ...to cluster member: " + $vm_host_dest)
	}
	Else {
		Write-Host ("$Hostname - moving VM ...")
		Write-Host ("$Hostname - ...to Hyper-V server: " + $vm_host_dest)
	}
	try {
		Move-VM -ComputerName $vm_host -Name $vm_name -DestinationHost $vm_host_dest -IncludeStorage -DestinationStoragePath $vm_path_vm
		Write-Host ("$Hostname - ...move complete!")
	}
	catch {
		Write-Host ("$Hostname - ...move failed!")
	}

	# add VM to cluster
	If ($vm_dest_cl) {
		Write-Host ("$Hostname - ...adding to cluster: " + $vm_dest_cluster)
		Add-ClusterVirtualMachineRole -Cluster $vm_dest_cluster -VMName $vm_name | Out-Null
	}
}

