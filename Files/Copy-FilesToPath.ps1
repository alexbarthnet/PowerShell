# define path
$sysvol = ("\\" + $env:USERDNSDOMAIN + "\sysvol\" + $env:USERDNSDOMAIN + "\scripts")
$path_1 = Join-Path -Path $sysvol -ChildPath "Hyper-V"

# copy
Get-ChildItem -Path . -Recuse | Copy-Item -Destination $path_1