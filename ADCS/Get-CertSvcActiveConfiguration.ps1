[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
param(
    [Parameter(Position = 0)]    
    [string]$ConfigurationPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration',
    # switch to write response to a variable instead of to the pipeline
    [Parameter(Position = 1)]
    [switch]$AsVariable,
    # name of variable when AsVariable is true
    [Parameter(Position = 2)]
    [string]$VariableName = 'CertSvcActiveConfiguration',
    # scope of variable when AsVariable is true
    [Parameter(Position = 3)]
    [string]$VariableScope = 'global'
)

process {
    # if configuration path not found in registry
    if (!(Test-Path -Path $ConfigurationPath -PathType 'Container')) {
        # warn and return
        Write-Warning -Message "could not locate CertSvc configuration registry key, exiting!"
        return
    }

    # retrieve CA name from active configuration in registry
    try {
        $Value = Get-ItemPropertyValue -Path $ConfigurationPath -Name 'Active' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not retrieve CA name from Active property on CertSvc configuration registry key, exiting!"
        throw $_
    }

    # if CA name not found...
    if ([System.String]::IsNullOrEmpty($Value)) {
        # warn and return
        Write-Warning -Message "found empty string for CA name in Active property on CertSvc configuration registry key, exiting!"
        return
    }

    # if AsVariable requested...
    if ($AsVariable) {
        New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
    }
    else {
        return $Value
    }
}
