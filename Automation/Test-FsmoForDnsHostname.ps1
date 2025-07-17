<#
.SYNOPSIS
Test if the current FSMO role owner matches the local DNS hostname.

.DESCRIPTION
Test if the current FSMO role owner matches the local DNS hostname.

.PARAMETER Role
The FSMO role owner to evaluate.

.PARAMETER DnsHostName
The DNS hostname expected in the role. The default value is the DNS hostname of the local system.

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-FsmoForHostname.ps1 -Role 'PDC'

.NOTES
The path may be a folder or a file. The file with the last write time is selected when the path is a folder.
#>

Param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# role to evaluate
	[Parameter(Position = 0, Mandatory = $True)][ValidateSet('PDC', 'RID', 'Infrastructure', 'Schema', 'Naming')]
	[string]$Role,
	# local DNS hostname
	[Parameter(Position = 1)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 2)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 3)]
	[string]$VariableName = 'TestFsmoForDnsHostname',
	# scope of variable when AsVariable is true
	[Parameter(Position = 4)]
	[string]$VariableScope = 'global'
)

Process {
	# retrieve name of role owner
	switch ($Role) {
		'PDC' {
			$RoleOnwer = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
		}
		'RID' {
			$RoleOnwer = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().RidRoleOwner.Name
		}
		'Infrastructure' {
			$RoleOnwer = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().InfrastructureRoleOwner.Name
		}
		'Schema' {
			$RoleOnwer = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name
		}
		'Naming' {
			$RoleOnwer = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().NamingRoleOwner.Name
		}
	}

	# if role owner matches DNS hostname...
	If ($RoleOnwer -eq $DnsHostName) {
		$Value = $true
	}
	Else {
		$Value = $false
	}

	# if AsVariable requested...
	If ($AsVariable) {
		New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
	}
	Else {
		return $Value
	}
}
