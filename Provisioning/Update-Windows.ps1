Begin {
	# define transcript file
	$log_root = [System.Environment]::GetFolderPath('CommonApplicationData')
	$log_file = (Split-Path -Path $PSCommandPath -Leaf).Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
	$log_path = Join-Path -Path $log_root -Child $log_file

	# force close open transcript and clear errors
	Try { Stop-Transcript; $Error.Clear() } Catch [System.Management.Automation.PSInvalidOperationException] { $Error.Clear() }

	# start transcript
	Start-Transcript -Path $log_path -Append -Force
}

Process {
	# define package provider names and versions
	$ps_providers = @{
		NuGet = [System.Version]'2.8.5.208'
	}

	# define powershell module names and versions
	$ps_modules = @{
		PSWindowsUpdate = [System.Version]'2.2.0.2' 
	}

	# install required providers
	ForEach ($provider in $ps_providers.Keys) {
		$ps_provider = Get-PackageProvider -Name $provider
		If (($null -eq $ps_provider) -or ($ps_provider.Version -lt $ps_providers[$provider])) {
			Try {
				Install-PackageProvider -Name $provider -Scope 'AllUsers' -Force
			}
			Catch {
				Write-Error "Installing package '$provider'"
				Return
			}
		}
	}

	# install required modules
	ForEach ($module in $ps_modules.Keys) {
		$ps_module = Get-Module -ListAvailable -Name $module
		If (($null -eq $ps_module) -or ($ps_module.Version -lt $ps_modules[$module])) {
			Try {
				Install-Module -Name $module -Scope 'AllUsers' -Force -AllowClobber
			}
			Catch {
				Write-Error "Installing module '$module'"
				Return
			}
		}
	}

	# update windows
	Install-WindowsUpdate -NotTitle 'Preview' -AcceptAll -AutoReboot
}

End {
	Stop-Transcript
}
