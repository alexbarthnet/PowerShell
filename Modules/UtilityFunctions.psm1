Function ConvertFrom-SecurityIdentifier {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [object]$SID
    )

    # verify the input
    If ($SID -isnot [System.Security.Principal.SecurityIdentifier]) {
        If (($SID -is [System.String]) -and ($SID -match 'S-1-\d{1,2}-\d*')) {
            $SID = [System.Security.Principal.SecurityIdentifier]($SID)
        }
    }

    # return the NTAccount
    Try {
        # return value of NTAccount
        $SID.Translate([System.Security.Principal.NTAccount]).Value
    }
    Catch {
        # return null and declare
        $null
        Write-Host 'Could not translate SID'
    }
}

Function ConvertTo-SecurityIdentifier {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Principal
    )

    # check principal against well-known SIDs in the BUILTIN space
    switch ($Principal) {
        { ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
            [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
        }
        Default {
            Try {
                # convert a SID text string into a SID object
                [System.Security.Principal.SecurityIdentifier]($Principal)
            }
            Catch {
                Try {
                    # convert an NT-style principal into a SID object
                    ([System.Security.Principal.NTAccount]($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
                }
                Catch {
                    # return null and declare
                    $null
                    Write-Host 'Could not translate principal'
                }
            }        
        }
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