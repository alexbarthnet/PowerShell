param(
    [Parameter(Position = 0, Mandatory)]
    $ReferenceGroup,
    [Parameter(Position = 1, Mandatory)]
    $DifferenceGroup,
    [Parameter(Position = 2)]
    [switch]$Transitive
)

# if reference group is not an AD group...
if ($ReferenceGroup -isnot [Microsoft.ActiveDirectory.Management.ADGroup]) {
    Write-Warning 'reference group is not an ADGroup object'
    return
}

# if difference group is not an AD group...
if ($DifferenceGroup -isnot [Microsoft.ActiveDirectory.Management.ADGroup]) {
    Write-Warning 'difference group is not an ADGroup object'
    return
}

# if transitive requested...
if ($Transitive.IsPresent) {
    # define comparison property
    $Property = 'msds-MemberTransitive'
}
else {
    # define comparison property
    $Property = 'Member'
}

# retrieve a fresh copy of the reference group
try {
    $ReferenceGroup = Get-ADGroup -Identity $ReferenceGroup -Properties $Property -ErrorAction Stop
}
catch {
    Write-Warning -Message "could not refresh reference group to load '$Property' property: $($_.Exception.Message)"
    return $_
}

# retrieve a fresh copy of the difference group
try {
    $DifferenceGroup = Get-ADGroup -Identity $DifferenceGroup -Properties $Property -ErrorAction Stop
}
catch {
    Write-Warning -Message "could not refresh difference group to load '$Property' property: $($_.Exception.Message)"
    return $_
}

# compare objects
$Comparison = Compare-Object -ReferenceObject $ReferenceGroup -DifferenceObject $DifferenceGroup -Property $Property

# report comparison
$Comparison
