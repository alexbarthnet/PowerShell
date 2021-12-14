Function Get-ZenossCloudDevices {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$Uri,
        [Parameter()]
        [string]$Key,
        [Parameter()]
        [switch]$Reset
    )

    # check for zenoss devices object
    If ($null -eq $zenoss_devices) {
        New-Variable -Name 'zenoss_devices' -Scope 'Global' -Force
    }

    # check for devices array in zenoss devices object
    If ($zenoss_devices.result.devices -is [array] -and $zenoss_devices.result.devices.Count -gt 0 -and -not $Reset) {
        # return array of devices
        Return $zenoss_devices
    }
    Else {
        # create hashtable for header
        $zenoss_head = @{
            'z-api-key'    = $Key
            'Content-Type' = 'application/json'
        }

        # create for body data
        $zenoss_data = [array][PSCustomObject]@{
            limit = 300
        }
        
        # create hashtable for headers and body
        $zenoss_body = @{
            'action' = 'DeviceRouter'
            'method' = 'getDevices'
            'data'   = $zenoss_data
            'tid'    = 1
        }

        # invoke rest method to retrieve devices
        $zenoss_devices = Invoke-RestMethod -Method 'Post' -Uri $Uri -Headers $zenoss_head -Body ($zenoss_body | ConvertTo-Json -Compress)
        
        # return array of devices
        Return $zenoss_devices
    }
}

Function Get-ZenossCloudDevice {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Uri,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$Key,
        [Parameter(Position = 2, Mandatory = $true)]
        [string]$Hostname
    )

    # get zenoss cloud device collection
    $zenoss_devices = Get-ZenossCloudDevices -Uri $Uri -Key $Key

    # retrieve device uid
    $zenoss_device = $null
    $zenoss_device = $zenoss_devices.result.devices | Where-Object { $_.Name -eq $Hostname }
    If ($null -eq $zenoss_device) {
        Return "ERROR: Device '$Hostname' not found in Zenoss Cloud"
    }
    Else {
        Return $zenoss_device
    }
}

Function Get-ZenossCloudProductionStates {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Uri,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$Key,
        [Parameter(Position = 2)]
        [switch]$Reset
    )

    # check for zenoss devices object
    If ($null -eq $zenoss_states) {
        New-Variable -Name 'zenoss_states' -Scope 'Global' -Force
    }

    # check for data array in zenoss states object
    If ($zenoss_states.result.data -is [array] -and $zenoss_states.result.data.Count -gt 0 -and -not $Reset) {
        # return production states
        Return $zenoss_states
    }
    Else {
        # create hashtable for HTML headers
        $zenoss_head = @{
            'z-api-key'    = $Key
            'Content-Type' = 'application/json' 
        }

        # create hashtable for HTML body
        $zenoss_body = @{
            'action' = 'DeviceRouter'
            'method' = 'getProductionStates'
            'tid'    = 1
        }
        
        # invoke rest method to retrieve production states
        $zenoss_states = Invoke-RestMethod -Method 'Post' -Uri $Uri -Headers $zenoss_head -Body ($zenoss_body | ConvertTo-Json)    

        # return production states
        Return $zenoss_states
    }
}

Function Set-ZenossCloudProductionState {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Uri,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$Key,
        [Parameter(Position = 2, Mandatory = $true)]
        [string]$Hostname,
        [Parameter(Position = 3, Mandatory = $true)]
        [string]$State
    )

    # get zenoss cloud production states 
    $zenoss_states = Get-ZenossCloudProductionStates -Uri $Uri -Key $Key
    
    # check zenoss cloud production state
    $zenoss_state = $null
    $zenoss_state = ($zenoss_states.result.data | Where-Object { $_.Name -eq $State }).Value
    If ($null -eq $zenoss_state) {
        Return "ERROR: ProductionState '$State' not found in Zenoss Cloud"
    }

    # retrieve device uid
    $zenoss_device = $null
    $zenoss_device = Get-ZenossCloudDevice -Uri $Uri -Key $Key -Hostname $Hostname
    If ($null -eq $zenoss_device.uid) {
        Return "ERROR: Device '$Hostname' not found in Zenoss Cloud"
    }

    # create hashtable for HTML headers
    $zenoss_head = @{
        'z-api-key'    = $Key
        'Content-Type' = 'application/json' 
    }

    # create array for zenoss body entry
    $zenoss_data = [array][PSCustomObject]@{
        uids      = $zenoss_device.uid
        prodState = $zenoss_state
        hashcheck = 'no' 
    }

    # create hashtable for HTML body
    $zenoss_body = @{
        'action' = 'DeviceRouter'
        'method' = 'setProductionState'
        'data'   = $zenoss_data
        'tid'    = 1
    }

    # invoke rest method to update state
    Invoke-RestMethod -Method 'Post' -Uri $Uri -Headers $zenoss_head -Body ($zenoss_body | ConvertTo-Json)
}

Function Invoke-ZenossCloudDeviceRemodel {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$Uri,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$Key,
        [Parameter(Position = 2, Mandatory = $true)]
        [string]$Hostname
    )

    # retrieve device uid
    $zenoss_device = $null
    $zenoss_device = Get-ZenossCloudDevice -Uri $Uri -Key $Key -Hostname $Hostname
    If ($null -eq $zenoss_device.uid) {
        Return "ERROR: Device '$Hostname' not found in Zenoss Cloud"
    }

    # create hashtable for HTML headers
    $zenoss_head = @{
        'z-api-key'    = $Key
        'Content-Type' = 'application/json' 
    }

    # create array for zenoss body entry
    $zenoss_data = [array][PSCustomObject]@{
        deviceUid = $zenoss_device.uid
    }

    # create hashtable for HTML body
    $zenoss_body = @{
        'action' = 'DeviceRouter'
        'method' = 'remodel'
        'data'   = $zenoss_data
        'tid'    = 1
    }

    # modify URI for remodel command
    $uri_remodel = $Uri.Replace('/zport/dmd',$zenoss_device.uid)

    # invoke rest method to update state
    Invoke-RestMethod -Method 'Post' -Uri $uri_remodel -Headers $zenoss_head -Body ($zenoss_body | ConvertTo-Json)
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Get-ZenossCloudDevices'
$functions_to_export += 'Get-ZenossCloudDevice'
$functions_to_export += 'Get-ZenossCloudProductionStates'
$functions_to_export += 'Set-ZenossCloudProductionState'

# export module members
Export-ModuleMember -Function $functions_to_export