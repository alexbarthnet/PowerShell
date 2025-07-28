<#
.SYNOPSIS
Writes the content from Invoke-WebRequest to a defined path.

.DESCRIPTION
Writes the content from Invoke-WebRequest to a defined path.

.PARAMETER Uri
The path to the URL that contains the desired content. The path must have a trailing forward slash if the constructed URI points to a folder instead of a file.

.PARAMETER Path
The path to the folder to contain the content files.

.PARAMETER FilePath
The path to content file for the local system. The default value is a text file in the provided path with name of the local host.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Write-UriContentToPath.ps1 -Uri 'https://example.com/host/' -Path 'C:\Content\host'

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# uri to query
	[Parameter(Position = 0, Mandatory = $True)]
	[uri]$Uri,
	# path for all script host files
	[Parameter(Position = 1, Mandatory = $True)]
	[string]$Path,
	# path for local script host file
	[Parameter(Position = 2)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath "$HostName.txt")
)

begin {
	function Get-UriWithIPAddressFromUriWithHostname {
		param(
			# a URI object or a string that can be cast a URI object
			[Parameter(Mandatory = $true)]
			[uri]$Uri,
			[Parameter(DontShow)][ValidateScript({ [Microsoft.DnsClient.Commands.RecordType].IsEnumDefined($_) })]
			# the DNS record type to resolve
			[string]$Type = 'A'
		)

		# get DnsSafeHost from Uri
		try {
			$DnsSafeHost = $Uri.DnsSafeHost
		}
		catch {
			Write-Warning "could not retrieve DnsSafeHost from Uri: $($Uri.AbsoluteUri)"
			return $_
		}

		# define parameters
		$ResolveDnsName = @{
			Name        = $DnsSafeHost
			Type        = $Type
			Server      = '8.8.8.8'
			DnsOnly     = $True
			NoHostsFile = $True
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# resolve DnsSafeHost
		try {
			$DnsName = Resolve-DnsName @ResolveDnsName
		}
		catch {
			Write-Warning "could not resolve DnsSafeHost '$DnsSafeHost' from Uri: $($Uri.AbsoluteUri)"
			return $_
		}

		# filter results and extract IPAddress
		$IPAddress = $DnsName.Where({ $_.Type -eq $Type }).IPAddress

		# check for
		switch ($IPAddress.Count) {
			# if 0 records in IPAddress...
			0 {
				# warn and return null
				Write-Warning "could not resolve any '$Type' records from DNS for DnsSafeHost '$DnsSafeHost' from Uri: $($Uri.AbsoluteUri)"
				return $null
			}
			# if 1 record in IPaddress...
			1 {
				# break out of switch and continue
				break
			}
			# if more than 1 record in IPaddress...
			Default {
				# select first address and continue
				$IPAddress = $IPAddress[0]
			}
		}

		# report IP address
		Write-Host "Resolved IP address '$IPAddress' from URL: $($Uri.AbsoluteUri)"

		# update URI with IP address
		try {
			$Uri = [Uri]$Uri.AbsoluteUri.Replace($Uri.DnsSafeHost, $IPAddress)
			Write-Host "Constructed host URL from IP: '$($Uri.AbsoluteUri)'"
		}
		catch {
			Write-Warning "Error constructing host URL from IP: '$($Uri.AbsoluteUri)'"
			return $_
		}

		# return updated URI
		return $Uri
	}

	# if path not found...
	if (![System.IO.Directory]::Exists($Path)) {
		# create path
		try {
			$null = New-Item -Path $Path -Force -ItemType 'Directory' -ErrorAction 'Stop'
		}
		catch {
			Write-Warning "could not create path: $local:Path"
			return $_
		}
	}

	# if file not found...
	if (![System.IO.File]::Exists($local:FilePath)) {
		# create script host file
		try {
			$null = New-Item -Path $local:FilePath -Force -ItemType 'File' -ErrorAction 'Stop'
		}
		catch {
			Write-Warning "could not create script host file: '$local:FilePath"
			return $_
		}
	}
}

process {
	# get content of hosts file
	try {
		$Content = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	catch {
		Write-Warning "could not retrieve hosts file on host: $local:Hostname"
		return $_
	}

	# process hosts file content
	:NextLine foreach ($Line in $Content) {
		# if line is commented out...
		if ($Line.StartsWith('#')) {
			# continue to the next line
			continue NextLine
		}
		# if line ends with the hostname...
		if ($Line -match "\s$($Uri.DnsSafeHost)$") {
			# set URI with IP address required
			$UriWithIPAddressRequired = $true
		}
	}

	# retrieve original host
	$DnsSafeHost = $Uri.DnsSafeHost

	# if URI with IP address required...
	if ($local:UriWithIPAddressRequired) {
		# retrieve updated URI with hostname for ADFS service replaced with IP address of ADFS service to address hosts file configuration for non-split-brain DNS
		try {
			$Uri = Get-UriWithIPAddressFromUriWithHostname -Uri $local:Uri
		}
		catch {
			Write-Warning 'could not create new Uri with IP address from original Uri'
			return $_
		}
	}

	# define parameters for Invoke-WebRequest
	$InvokeWebRequest = @{
		Uri                = $Uri
		Headers            = @{ 'host' = $DnsSafeHost }
		UseBasicParsing    = $true
		MaximumRedirection = 0
		ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve content from URI
	try {
		$WebRequest = Invoke-WebRequest @InvokeWebRequest
	}
	catch {
		Write-Warning "could not retrieve response from URL: $($Uri.AbsoluteUri)"
		return $_
	}

	# if content empty...
	if ([string]::IsNullOrEmpty($WebRequest.Content)) {
		Write-Warning "found empty content at URL: $($Uri.AbsoluteUri)"
		return
	}

	# parse content from URI
	try {
		$ContentFromUri = $WebRequest.Content.Trim()
	}
	catch {
		Write-Warning "could not parse response from URL: $($Uri.AbsoluteUri)"
		return $_
	}

	# retrieve content from file
	try {
		$ContentFromFile = Get-Content -Path $FilePath
	}
	catch {
		Write-Warning "could not retrieve content from file: '$FilePath'"
		return $_
	}

	# if content from file is present and matches content from URI...
	if (![string]::IsNullOrEmpty($ContentFromFile) -and $ContentFromFile -eq $ContentFromUri) {
		Write-Host "Verified file: content from file matches content from URI: $ContentFromUri"
		return
	}

	# update host name
	try {
		Set-Content -Path $FilePath -Value $ContentFromUri
	}
	catch {
		Write-Warning "could not update content of file: '$FilePath"
		return $_
	}

	# declare state
	Write-Host "Updated file: replaced '$ContentFromFile' content from file with content from URI: $ContentFromUri"
}
