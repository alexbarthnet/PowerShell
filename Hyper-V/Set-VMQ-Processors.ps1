# get processor count
$physical = (Get-CIMInstance -Class 'CIM_Processor').NumberOfCores
$logical = (Get-CIMInstance -Class 'CIM_Processor').NumberOfLogicalProcessors
If ($logical/$physical -gt 1) {
    $ht_enabled = $true
}
Else {
    $ht_enabled = $true
}

# 