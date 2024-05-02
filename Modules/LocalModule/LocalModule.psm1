Function Get-ComputersFromParams {
	<#
	.SYNOPSIS
	Creates a list of computers from inputs.

	.DESCRIPTION
	Creates a list of computers from inputs. Called by multiple functions in this module.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies one or more remote clusters.

	.PARAMETER Cluster
	Instructs the command to check if the local machine is a cluster and, if so, to execute on all members of the cluster.

	.INPUTS
	None.

	.OUTPUTS
	An array of computer hostnames.

	#>

	[CmdletBinding()]
	param (
		[Parameter(Position = 0)][AllowEmptyCollection()]
		[string[]]$ComputerName,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$ClusterName,
		[Parameter(Position = 2)]
		[switch]$Cluster
	)

	# define empty array
	$ComputersFromParams = @()

	# retrieve local cluster name if requested
	If ($Cluster) {
		$ClusSvc = $null
		$ClusSvc = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
		If ($null -ne $ClusSvc) {
			Try { $ClusterName += (Get-Cluster).Name }
			Catch { Write-Host 'ERROR: could not retrieve local cluster name' }
		}
		Else {
			Write-Host 'ERROR: cluster service is not running on local host'
		}
	}

	# add computers to array from ClusterName argument
	If ($ClusterName.Count) {
		ForEach ($cluster_name in $ClusterName) {
			Try {
				$cluster_nodes = $null
				$cluster_nodes = Invoke-Command -ComputerName $cluster_name -ScriptBlock { (Get-ClusterNode).Name }
				$cluster_nodes | ForEach-Object { $ComputersFromParams += $_ }
			}
			Catch {
				Write-Host "ERROR: could not retrieve list of cluster nodes from '$cluster_name'"
			}
		}
	}

	# add computers to array from ComputerName argument
	If ($ComputerName) {
		$ComputerName | ForEach-Object { $ComputersFromParams += $_ }
	}

	# remove duplicate computers
	$ComputersFromParams | Select-Object -Unique
}

Function Import-LocalModule {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $True, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
		[object[]]$InputObject
	)

	Begin {
		# verify function run as admin
		If ([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains 'S-1-5-32-544' -eq $false) {
			Write-Host 'ERROR: this function must be run as an administrator, exiting!'
			Return
		}
	}

	# process
	Process {
		# retrieve module names
		$psm1_names = @()
		$psm1_names += Install-LocalModule -InputObject $InputObject -CalledByImportLocalModule
		
		# import modules by name
		ForEach ($psm1_name in $psm1_names) {
			Import-Module -Global -Name $psm1_name -Force -Verbose
		}
	}
}

Function Install-LocalModule {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $True, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
		[object[]]$InputObject,
		[Parameter(Position = 1)]
		[string[]]$ComputerName,
		[Parameter(Position = 2)]
		[string[]]$ClusterName,
		[Parameter(Position = 3)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[switch]$CalledByImportLocalModule
	)

	Begin {
		# verify function run as admin
		If ([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains 'S-1-5-32-544' -eq $false) {
			Write-Host 'ERROR: this function must be run as an administrator, exiting!'
			Return
		}

		# get computer names
		$module_computers = @()
		$module_computers += Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}

	# process
	Process {
		# create empty array for PSM1 files
		$input_files = @()

		# process input
		ForEach ($Object in $InputObject) {
			switch ($true) {
				{ $Object -is [System.IO.DirectoryInfo] } { $input_files += Get-ChildItem -Path $Object }
				{ $Object -is [System.IO.FileInfo] } { $input_files += $Object }
				{ $Object -is [System.String] } { $input_files += Get-Item -Path $Object }
			}
		}

		# filter input
		$psm1_files = $input_files | Where-Object { $_.Extension -eq '.psm1' }

		# process files
		ForEach ($psm1 in $psm1_files) {
			# define module base
			$module_base = $psm1.BaseName

			# define module path
			$module_path = "$([System.Environment]::GetFolderPath('ProgramFiles'))\WindowsPowerShell\Modules\$module_base"

			# retrieve module files
			$module_files = Get-ChildItem -Path $psm1.Directory | Where-Object { $_.BaseName -eq $module_base }

			# copy module files to module path
			If ($module_computers.Count -gt 0) {
				ForEach ($module_computer in $module_computers) {
					# define remote computer
					Write-Output "Installing '$module_base' on '$module_computer'"
					# define path on remote computer
					$module_path = Invoke-Command -ComputerName $module_computer -ScriptBlock { "$([System.Environment]::GetFolderPath('ProgramFiles'))\WindowsPowerShell\Modules\$using:module_base"}
					# verify path on remote computer
					Invoke-Command -ComputerName $module_computer -ScriptBlock { If ((Test-Path -Path $using:module_path ) -eq $false) { $null = New-Item -ItemType 'Directory' -Path $using:module_path } }
					# copy files to path on remote computer
					$module_files | Copy-Item -ToSession (New-PSSession -ComputerName $module_computer) -Destination $module_path -Verbose
				}
			}
			Else {
				# define path on local computer
				$module_path = "$([System.Environment]::GetFolderPath('ProgramFiles'))\WindowsPowerShell\Modules\$module_base"
				# verify path on local computer
				If ((Test-Path -Path $module_path ) -eq $false) { $null = New-Item -ItemType 'Directory' -Path $module_path }
				# copy files to path on local computer
				$module_files | Copy-Item -Destination $module_path -Verbose
			}

			# return installed module name if function was called by Import-LocalModule
			If ($CalledByImportLocalModule) {
				Return $psm1.BaseName
			}
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Import-LocalModule'
	'Install-LocalModule'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport