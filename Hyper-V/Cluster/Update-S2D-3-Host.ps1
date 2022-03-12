<#
.SYNOPSIS
Configures the live migration and QoS settings on a Hyper-V host that will be or is running Storage Spaces Direct (S2D).

.DESCRIPTION
Configures the live migration and QoS settings on a Hyper-V host that will be or is running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

A parent script pushes this script and the configuration files to each Hyper-V host then starts the script using PowerShell Remoting.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

[CmdletBinding()]
param (
	[Parameter()]
	[string]$Hostname = [System.Net.Dns]::GetHostName().ToLower(),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$TempPath = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$FilePath = (Join-Path -Path $TempPath -ChildPath 'hv-setup'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$LogFile = $PSCommandPath.Replace('.ps1', "-$(Get-Date -Format FileDateTime).txt"),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv = (Join-Path -Path $FilePath -ChildPath "$($Hostname)-host.csv"),
	[Parameter()]
	[string]$SmbLabel = 'SMB',
	[Parameter()]
	[string]$SmbDirectLabel = 'SMBDirect',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$SmbDirectPercent = 50,
	[Parameter()]
	[string]$ClusterPortLabel = 'ClusterPort',
	[Parameter()]
	[string]$ClusterLabel = 'Cluster',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$ClusterPercent = 1,
	[Parameter()]
	[string]$DefaultLabel = 'Default',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$DefaultPercent = (100 - $SmbDirectPercent - $ClusterPercent )
)

Try {
	# start logging
	Start-Transcript -Path $LogFile -Append -Force

	# determine live migration bandwidth limit
	$nic_speed = $null
	$nic_speed = (Get-NetAdapter -Physical | Sort-Object Speed | Select-Object -Last 1).Speed
	If ($nic_speed -lt [Math]::Pow(10, 10)) {
		# below 10Gb, set SMB bandwidth limit to 30% of the link speed in MB
		# the math: take linkspeed, divide by 1 million (convert bit to megabits), divide by 8 (convert megabits to megabytes), multiply by 0.3 (30%)
		$smb_limit = $nic_speed / [Math]::Pow(10, 6) / 8 * 0.3
	}
	Else {
		# at or above 10Gb, set SMB bandwidth limit to 375MB
		# the limit is defined in Validate-DCB
		$smb_limit = 375
	}

	# import host CSV and retrieve any values for VmPath and VhdPath
	$host_data = Import-Csv -Path $HostCsv | Where-Object { $_.Host -eq $Hostname -and $_.VmPath -and $_.VhdPath } | Select-Object -First 1

	# check virtual hard disk path
	If ([string]::IsNullOrEmpty($host_data.VmPath)) {
		$host_vmpath = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
	}
	ElseIf (Test-Path -Path $host_data.VmPath) {
		$host_vmpath = $host_data.VmPath
	}
	ElseIf (Test-Path -Path (Get-VMHost).VirtualMachinePath) {
		$host_vmpath = (Get-VMHost).VirtualMachinePath
	}
	Else {
		$host_vmpath = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
	}

	# check virtual hard disk path
	If ([string]::IsNullOrEmpty($host_data.VhdPath)) {
		$host_vhdpath = 'C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks'
	}
	ElseIf (Test-Path -Path $host_data.VhdPath) {
		$host_vhdpath = $host_data.VhdPath
	}
	ElseIf (Test-Path -Path (Get-VMHost).VirtualHardDiskPath) {
		$host_vhdpath = (Get-VMHost).VirtualHardDiskPath
	}
	Else {
		$host_vhdpath = 'C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks'
	}

	# set virtual hard disk path
	Write-Host "$Hostname - setting Virtual Machine Path to: '$host_vmpath'"
	Set-VMHost -VirtualMachinePath $host_vmpath

	# set virtual hard disk path
	Write-Host "$Hostname - setting Virtual Hard Disk Path to: '$host_vhdpath'"
	Set-VMHost -VirtualHardDiskPath $host_vhdpath

	# set winrm max envelope size
	Write-Host "$Hostname - setting WinRM Envelope maximum to 4MB"
	Set-WSManInstance -ResourceURI 'winrm/config' -ValueSet @{MaxEnvelopeSizekb = '4096' }

	# set live migration bandwidth limit
	Write-Host "$Hostname - setting Live Migration bandwidth limit: $($smb_limit.ToString()) MB/s"
	Set-SmbBandwidthLimit -Category 'LiveMigration' -BytesPerSecond ($smb_limit * 1MB)

	# configure Live Migration to allow 4 concurrent Live Migrations
	Write-Host "$Hostname - setting Live Migration concurrence: 4"
	Set-VMHost -MaximumVirtualMachineMigrations 4

	# configure Live Migration to use Kerberos
	Write-Host "$Hostname - setting Live Migration authentication: Kerberos"
	Set-VMHost -VirtualMachineMigrationAuthenticationType 'Kerberos'

	# configure Live Migration to use SMB
	Write-Host "$Hostname - setting Live Migration transfer type: SMB"
	Set-VMHost -VirtualMachineMigrationPerformanceOption 'SMB'

	# enable Live Migration
	Write-Host "$Hostname - enabling Live Migration"
	Enable-VMMigration

	# disable numa spanning
	Write-Host "$Hostname - disabling NUMA Spanning"
	Set-VMHost -NumaSpanningEnabled $false

	# disable enhanced session mode
	Write-Host "$Hostname - disabling Enhanced Session Mode"
	Set-VMHost -EnableEnhancedSessionMode $false

	# disable DCBx
	Write-Host "$Hostname - disabling QoS DCBx Willing mode"
	Set-NetQosDcbxSetting -Willing $False -Confirm:$false

	# check for SMBDirect QoS policy
	Write-Host "$Hostname - checking SMBDirect QoS policy"
	$qos_policy_smb_direct = Get-NetQosPolicy | Where-Object { $_.Name -eq $SmbDirectLabel -and $_.PriorityValue -eq 3 -and $_.NetDirectPort -eq 445 }
	If ($qos_policy_smb_direct) {
		Write-Host "$Hostname - verified SMBDirect QoS policy"
	}
	Else {
		$qos_policy_smb_direct = Get-NetQosPolicy | Where-Object { $_.Name -eq $SmbDirectLabel -or $_.NetDirectPort -eq 445 }
		$qos_policy_smb_direct | ForEach-Object {
			If ($_.Name -ne $SmbDirectLabel -or $_.PriorityValue -ne 3 -or $_.NetDirectPort -ne 445 ) {
				Write-Host "$Hostname - removing errant SMBDirect QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating SMBDirect QoS policy"
		New-NetQosPolicy -Name $SmbDirectLabel -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445
	}

	# check for SMBDirect QoS policy
	Write-Host "$Hostname - checking SMB QoS policy"
	$qos_policy_smb = Get-NetQosPolicy | Where-Object { $_.Name -eq $SmbLabel -and $_.PriorityValue -eq 3 -and $_.Template -eq $SmbLabel }
	If ($qos_policy_smb) {
		Write-Host "$Hostname - verified SMB QoS policy"
	}
	Else {
		$qos_policy_smb = Get-NetQosPolicy | Where-Object { $_.Name -eq $SmbLabel -or $_.NetDirectPort -eq 445 }
		$qos_policy_smb | ForEach-Object {
			If ($_.Name -ne $SmbLabel -or $_.PriorityValue -ne 3 -or $_.Template -ne $SmbLabel) {
				Write-Host "$Hostname - removing errant SMB QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating SMB QoS policy"
		New-NetQosPolicy -Name $SmbLabel -PriorityValue8021Action 3 -SMB
	}

	# check for Cluster Port QoS policy
	Write-Host "$Hostname - checking Cluster Port QoS policy"
	$qos_policy_cluster_port = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterPortLabel -and $_.PriorityValue -eq 7 -and $_.IPDstPortStart -eq '3343' -and $_.IPDstPortEnd -eq '3343' }
	If ($qos_policy_cluster_port) {
		Write-Host "$Hostname - verified Cluster Port QoS policy"
	}
	Else {
		$qos_policy_cluster_port = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterPortLabel -or $_.IPDstPortStart -eq '3343' -or $_.IPDstPortEnd -eq '3343' }
		$qos_policy_cluster_port | ForEach-Object {
			If ($_.Name -ne $ClusterPortLabel -or $_.PriorityValue -ne 7 -or $_.IPDstPortStart -eq '3343' -or $_.IPDstPortEnd -eq '3343') {
				Write-Host "$Hostname - removing incorrect Cluster Port QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating Cluster Port QoS policy"
		New-NetQosPolicy -Name $ClusterPortLabel -PriorityValue8021Action 7 -IPDstPort 3343
	}

	# check for Cluster QoS policy
	Write-Host "$Hostname - checking Cluster QoS policy"
	$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterLabel -and $_.PriorityValue -eq 7 -and $_.Template -eq $ClusterLabel }
	If ($qos_policy_cluster) {
		Write-Host "$Hostname - verified Cluster QoS policy"
	}
	Else {
		$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterLabel -or $_.Template -eq $ClusterLabel }
		$qos_policy_cluster | ForEach-Object {
			If ($_.Name -ne $ClusterLabel -or $_.PriorityValue -ne 7 -or $_.Template -ne $ClusterLabel) {
				Write-Host "$Hostname - removing incorrect Cluster QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating Cluster QoS policy"
		New-NetQosPolicy -Name $ClusterLabel -PriorityValue8021Action 7 -Cluster
	}

	# check for Default QoS policy
	Write-Host "$Hostname - checking Default QoS policy"
	$qos_policy_default = Get-NetQosPolicy | Where-Object { $_.Name -eq $DefaultLabel -and $_.PriorityValue -eq 0 -and $_.Template -eq $DefaultLabel }
	If ($qos_policy_default) {
		Write-Host "$Hostname - verified Default QoS policy"
	}
	Else {
		$qos_policy_default = Get-NetQosPolicy | Where-Object { $_.Name -eq $DefaultLabel -or $_.Template -eq $DefaultLabel }
		$qos_policy_default | ForEach-Object {
			If ($_.Name -ne $DefaultLabel -or $_.PriorityValue -ne 0 -or $_.Template -ne $DefaultLabel) {
				Write-Host "$Hostname - removing incorrect Default QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating Default QoS policy"
		New-NetQosPolicy -Name $DefaultLabel -PriorityValue8021Action 0 -Default
	}

	# check for SMB QoS traffic class
	Write-Host "$Hostname - checking SMBDirect QoS traffic class"
	$qos_traffic_smb_direct = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $SmbDirectLabel -and $_.Priority -eq 3 -and $_.Bandwidth -eq $SmbDirectPercent -and $_.Algorithm -eq 'ETS' }
	If ($qos_traffic_smb_direct) {
		Write-Host "$Hostname - verified SMBDirect QoS traffic class"
	}
	Else {
		$qos_traffic_smb_direct = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $SmbDirectLabel -or $_.Priority -eq 3 } | Where-Object { $_.Name -notmatch $DefaultLabel }
		$qos_traffic_smb_direct | ForEach-Object {
			If ($_.Name -ne $SmbDirectLabel -or $_.Priority -ne 3 -or $_.Bandwidth -ne $SmbDirectPercent -or $_.Algorithm -ne 'ETS') {
				Write-Host "$Hostname - removing errant SMBDirect QoS traffic class: $($_.Name)"
				$_ | Remove-NetQosTrafficClass -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating SMBDirect QoS traffic class"
		New-NetQosTrafficClass -Name $SmbDirectLabel -Priority 3 -BandwidthPercentage $SmbDirectPercent -Algorithm ETS
	}

	# check for Cluster QoS traffic class
	Write-Host "$Hostname - checking Cluster QoS traffic class"
	$qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $ClusterLabel -and $_.Priority -eq 7 -and $_.Bandwidth -eq $ClusterPercent -and $_.Algorithm -eq 'ETS' }
	If ($qos_traffic_cluster) {
		Write-Host "$Hostname - verified Cluster QoS traffic class"
	}
	Else {
		$qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $ClusterLabel -or $_.Priority -eq 7 } | Where-Object { $_.Name -notmatch $DefaultLabel }
		$qos_traffic_cluster | ForEach-Object {
			If ($_.Name -ne $ClusterLabel -or $_.Priority -ne 7 -or $_.Bandwidth -ne $ClusterPercent -or $_.Algorithm -ne 'ETS') {
				Write-Host "$Hostname - removing errant Cluster QoS traffic class: $($_.Name)"
				$_ | Remove-NetQosTrafficClass -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating Cluster QoS traffic class"
		New-NetQosTrafficClass -Name $ClusterLabel -Priority 7 -BandwidthPercentage $ClusterPercent -Algorithm ETS
	}

	# check for Default QoS traffic class
	Write-Host "$Hostname - checking Default QoS traffic class"
	$qos_traffic_default = Get-NetQosTrafficClass | Where-Object { $_.Name -match $DefaultLabel -and $_.Priority -contains 0 -and $_.Bandwidth -eq $DefaultPercent -and $_.Algorithm -eq 'ETS' }
	If ($qos_traffic_default) {
		Write-Host "$Hostname - verified Default QoS traffic class"
	}
	Else {
		$qos_traffic_default = Get-NetQosTrafficClass | Where-Object { $_.Name -match $DefaultLabel -and $_.Priority -contains 0 -and $_.Bandwidth -lt $DefaultPercent -and $_.Algorithm -eq 'ETS' }
		If ($qos_traffic_default) {
			Write-Host "$Hostname - found Default QoS traffic class with unexpected bandwidth reservation: $($qos_traffic_default.Bandwidth)"
			Write-Host "$Hostname - ... the default QoS configuration for S2D should reserve $DefaultPercent% of bandwidth"
			Write-Host "$Hostname - ... review other QoS traffic classes on the system to determine if correct"
		}
		Else {
			Write-Host "$Hostname - unable to verify the default QoS traffic class..."
			Write-Host "$Hostname - ... review and correct the QoS configuration before continuing"
		}
	}

	# enable QoS classes 3 (SMB) and 7 (Cluster)
	Write-Host "$Hostname - setting QoS flow control enabled priorities: 3,7"
	Enable-NetQosFlowControl -Priority 3, 7
	Disable-NetQosFlowControl -Priority 0, 1, 2, 4, 5, 6

	# balance VFs across SRIOV adapters
	Write-Host "$Hostname - checking for balanced VFs on SRIOV-enabled adapters..."
	$sriov_adapters = Get-NetAdapter | Where-Object { ($_ | Get-NetAdapterAdvancedProperty).RegistryKeyword -eq '*SRIOV' }
	If ($sriov_adapters) {
		Write-Host "$Hostname - ...found $($sriov_adapters.Count) SRIOV-enabled adapters to review ..."
		# group SRIOV adapters by DriverDescription
		$sriov_groups = $sriov_adapters | Group-Object -Property 'DriverDescription'
		ForEach ($sriov_group in $sriov_groups) {
			Write-Host "$Hostname - ...getting VFs for adapters with driver: $($sriov_group.Name)"
			# reset VF count for group
			$sriov_vfs = 0
			# get current VF count from each adapter in group
			ForEach ($sriov_adapter in $sriov_group.Group) {
				# add adapter VF count to VF count for group
				$sriov_vfs += ($sriov_adapter | Get-NetAdapterSriov).NumVFs
			}
			Write-Host "$Hostname - ...found '$sriov_vfs' VFs for '$($sriov_group.Count)' adapters"
			$sriov_vfs_per_adapter = $sriov_vfs / ($sriov_group.Count)
			# verify correct VF count on each adapter in group
			ForEach ($sriov_adapter in $sriov_group.Group) {
				$sriov_vfs_on_adapter = ($sriov_adapter | Get-NetAdapterSriov).NumVFs
				If ($sriov_vfs_on_adapter -ne $sriov_vfs_per_adapter) {
					$sriov_adapter | Set-NetAdapterSriov -NumVFs $sriov_vfs_per_adapter
					Write-Host "$Hostname - ...updated '$($sriov_adapter.Description)' to '$sriov_vfs_per_adapter' VFs"
				}
				Else {
					Write-Host "$Hostname - ...found '$sriov_vfs_per_adapter' VFs on '$($sriov_adapter.Name)'"
				}
			}
		}
	}
}
Finally {
	# stop logging
	Stop-Transcript
}
