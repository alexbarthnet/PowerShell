[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 1)]
	[string]$FileName = 'ServiceTags_Public.json'
)

# define local objects
$file_down = $true
$file_path = Join-Path -Path $Destination -ChildPath $FileName

# retrieve information on latest release
$uri_path = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519'
$uri_link = ((Invoke-WebRequest -Uri $uri_path -UseBasicParsing -MaximumRedirection 0).Links | Where-Object {$_.href -match "\.json$" -and $_.target} | Sort-Object 'href' -Unique | Select-Object -Last 1).href

# check file
If (Test-Path $file_path) {
	$uri_size = (Invoke-WebRequest -Uri $uri_link -UseBasicParsing -Method Head).Headers.'Content-Length'
	If ($uri_size -eq (Get-ItemProperty $file_path).Length -and -not $Force) {
		Write-Output 'Size of most recent download matches current download size, skipping!'
		$file_down = $false
	}
}

# download file
If ($file_down) {
	# download latest release to temp file
	Invoke-WebRequest -Uri $uri_link -UseBasicParsing -OutFile $file_path
}
