[CmdletBinding()]
param (
    [Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
    [string]$Path = (Get-Location),
    [Parameter(Position = 1)]
    [switch]$Force,
    [Parameter(DontShow)]
    [string]$BaseUri = 'https://aka.ms/hcireleaseimage',
    [Parameter(DontShow)]
    [datetime]$DateTime = [System.DateTime]::Now,
    [Parameter(DontShow)]
    [datetime]$StartTime = [System.DateTime]::Now
)

begin {
    function Expand-Uri {
        [CmdletBinding()]
        param (
            [string]$Uri
        )

        # define parameters for Invoke-WebRequest
        $InvokeWebRequest = @{
            Uri                = $Uri
            Method             = 'Head'
            UseBasicParsing    = $true
            MaximumRedirection = 0
            ErrorAction        = [System.Management.Automation.ActionPreference]::SilentlyContinue
        }

        # get web request object
        $WebRequest = Invoke-WebRequest @InvokeWebRequest

        # check object
        if ($WebRequest -isnot [Microsoft.PowerShell.Commands.WebResponseObject]) {
            throw $_
        }

        # if status is redirected and location found...
        if ($WebRequest.StatusCode -in '301', '302' -and -not [string]::IsNullOrEmpty($WebRequest.Headers.Location)) {
            # ...expand location
            Expand-Uri -Uri $WebRequest.Headers.Location
        }
        else {
            return $Uri
        }
    }

    function Get-HeadersFromUri {
        [CmdletBinding()]
        param (
            [string]$Uri
        )

        # define parameters for Invoke-WebRequest
        $InvokeWebRequest = @{
            Uri                = $Uri
            Method             = 'Head'
            UseBasicParsing    = $true
            MaximumRedirection = 0
            ErrorAction        = [System.Management.Automation.ActionPreference]::SilentlyContinue
        }

        # retrieve response from URI
        $WebRequest = Invoke-WebRequest @InvokeWebRequest

        # return headers
        return $WebRequest.Headers
    }

    function Get-FileByteHash {
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path,
            [ValidateSet('MD5', 'SHA1', 'SHA256')]
            [string]$Algorithm = 'SHA256'
        )

        # get file content as bytes
        try {
            $Bytes = Get-Content -Path $Path -Raw -Encoding Byte
        }
        catch {
            throw $_
        }

        # create hash object
        try {
            switch ($Algorithm) {
                'MD5' {
                    $HashAlgorithm = [System.Security.Cryptography.MD5]::Create()
                }
                'SHA1' {
                    $HashAlgorithm = [System.Security.Cryptography.SHA1]::Create()
                }
                'SHA256' {
                    $HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
                }
            }
        }
        catch {
            throw $_
        }

        # get hash of bytes
        try {
            $Hash = $HashAlgorithm.ComputeHash($Bytes)
        }
        catch {
            throw $_
        }

        # convert hash to base64
        try {
            $String = [System.Convert]::ToBase64String($Hash)
        }
        catch {
            throw $_
        }

        # return string
        return $String
    }
}

process {
    # report stat
    WRite-Host "locating URI for latest Azure Local ISO..."

    # while location empty...
    :NextUri while ([System.String]::IsNullOrEmpty($Location)) {
        # if datetime is over six months ago...
        if (($StartTime - $DateTime) -gt ($StartTime - $StartTime.AddMonths(-6))) {
            # warn and return
            Write-Warning -Message 'could not locate valid URI with allowed 6 month limit'
            return
        }

        # define URI with two digit year and month
        $Uri = '{0}/{1}' -f $BaseUri, $DateTime.ToString('yyMM')

        # update datetime to previous month
        $DateTime = $DateTime.AddMonths(-1)

        # declare URI
        Write-Host "...checking URI: $Uri"

        # get file from uri
        try {
            $Headers = Get-HeadersFromUri -Uri $Uri
        }
        catch {
            throw $_
        }

        # if headers missing a location...
        if ([System.String]::IsNullOrEmpty($Headers.Location)) {
            # continue to next uri
            Write-Verbose -Message "no location found in headers for URI: $Uri"
            continue NextUri
        }

        # if location not an ISO file...
        if (!$Headers.Location.EndsWith('.iso', [System.StringComparison]::InvariantCultureIgnoreCase)) {
            # continue to next uri
            Write-Verbose -Message "no location found in headers for URI: $Uri"
            continue NextUri
        }

        # if this far...
        $Location = $Headers.Location

        # report location
        Write-Host "...located URI for ISO: $Location"
    }

    # expand location
    try {
        $UriForBits = Expand-Uri -Uri $Location
    }
    catch {
        throw $_
    }

    # get file from uri
    try {
        $Headers = Get-HeadersFromUri -Uri $UriForBits
    }
    catch {
        throw $_
    }

    # retrieve file name from headers
    $ChildPath = Split-Path -Path $UriForBits -Leaf

    # create local path
    $FilePath = Join-Path -Path $Path -ChildPath $ChildPath

    # if file exists...
    if (Test-Path -Path $FilePath -PathType 'Leaf') {
        # if force set...
        if ($Force.IsPresent) {
            Write-Warning -Message "overwriting existing file: the Force parameter is present and the '$ChildPath' file was found in '$Path' path"
        }
        # if remote hash is available...
        elseif ($Headers.ContainsKey('Content-MD5')) {
            # get local hash
            try {
                $FileByteHash = Get-FileByteHash -Path $FilePath -Algorithm 'MD5'
            }
            catch {
                throw $_
            }
            # if local hash matches remote hash...
            if ($FileByteHash -eq $Headers['Content-MD5']) {
                Write-Host 'skipping download: existing file hash matches value in Content-MD5 header'
                return
            }
        }
        # if remote length is available...
        elseif ($Headers.ContainsKey('Content-Length')) {
            # get local length
            try {
                $Length = Get-Item -Path $FilePath | Select-Object -ExpandProperty 'Length'
            }
            catch {
                throw $_
            }
            # if local length matches remote length...
            if ($Length -eq $Headers['Content-Length']) {
                Write-Host 'skipping download: existing file size matches value in Content-Length header'
                return
            }
        }
    }

    # report state
    Write-Host "downloading ISO to path: $FilePath"

    # download the file
    try {
        Start-BitsTransfer -Source $UriForBits -Destination $FilePath
    }
    catch {
        Write-Warning -Message "could not download '$UriForBits' to '$FilePath"
        return $_
    }
}
