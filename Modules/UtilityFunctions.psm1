Function ConvertFrom-SecurityIdentifier {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [object]$SID
    )

    # verify the input
    If ($SID -isnot [System.Security.Principal.SecurityIdentifier] -and $SID -is [System.String] -and $SID -match 'S-1-\d{1,2}-\d*') {
        $SID = [System.Security.Principal.SecurityIdentifier]($SID)
    }

    # return the NTAccount
    Try {
        # return value for specific well-known SIDs or translate the SID
        switch ($SID.Value) {
            { $_ -eq 'S-1-5-32-560' } {
                "$([System.Environment]::UserDomainName)\Windows Authorization Access Group"
            }
            Default {
                $SID.Translate([System.Security.Principal.NTAccount]).Value
            }
        }
    }
    Catch {
        # return error
        Return $_
    }
}

Function ConvertTo-SecurityIdentifier {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [object]$Principal
    )

    # verify the input
    If ($Principal -isnot [System.String] -and $Principal -is [System.Security.Principal.SecurityIdentifier]) {
        $Principal = $Principal.Value
    }

    # translate principal to SID
    Try {
        # check for specific well-known SIDs or translate the SID
        switch ($Principal) {
            { ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
                Return [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
            }
            { ($_ -match 'S-1-\d{1,2}-\d*') } {
                Return [System.Security.Principal.SecurityIdentifier]($Principal)
            }
            { $_ -match '^[\w\.-]*\\[\w\.-]*$' } {
                Return ([System.Security.Principal.NTAccount]($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
            }
            Default {
                Return ([System.Security.Principal.NTAccount]([System.Environment]::UserDomainName, $cms_principal)).Translate([System.Security.Principal.SecurityIdentifier])
            }
        }
    }
    Catch {
        # return error
        Return $_
    }
}

Function Get-RandomAlpha {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [int]$Length,
        [switch]$LowerCase,
        [switch]$UpperCase,
        [switch]$Numbers
    )

    If (-not $LowerCase -and -not $UpperCase -and -not $Numbers) {
        $LowerCase = $true; $UpperCase = $true; $Numbers = $true
    }

    $array = @()
    If ($Numbers) { $array += 48..57 }
    If ($UpperCase) { $array += 65..90 }
    If ($LowerCase) { $array += 97..122 }

    # clear required objects
    $key = $null
    switch ($true) {
        { $Length -gt 0 } { 
            Do { $value = (Get-Random -Max $array.Count); $key += [char]($array[$value]) } Until ($key.Length -eq $Length)
            $key
        }
        Default {
            Write-Output 'Provide a length!'
        }
    }
}

Function Get-RandomAlpha {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [int]$Length
    )

    # clear required objects
    $key = $null
    switch ($true) {
        { $Length -gt 0 } { 
            Do { $key += '{0:x}' -f (Get-Random -Max 16) } Until ($key.Length -eq $Length) 
            $key
        }
        Default {
            Write-Output 'Provide a length!'
        }
    }
}


# define functions to export
$functions_to_export = @()
$functions_to_export += 'ConvertFrom-SecurityIdentifier'
$functions_to_export += 'ConvertTo-SecurityIdentifier'
$functions_to_export += 'Get-RandomAlpha'
$functions_to_export += 'Get-RandomHex'

# export module members
Export-ModuleMember -Function $functions_to_export