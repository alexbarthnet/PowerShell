Install-PackageProvider -Name 'NuGet' -Scope 'AllUsers' -Force
Install-Module -Name 'PSWindowsUpdate' -Scope 'AllUsers' -Force -AllowClobber
Install-WindowsUpdate -NotTitle 'Preview' -AcceptAll -AutoReboot
