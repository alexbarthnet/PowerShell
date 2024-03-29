<#
.SYNOPSIS
Runs a script to configure the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D).

.DESCRIPTION
Runs a script to configure the Windows features on one or more Hyper-V hosts that will be or are running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

This parent script pushes another script and any configuration files to each Hyper-V host defined in a CSV then starts the script using PowerShell Remoting.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

Param(
	[Parameter(DontShow = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$ScriptFile = 'Update-S2D-2-Features.ps1',
	[Parameter(DontShow = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$ScriptPath = (Split-Path -Path $PSCommandPath -Parent),
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$HostCsv,
	[string[]]$HostName
)

# get array of file names
$file_names = @((Join-Path -Path $ScriptPath -ChildPath $ScriptFile), $HostCsv)

# import file
$host_list = @()
$host_list += Import-Csv -Path $HostCsv

# filter host information
If ($HostName) {
	# process hostnames
	$host_temp = @()
	ForEach ($host_name in $HostName) {
		$host_temp += $host_list | Where-Object { $_.Host -eq $host_name }
	}
	$host_list = $host_temp
}

# process the cluster mapping file
$host_list | Sort-Object 'Host' -Unique | ForEach-Object {
	# get base strings for this pass
	$host_name = $_.Host

	# declare start
	Write-Host ("======================== $host_name ========================")

	# clear the DNS cache then resolve hostname
	Write-Host "$host_name - resolving host..."
	Do {
		Clear-DnsClientCache
		$dns_found = $null
		$dns_found = Resolve-DnsName -Name $host_name -ErrorAction 'SilentlyContinue'
	} Until ($dns_found)

	# verify connection to remote host
	Write-Host "$host_name - checking host..."
	Do {
		$host_alive = $false
		$host_alive = Test-NetConnection -ComputerName $host_name -CommonTCPPort 'WINRM' -InformationLevel 'Quiet'
	} Until ($host_alive)

	# close existing sessions
	Write-Host "$host_name - closing any existing sessions..."
	$pss_old = $null
	$pss_old = Get-PSSession -ComputerName $host_name
	If ($pss_old) {
		$pss_old | Remove-PSSession
	}

	# start session for files
	Write-Host "$host_name - starting file session..."
	$pss_files = $null
	$pss_files = New-PSSession -ComputerName $host_name

	# create and define remote directory
	Write-Host "$host_name - creating directory..."
	$host_path = Invoke-Command -Session $pss_files -ScriptBlock {
		$host_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		New-Item -Path $host_temp -Name 'hv-setup' -ItemType 'Directory' -Force
	}

	# copy files for alias configuration
	Write-Host "$host_name - copying files..."
	$file_names | Copy-Item -ToSession $pss_files -Destination $host_path

	# close session for files
	Write-Host "$host_name - ending file session..."
	Remove-PSSession -Session $pss_files

	# run the scripts
	Write-Host "$host_name - starting script session..."
	$pss_options = New-PSSessionOption -OutputBufferingMode 'Drop'
	$pss_scripts = Invoke-Command -ComputerName $host_name -InDisconnectedSession -SessionOption $pss_options -ScriptBlock {
		Set-Location -Path $using:host_path
		Invoke-Expression -Command (Join-Path -Path $using:host_path -ChildPath $using:ScriptFile)
	}

	# declare session name
	Write-Host "$host_name - started script session: $($pss_scripts.Name)"
}
