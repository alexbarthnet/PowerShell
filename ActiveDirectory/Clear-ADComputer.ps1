#Requires -Modules ActiveDirectory,DnsServer

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True)]
	[object]$Identity,
	[Parameter(Position = 2)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

# create global objects
$env_comp_name = [System.Environment]::MachineName.ToLowerInvariant()

# remove computer object from AD
Write-Host ("$env_comp_name,$Identity - checking for VM in AD")
$vm_ad = Get-ADObject -Server $Server -Filter "Name -eq '$($Identity)' -and ObjectClass -eq 'computer'"
If ($vm_ad) {
	Write-Host ("$env_comp_name,$Identity - ...AD object found")
	Write-Host ("$env_comp_name,$Identity - removing AD object...")
	$vm_ad | Remove-ADObject -Server $Server -Recursive -Confirm:$false
	Write-Host ("$env_comp_name,$Identity - ...removed AD object")
}
Else {
	Write-Host ("$env_comp_name,$Identity - ...AD object not found")
}

# remove forward DNS records
Write-Host ("$env_comp_name,$Identity - checking for VM in DNS")

# check DNS records
$dns_forward_zone = (Get-ADDomain).DnsRoot
$dns_forward = Resolve-DnsName -Server $Server -Type A -Name ($Identity, $dns_forward_zone -join '.') -ErrorAction SilentlyContinue
$dns_reverse = Resolve-DnsName -Server $Server -Type PTR -Name $dns_forward.IPAddress  -ErrorAction SilentlyContinue

# get DNS forward record
If ($dns_forward) {
	$dns_forward_record = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_forward_zone -RRType A | Where-Object { $_.HostName -eq $Identity }
	If ($dns_forward_record) {
		Write-Host ("$env_comp_name,$Identity - ...DNS A records found")
		Write-Host ("$env_comp_name,$Identity - removing DNS A records...")
		$dns_forward_record | Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_forward_zone -Force
		Write-Host ("$env_comp_name,$Identity - ...removed DNS A records")
	}
	Else {
		Write-Host ("$env_comp_name,$Identity - ...DNS A records not found")
	}
}

# get DNS reverse record
If ($dns_reverse) {
	$dns_reverse_host = $dns_reverse.Name.Split('.', 2)[0]
	$dns_reverse_zone = $dns_reverse.Name.Split('.', 2)[1]
	$dns_reverse_record = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_reverse_zone -RRType PTR | Where-Object { $_.HostName -eq $dns_reverse_host }
	If ($dns_reverse_record) {
		Write-Host ("$env_comp_name,$Identity - ...DNS PTR records found")
		Write-Host ("$env_comp_name,$Identity - removing DNS PTR records...")
		Try {
			$dns_reverse_record | Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_reverse_zone -Force
			Write-Host ("$env_comp_name,$Identity - ...removed DNS PTR records")
		}
		Catch {
			Write-Host ("$env_comp_name,$Identity - ERROR: could not remove DNS PTR records")
			$_
		}
	}
	Else {
		Write-Host ("$env_comp_name,$Identity - ...DNS PTR records not found")
	}
}
