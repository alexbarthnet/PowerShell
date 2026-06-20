<#
.SYNOPSIS
Test if the current hour matches the current cluster node ID.

.DESCRIPTION
Test if the current hour matches the current cluster node ID. The expected cluster node ID is derived by retrieving the remainder of dividing by current hour in 24 hour time by the count of cluster nodes and adding 1 to account for cluster nodes IDs being 1 indexed. If the derived value matches the cluster node id of the current cluster node, this script returns true. Otherwise, this script returns false.

.INPUTS
None.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-HourForClusterNodeId.ps1

#>

[CmdletBinding(DefaultParameterSetName = 'Hour')]
Param(
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 0)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 1)]
	[string]$VariableName = 'TestDateTimeHourForClusterNodeId',
	# scope of variable when AsVariable is true
	[Parameter(Position = 2)]
	[string]$VariableScope = 'global'
)

process {
    # retrieve cluster nodes in the current cluster
    try {
        $ClusterNodes = Get-ClusterNode
    }
    catch {
        throw $_
    }

    # retrieve count of cluster nodes in the current cluster
    $Count = $ClusterNodes | Measure-Object | Select-Object -ExpandProperty Count

    # if count of cluster nodes is zero somehow...
    if ($Count -eq 0) {
        return
    }

    # active node is modulo of hour plus 1 as nodes start with 1
    $ActiveNode = [System.DateTime]::Now.ToString('HH') % $Count + 1

    # retrieve expected cluster node name
    $ClusterNodeName = $ClusterNodes | Where-Object { $_.Id -eq $ActiveNode } | Select-Object -ExpandProperty name

    # if expected cluster node is current computer...
    if ($ClusterNodeName -eq $env:COMPUTERNAME) {
        $Value = $true
    }
    else {
        $Value = $false
    }

    # if AsVariable requested...
    if ($AsVariable) {
        New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
    }
    else {
        return $Value
    }
}