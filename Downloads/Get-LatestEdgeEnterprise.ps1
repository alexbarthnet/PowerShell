[CmdletBinding(DefaultParameterSetName = 'Default')]
Param (
	[Parameter(ParameterSetName = 'Default')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Mandatory = $false)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Uri = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
)

# get JSON
Try {
	$JsonFromRest = Invoke-RestMethod -Uri $Uri
}
Catch { 
	Return $_
}

# filter JSON
$EdgeMsi = $JsonFromRest.Where({ $_.Product -eq 'Stable' }).Releases | Sort-Object -Property 'ProductVersion' | Where-Object { $_.Architecture -eq 'x64' -and $_.Platform -eq 'Windows' -and $_.Artifacts } | Select-Object -Last 1
$EdgeCab = $JsonFromRest.Where({ $_.Product -eq 'Policy' }).Releases | Sort-Object -Property 'ProductVersion' | Where-Object { $_.Architecture -eq 'any' -and $_.Platform -eq 'Any' -and $_.Artifacts } | Select-Object -Last 1

# if Edge MSI file not found in JSON...
If ($null -eq $EdgeMsi) {
	Write-Warning -Message "could not locate information required to download MSI file in response from URI: $Uri"
}
Else {
	$DestinationMsi = Join-Path -Path $Path -ChildPath $EdgeMsi.Artifacts.Location.Split('/')[-1]
}

# if Edge CAB file not found in JSON...
If ($null -eq $EdgeCab) {
	Write-Warning -Message "could not locate information required to download CAB file in response from URI: $Uri"
}
Else {
	$DestinationCab = Join-Path -Path $Path -ChildPath $EdgeCab.Artifacts.Location.Split('/')[-1]
}

# if Edge MSI file exists and Force parameter not set...
If ((Test-Path -Path $DestinationMsi -PathType 'Leaf') -and -not $Force) {
	# get file hash of existing Edge MSI file using algorithm from JSON
	Try {
		$FileHashMsi = Get-FileHash -Path $DestinationMsi -Algorithm $EdgeMsi.Artifacts.HashAlgorithm
	}
	Catch {
		Return $_
	}
	# if hashes match...
	If ($FileHashMsi.Hash -eq $EdgeMsi.Artifacts.Hash) {
		# skip downloading Edge MSI file
		$SkipMSI = $true
		# report version found
		Write-Verbose -Verbose -Message "Found existing Edge MSI file with latest product version: $($EdgeMsi.ProductVersion)"
	}
} 

# if Edge CAB file exists and Force parameter not set...
If ((Test-Path -Path $DestinationCab -PathType 'Leaf') -and -not $Force) {
	# get file hash of existing Edge CAB file using algorithm from JSON
	Try {
		$FileHashCab = Get-FileHash -Path $DestinationCab -Algorithm $EdgeCab.Artifacts.HashAlgorithm
	}
	Catch {
		Return $_
	}
	# if hashes match...
	If ($FileHashCab.Hash -eq $EdgeCab.Artifacts.Hash) {
		# skip downloading Edge CAB file
		$SkipCab = $true
		# report version found
		Write-Verbose -Verbose -Message "Found existing Edge CAB file with latest product version: $($EdgeCab.ProductVersion)"
	}
} 

# if skip MSI not set...
If (!$local:SkipMsi) {
	# download MSI file with BITS
	Start-BitsTransfer -Source $EdgeMsi.Artifacts.Location -Destination $DestinationMsi
	# report version of MSI file
	Write-Verbose -Verbose -Message "Downloaded new Edge MSI file with latest product version: $($EdgeMsi.ProductVersion)"
}

# if we should get a new policy, get it!
If (!$local:SkipCab) {
	# download CAB file with BITS
	Start-BitsTransfer -Source $EdgeCab.Artifacts.Location -Destination $DestinationCab
	# report version of CAB file
	Write-Verbose -Verbose -Message "Downloaded new Edge CAB file with latest product version: $($EdgeCab.ProductVersion)"
}