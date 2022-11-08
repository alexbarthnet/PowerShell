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
	$vm_host_source = $null
	$vm_host_target = $null
	$vm_path_target = $null

	# set host information
	If ($Reverse) {
		$vm_host_source = $DestinationHost
		$vm_host_target = $VmParams.Host
	}
	Else {
		$vm_host_source = $VmParams.Host
		$vm_host_target = $DestinationHost
	}

	# check source host
	switch ($vm_host_source) {
		'cloud' {
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname - ERROR: source host not defined for VM")
			Return
		}
		Default {
			Try {
				$null = Test-WSMan -ComputerName $vm_host_source -Authentication 'Default'
				Write-Host ("$Hostname - connected to source host: $vm_host_source")
			}
			Catch {
				Write-Host ("$Hostname - ERROR: could not connect to source host: $vm_host_source")
				Return
			}
		}
	}

	# check destination host
	switch ($vm_host_target) {
		'cloud' {
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname - ERROR: destination host not defined for VM")
			Return
		}
		Default {
			Try {
				$null = Test-WSMan -ComputerName $vm_host_target -Authentication 'Default'
				Write-Host ("$Hostname - connected to destination host: $vm_host_target")
			}
			Catch {
				Write-Host ("$Hostname - ERROR: could not connect to destination host: $vm_host_target")
				Return
			}
		}
	}

	# validate host configuration
	If ($vm_in_the_cloud) {
		Write-Host ("$Hostname - ERROR: source or destination host is 'cloud', cannot move VM between cloud and local hosts")
		Return
	}

	# set path information
	If ($Reverse) {
		$vm_path_target = $VmParams.Path
	}
	Else {
		$vm_path_target = $DestinationPath
	}

	# set destination path
	If (!($vm_path_target)) {
		$vm_path_target = (Get-VMHost -ComputerName $vm_host_target).VirtualMachinePath
		Write-Host ("$Hostname - ...using default VM path: $vm_path_target")
	}

	# create the VM specific path
	$vm_path_vm = Invoke-Command -ComputerName $vm_host_target -ScriptBlock { Join-Path -Path $using:vm_path_target -ChildPath $using:vm_name }

	# check if dest is clustered
	$vm_host_target_cl = $null
	$vm_host_target_cl = Get-Service -ComputerName $vm_host_target | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
	If ($vm_host_target_cl) {
		# check for VM on cluster
		$vm_host_target_cluster = Invoke-Command -ComputerName $vm_host_target { (Get-Cluster).Name }
		$vm_to_cl = Get-ClusterGroup -Cluster $vm_host_target_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
		If ($vm_to_cl) {
			Write-Host ("$Hostname - ...cluster resource for VM found on destination cluster: $vm_host_target_cluster")
			Write-Host ("$Hostname - ...skipping!")
			Return
		}
	}

	# check for VM on destination host
	$vm_on_target = Get-VM -ComputerName $vm_host_target | Where-Object { $_.Name -eq $vm_name }
	If ($vm_on_target) {
		Write-Host ("$Hostname - ....VM found on destination: $vm_host_target")
		Write-Host ("$Hostname - ...skipping!")
		Return
	}

	# check if source is clustered
	$vm_host_cl = $null
	$vm_host_cl = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
	If ($vm_host_cl) {
		# check for VM on cluster
		$vm_host_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
		$vm_on_cluster = Get-ClusterGroup -Cluster $vm_host_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
		If ($vm_on_cluster) {
			Write-Host ("$Hostname - ...cluster resource for VM found on source cluster: $vm_host_cluster")
			# verify the resource group is on the local node
			$vm_node = $vm_on_cluster.OwnerNode.NodeName
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
	If ($vm_on_cluster) {
		# remove resource group from the cluster
		Write-Host ("$Hostname - ...removing cluster resource on source: " + $vm_host_cluster)
		$vm_on_cluster | Remove-ClusterGroup -RemoveResources -Force
	}

	# move VM
	If ($vm_host_target_cl) {
		Write-Host ("$Hostname - moving VM ...")
		Write-Host ("$Hostname - ...to cluster member: " + $vm_host_target)
	}
	Else {
		Write-Host ("$Hostname - moving VM ...")
		Write-Host ("$Hostname - ...to Hyper-V server: " + $vm_host_target)
	}
	try {
		Move-VM -ComputerName $vm_host -Name $vm_name -DestinationHost $vm_host_target -IncludeStorage -DestinationStoragePath $vm_path_vm
		Write-Host ("$Hostname - ...move complete!")
	}
	catch {
		Write-Host ("$Hostname - ...move failed!")
	}

	# add VM to cluster
	If ($vm_host_target_cl) {
		Write-Host ("$Hostname - ...adding to cluster: " + $vm_host_target_cluster)
		Add-ClusterVirtualMachineRole -Cluster $vm_host_target_cluster -VMName $vm_name | Out-Null
	}
}

