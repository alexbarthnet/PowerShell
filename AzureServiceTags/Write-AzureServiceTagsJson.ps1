[CmdletBinding(DefaultParameterSetName = 'Default')]
Param (
	# uri of Azure service tag files
	[Parameter(DontShow)]
	[string]$Uri = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519',
	# pattern for Azure service tag files
	[Parameter(DontShow)]
	[string]$Pattern = 'ServiceTags_Public_\d*\.json$',
	# path to Azure service tag file
	[Parameter(Position = 0, Mandatory)]
	[string]$Path,
	# switch to force new file
	[Parameter(Position = 1)]
	[switch]$Force
)

# retrieve web request
Try {
	$WebRequest = Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0
}
Catch {
	Write-Verbose -Verbose -Message "calling Invoke-WebRequest on uri: $Uri"
	Return $_
}

# get Uri for JSON file
$UriForJson = $WebRequest.Links.href -match $Pattern | Select-Object -Unique

# check link
If ([string]::IsNullOrEmpty($UriForJson)) {
	Write-Warning -Message "could not find link that matched pattern: $Pattern"
	Return
}

# if local file exists and Force not set
If ([System.IO.File]::Exists($Path) -and -not $Force) {
	# retrieve headers
	Try {
		$Headers = Invoke-WebRequest -Uri $UriForJson -UseBasicParsing -Method Head
	}
	Catch {
		Write-Warning -Message "could not call Invoke-WebRequest for headers on uri: $UriForJson"
		Return $_
	}

	# get timestamp from headers
	Try {
		$UriDateTime = [System.DateTime]$Headers.Headers.'Last-Modified'
	}
	Catch {
		Write-Warning -Message "could not create DateTime from Last-Modified in headers: $($Headers.Headers.'Last-Modified')"
		Return $_
	}

	# get file
	Try {
		$File = Get-Item -Path $Path
	}
	Catch {
		Write-Warning -Message "could not call Get-Item on path: $Path"
		Return $_
	}

	# if file is not older than headers...
	If ($File.LastWriteTime -ge $UriDateTime) {
		Write-Verbose -Verbose -Message 'LastWriteTime of file newer than Last-Modified in headers, skipping!'
		Return
	}
}

# download file at link to path
Try {
	Start-BitsTransfer -Source $UriForJson -Destination $Path
}
Catch {
	Write-Verbose -Verbose -Message "calling Start-BitsTransfer on uri: $UriForJson"
	Return $_
}

# declare complete
Write-Verbose -Verbose -Message "downloaded lastest copy of JSON from uri: $UriForJson"
