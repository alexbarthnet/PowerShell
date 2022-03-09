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
	[string]$NetworkCsv = (Join-Path -Path $FilePath -ChildPath "$($Hostname)-net.csv"),
	[Parameter()]
	[string]$ClusterLabel = 'Cluster',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$ClusterPercent = 1,
	[Parameter()]
	[string]$StorageLabel = 'SMBDirect',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$StoragePercent = 50,
	[Parameter()]
	[string]$DefaultLabel = 'Default',
	[Parameter()][ValidateRange(1, 100)]
	[uint16]$DefaultPercent = (100 - $StoragePercent - $ClusterPercent )
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

	# import CSV
	$map_network = Import-Csv -Path $NetworkCsv | Where-Object { $_.Host -eq $Hostname }

	# get the VM paths from the network CSV
	$map_network | Where-Object { $_.VmPath -and $_.VhdPath } | ForEach-Object {
		# check virtual hard disk path
		$host_vmpath = $_.VmPath
		If (Test-Path -Path $host_vmpath) {
			$host_vmpath = $_.VmPath
		}
		ElseIf (Test-Path -Path (Get-VMHost).VirtualMachinePath) {
			$host_vmpath = (Get-VMHost).VirtualMachinePath
		}
		Else {
			$host_vmpath = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
		}
		# check virtual hard disk path
		$host_vhdpath = $_.VhdPath
		If (Test-Path -Path $host_vhdpath) {
			$host_vhdpath = $_.VhdPath
		}
		ElseIf (Test-Path -Path (Get-VMHost).VirtualHardDiskPath) {
			$host_vhdpath = (Get-VMHost).VirtualHardDiskPath
		}
		Else {
			$host_vhdpath = 'C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks'
		}
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

	# check for SMB QoS policy
	Write-Host "$Hostname - checking SMB QoS policy"
	$qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq $StorageLabel -and $_.PriorityValue -eq 3 -and $_.NetDirectPort -eq 445 }
	If ($qos_policy_storage) {
		Write-Host "$Hostname - verified SMB QoS policy"
	}
	Else {
		$qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq $StorageLabel -or $_.NetDirectPort -eq 445 }
		$qos_policy_storage | ForEach-Object {
			If ($_.Name -ne $StorageLabel -or $_.PriorityValue -ne 3 -or $_.NetDirectPort -ne 445 ) {
				Write-Host "$Hostname - removing errant SMB QoS policy: $($_.Name)"
				$_ | Remove-NetQosPolicy -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating SMB QoS policy"
		New-NetQosPolicy -Name $StorageLabel -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445
	}

	# check for Cluster QoS policy
	Write-Host "$Hostname - checking Cluster QoS policy"
	$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterLabel -and $_.PriorityValue -eq 7 -and $_.Template -eq $ClusterLabel }
	If ($qos_policy_cluster) {
		Write-Host "$Hostname - verified Cluster QoS policy"
	}
	Else {
		$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq $ClusterLabel -or $_.PriorityValue -eq 7 -or $_.Template -eq $ClusterLabel }
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
		$qos_policy_default = Get-NetQosPolicy | Where-Object { $_.Name -eq $DefaultLabel -or $_.PriorityValue -eq 0 -or $_.Template -eq $DefaultLabel }
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
	Write-Host "$Hostname - checking SMB QoS traffic class"
	$qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $StorageLabel -and $_.Priority -eq 3 -and $_.Bandwidth -eq $StoragePercent -and $_.Algorithm -eq 'ETS' }
	If ($qos_traffic_storage) {
		Write-Host "$Hostname - verified SMB QoS traffic class"
	}
	Else {
		$qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq $StorageLabel -or $_.Priority -eq 3 } | Where-Object { $_.Name -notmatch $DefaultLabel }
		$qos_traffic_storage | ForEach-Object {
			If ($_.Name -ne $StorageLabel -or $_.Priority -ne 3 -or $_.Bandwidth -ne $StoragePercent -or $_.Algorithm -ne 'ETS') {
				Write-Host "$Hostname - removing errant SMB QoS traffic class: $($_.Name)"
				$_ | Remove-NetQosTrafficClass -Confirm:$false
			}
		}
		Write-Host "$Hostname - creating SMB QoS traffic class"
		New-NetQosTrafficClass -Name $StorageLabel -Priority 3 -BandwidthPercentage $StoragePercent -Algorithm ETS
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

}
Finally {
	# stop logging
	Stop-Transcript
}
