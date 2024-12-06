# define path to KMS settings
$Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'

# retrieve item containing KMS settings
Try {
	$Item = Get-Item -Path $Path
}
Catch {
	Return $_
}

# if KMS name defined in registry...
If ($Item.Property.Contains('KeyManagementServiceName')) {
	# remove KMS name
	Try {
		$Item | Remove-ItemProperty -Name 'KeyManagementServiceName' -Verbose
	}
	Catch {
		Return $_
	}
}

# if KMS port defined in registry...
If ($Item.Property.Contains('KeyManagementServicePort')) {
	# remove KMS port
	Try {
		$Item | Remove-ItemProperty -Name 'KeyManagementServicePort' -Verbose
	}
	Catch {
		Return $_
	}
}

Start-Process -NoNewWindow -Wait -FilePath "$env:systemroot\system32\cscript.exe" -ArgumentList "$env:systemroot\system32\slmgr.vbs", "/ato"
