#requires -modules ActiveDirectory

<#
.SYNOPSIS
Enable the Global Catalog role for the local system via the object for local system on a remote domain controller.

.DESCRIPTION
Enable the Global Catalog role for the local system via the object for local system on a remote domain controller.

#>

[CmdletBinding()]
Param (
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
)

# if local system is not a domain controller...
If ($DomainRole -lt 4) {
	# report and return
	Write-Warning -Message 'local system is not a domain controller'
	Return
}

# get local domain controller by name
Try {
	$LocalDomainController = Get-ADDomainController -Identity $DnsHostName
}
Catch {
	Write-Warning -Message 'could not retrieve local domain controller'
	Return $_
}

# if local domain controller is read only...
If ($LocalDomainController.IsReadOnly) {
	# report and return
	Write-Warning -Message 'local system is a read-only domain controller'
	Return
}

# get remote domain controller by discovery
Try {
	$RemoteDomainController = Get-ADDomainController -AvoidSelf -Discover -ForceDiscover -NextClosestSite -Writable
}
Catch {
	Write-Warning -Message 'could not retrieve remote domain controller'
	Return $_
}

# if remote domain controller not found...
If ($null -eq $script:RemoteDomainController) {
	# warn and return
	Write-Warning -Message 'could not locate a remote domain controller'
	Return
}
Else {
	# retrieve server name from property collection
	$Server = $RemoteDomainController.HostName.Value
	# declare found
	Write-Host "found remote domain controller: $Server"
}

# get DSA object for local domain controller from remote domain controller
Try {
	$ADObject = Get-ADObject -Server $Server -Identity $LocalDomainController.NTDSSettingsObjectDN -Properties 'options'
}
Catch {
	Write-Warning -Message "could not find DSA for local domain controller on remote domain controller: $Server"
	Return $_
}

# if Global Catalog role already enabled on DSA object...
If ($ADObject.options -eq '1') {
	Write-Warning -Message "found Global Catalog role already enabled for local domain controller on remote domain controller: $Server"
	Return
}

# enable Global Catalog role for local domain controller on remote domain controller
Try {
	Set-ADObject -Server $Server -Identity $LocalDomainController.NTDSSettingsObjectDN -Replace @{ options = '1' }
}
Catch {
	Write-Warning -Message "could not enable Global Catalog role for local domain controller on remote domain controller: $Server"
	Return $_
}

# declare complete
Write-Host "enabled Global Catalog role for local domain controller on remote domain controller: $Server"
