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
