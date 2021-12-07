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
		$psm1_names += Install-LocalModule -InputObject $InputObject -Import
		
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
		[Parameter(DontShow)]
		[switch]$Import
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
			# define module path
			$module_path = "$([System.Environment]::GetFolderPath('ProgramFiles'))\WindowsPowerShell\Modules\$($psm1.BaseName)"

			# verify module path
			If (Test-Path -Path $module_path) {
				Write-Host "Found folder for module: '$module_path'"
			}
			Else {
				$null = New-Item -ItemType 'Directory' -Path $module_path -Force
				Write-Host "Created folder for module: '$module_path'"
			}

			# retrieve module files
			$module_files = Get-ChildItem -Path $psm1.Directory | Where-Object { $_.BaseName -eq $psm1.BaseName }

			# copy module files to module path
			$module_files | Copy-Item -Destination $module_path -Verbose

			# 
			If ($Import) {
				$psm1.BaseName
			}
		}
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Import-LocalModule'
$functions_to_export += 'Install-LocalModule'

# export module members
Export-ModuleMember -Function $functions_to_export