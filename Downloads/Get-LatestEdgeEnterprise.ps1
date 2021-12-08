[CmdletBinding()]
Param (
    [Parameter(Position = 0, Mandatory = $true)][ValidateScript({Test-Path -Path $_})]
    [string]$Destination,
    [switch]$Force
)

# get JSON
$edge_json = Invoke-RestMethod -Uri "https://edgeupdates.microsoft.com/api/products?view=enterprise"

# get and set browser information
$edge_msi_down = $false
$edge_msi_file = Join-Path -Path $Destination -ChildPath "MicrosoftEdgeEnterpriseX64.msi"
$edge_msi_size = ($edge_json | Where-Object {$_.Product -eq "Stable"} | Select-Object -ExpandProperty 'Releases' | Where-Object {$_.Architecture -eq "x64" -and $_.Platform -eq "Windows" -and $_.Artifacts -ne $null} | Sort-Object -Proerty 'ProductVersion' -Descending | Select-Object -First 1 | Select-Object -ExpandProperty 'Artifacts' | Where-Object {$_.ArtifactName -eq 'msi'}).SizeInBytes
$edge_msi_path = ($edge_json | Where-Object {$_.Product -eq "Stable"} | Select-Object -ExpandProperty 'Releases' | Where-Object {$_.Architecture -eq "x64" -and $_.Platform -eq "Windows" -and $_.Artifacts -ne $null} | Sort-Object -Proerty 'ProductVersion' -Descending | Select-Object -First 1 | Select-Object -ExpandProperty 'Artifacts' | Where-Object {$_.ArtifactName -eq 'msi'}).Location

# get and set policy information
$edge_pol_down = $false
$edge_pol_file = Join-Path -Path $Destination -ChildPath "MicrosoftEdgePolicyTemplates.zip"
$edge_pol_size = ($edge_json | Where-Object {$_.Product -eq "Policy"} | Select-Object -ExpandProperty 'Releases' | Where-Object {$_.Architecture -eq "any" -and $_.Platform -eq "Any" -and $_.Artifacts -ne $null} | Sort-Object -Proerty 'ProductVersion' -Descending | Select-Object -First 1 | Select-Object -ExpandProperty 'Artifacts' | Where-Object {$_.ArtifactName -eq 'zip'}).SizeInBytes
$edge_pol_path = ($edge_json | Where-Object {$_.Product -eq "Policy"} | Select-Object -ExpandProperty 'Releases' | Where-Object {$_.Architecture -eq "any" -and $_.Platform -eq "Any" -and $_.Artifacts -ne $null} | Sort-Object -Proerty 'ProductVersion' -Descending | Select-Object -First 1 | Select-Object -ExpandProperty 'Artifacts' | Where-Object {$_.ArtifactName -eq 'zip'}).Location

# do we have edge already and, if so, is it the same as current?
If (Test-Path $edge_msi_file) {
    If ($Force) {
        Write-Host "Edge Enterprise X64 - Force set, downloading!"
        $edge_msi_down = $true
    }
    ElseIf ($edge_msi_size -ne (Get-ItemProperty $edge_msi_file).Length) {
        Write-Host "Edge Enterprise X64 - File sizes mismatch, downloading!"
        $edge_msi_down = $true
    }
    Else {
        Write-Host "Edge Enterprise X64 - File sizes matched, skipping download!"
    }
} 
Else {
    Write-Host "Edge Enterprise X64 - File not found, downloading!"
    $edge_msi_down = $true
}

# do we have policy already and, if so, is it the same as current?
If (Test-Path $edge_pol_file) {
    If ($Force) {
        Write-Host "Edge Template Files - Force set, downloading!"
        $edge_pol_down = $true
    } 
    ElseIf ($edge_pol_size -ne (Get-ItemProperty $edge_pol_file).Length) {
        Write-Host "Edge Template Files - File sizes mismatch, will download!"
        $edge_pol_down = $true
    }
    Else {
        Write-Host "Edge Template Files - File sizes matched, skipping download!"
    }
}
Else {
    Write-Host "Edge Template Files - File not found, downloading!"
    $edge_pol_down = $true
}

# if we should get a new edge, get it!
If ($edge_msi_down) {Invoke-WebRequest -Uri $edge_msi_path -OutFile $edge_msi_file}

# if we should get a new policy, get it!
If ($edge_pol_down) {Invoke-WebRequest -Uri $edge_pol_path -OutFile $edge_pol_file}