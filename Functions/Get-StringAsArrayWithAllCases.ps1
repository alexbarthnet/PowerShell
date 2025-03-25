Function Get-StringAsArrayWithAllCases {
    Param(
        [Parameter(Mandatory)]
        [string]$String,
        [string[]]$Prefix = @()
    )

    # if string is empty...
    If ($String -eq '') {
        # return prefix array joined
        Return -join $Prefix
    }

    Get-StringAsArrayWithAllCases -String $String.Substring(1) -Prefix ($Prefix + $String.Substring(0, 1).ToLower())
    Get-StringAsArrayWithAllCases -String $String.Substring(1) -Prefix ($Prefix + $String.Substring(0, 1).ToUpper())
}
