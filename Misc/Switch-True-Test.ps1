[CmdletBinding(DefaultParameterSetName='Default')]
Param(
    [Parameter(Mandatory = $True, ParameterSetName = 'View')]
    [switch]$View,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [switch]$Add,
    [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
    [switch]$Remove
)

switch ($true) {
    $Add { Write-Output "Add!" }
    $View { Write-Output "View!" }
    $Remove { Write-Output "Remove!" }
    Default { Write-Output "...nothing!" }
}
