Begin {
	# create log folder path from environment
	Try {
		$LogFolderPath = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'PowerShell_transcript'
	}
	Catch {
		Exit 101
	}

	# create log file name from command path
	Try {
		$LogFileName = (Get-Item -Path $PSCommandPath).Name.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
	}
	Catch {
		Exit 102
	}

	# join paths
	Try {
		$Path = Join-Path -Path $LogFolderPath -ChildPath $LogFileName
	}
	Catch {
		Exit 103
	}

	# start transcript
	Try {
		Start-Transcript -Path $Path -Append
	}
	Catch {
		Exit 104
	}
}

Process {
	# define package provider names and versions
	$PackageProviders = @{
		NuGet = [System.Version]'2.8.5.208'
	}

	# define powershell module names and versions
	$Modules = @{
		PSWindowsUpdate = [System.Version]'2.2.0.2'
	}

	# install required providers
	:NextProviderName ForEach ($ProviderName in $PackageProviders.Keys) {
		# get package provider by name
		Try {
			$PackageProvider = Get-PackageProvider -Name $ProviderName
		}
		Catch {
			Write-Warning -Message "could not retrieve package provider: $ProviderName"
			Return $_
		}

		# if package provider found with required or later version
		If ($PackageProvider -and $PackageProvider.Version -ge $PackageProviders[$ProviderName]) {
			Write-Verbose -Verbose -Message "found package provider '$ProviderName' with version: $($PackageProvider.Version)"
			Continue :NextProviderName
		}

		# install package provider to all users scope
		Try {
			Install-PackageProvider -Name $ProviderName -Scope 'AllUsers' -Force
		}
		Catch {
			Write-Warning -Message "could not install package provider: $ProviderName"
			Return $_
		}
	}

	# install required modules
	:NextModuleName ForEach ($ModuleName in $Modules.Keys) {
		# get module by name
		Try {
			$Module = Get-Module -Name $ModuleName -ListAvailable
		}
		Catch {
			Write-Warning -Message "could not retrieve module: $ModuleName"
			Return $_
		}

		# if module found with required or later version
		If ($Module -and $Module.Version -ge $Modules[$ModuleName]) {
			Write-Verbose -Verbose -Message "found module '$ModuleName' with version: $($Module.Version)"
			Continue :NextModuleName
		}

		# install module to all users scope
		Try {
			Install-Module -Name $ModuleName -Scope 'AllUsers' -Force -AllowClobber
		}
		Catch {
			Write-Warning -Message "could not install module: $ModuleName"
			Return $_
		}
	}

	# update windows
	Try {
		Install-WindowsUpdate -NotTitle 'Preview' -AcceptAll -AutoReboot
	}
	Catch {
		Write-Warning -Message "could not install updates: $($_.ToString())"
		Return $_
	}

}

End {
	Try {
		Stop-Transcript
	}
	Catch {
		Exit 201
	}
}
