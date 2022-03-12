Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$NetCsv
)

# create global objects
$env_comp_name = $env:computername.ToLower()

# import the CSV
$nic_list = $null
$nic_list = Import-Csv -Path $NetCsv

# process each unique VM in the CSV
$nic_list | Sort-Object -Property 'Name' -Unique | ForEach-Object {
	# get strings from CSV
	$vm_name = $_.Name
	$vm_host = $_.Host

	# declare start
	Write-Host ("======================== $vm_name ========================")

	# check if host is valid
	Write-Host ("$env_comp_name,$vm_host,$vm_name - checking host...")
	Try {
		$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...found host")
	}
	Catch {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ERROR: could not connect to host")
		Return
	}

	# check if host is clustered
	Write-Host ("$env_comp_name,$vm_host,$vm_name - checking if host is clustered...")
	$vm_host_cl = $null
	$vm_host_cl = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }

	# check for VM on cluster
	If ($vm_host_cl) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...host is clustered")
		# check for VM on cluster
		Write-Host ("$env_comp_name,$vm_host,$vm_name - locating VM on cluster...")
		$vm_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
		$vm_on_cl = Get-ClusterGroup -Cluster $vm_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
		If ($vm_on_cl) {
			# verify the resource group is on the local node
			$vm_node = $vm_on_cl.OwnerNode.NodeName
			If ($vm_host -eq $vm_node) {
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on expected host in cluster")
			}
			Else {
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on different host in cluster, changing host to: " + $vm_node)
				$vm_host = $vm_node
			}
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM not found on cluster")
			Return
		}
	}
	Else {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...host is standalone")
	}

	# check for VM on host
	Write-Host ("$env_comp_name,$vm_host,$vm_name - locating VM on host...")
	$vm = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
	If ($null -eq $vm) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM not found, create VM before configuring ASH")
		Return
	}

	# get the VM NICs
	$vm_nic_all = $vm | Get-VMNetworkAdapter

	# run through network CSV to configure network adapaters
	$nic_list | Where-Object { $_.Name -eq $vm_name } | ForEach-Object {
		# get values from CSV
		$nic_name = $_.Adapter
		$nic_mode = $_.Mode
		$nic_vlan = $_.Vlan
		$nic_switch = $_.Switch

		# check for NIC
		$vm_nic = $vm_nic_all | Where-Object { $_.Name -eq $nic_name }
		If ($null = $vm_nic) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name,$nic_name - NIC not found, creating!")
			$vm_nic = Add-VMNetworkAdapter -VMName $vm_name -Name $nic_name -SwitchName $nic_switch -Passthru
		}
		ElseIf ($vm_nic.SwitchName -ne $nic_switch) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - NIC found but not connected to switch '$nic_switch', fixing!")
			$vm_nic | Connect-VMNetworkAdapter -SwitchName $nic_switch
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - NIC found connected to switch: $nic_switch")
		}

		# set the NIC port mode
		If ($nic_mode -eq 'Trunk') {
			Write-Host ("$env_comp_name,$vm_host,$vm_name,$nic_name - NIC set to Trunk mode with native VLAN: $nic_vlan")
			$vm_nic | Set-VMNetworkAdapterVlan -Trunk -NativeVlanId $nic_vlan -AllowedVlanIdList 1-4094
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name,$nic_name - NIC set to Access mode with VLAN: $nic_vlan")
			$vm_nic | Set-VMNetworkAdapterVlan -Access -VlanId $nic_vlan
		}

		# set all other NIC properties
		Write-Host ("$env_comp_name,$vm_host,$vm_name,$nic_name - NIC teaming, device naming and MAC address spoofing enabled")
		$vm_nic | Set-VMNetworkAdapter -AllowTeaming On -DeviceNaming On -MacAddressSpoofing On
	}
}
