Function ConvertTo-Collection {
	Param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[object]$InputObject,
		[switch]$Ordered
	)

	# if ordered...
	If ($Ordered) {
		# create an ordered dictionary
		$Collection = [System.Collections.Specialized.OrderedDictionary]::new()
	}
	Else {
		# create a hashtable
		$Collection = [System.Collections.Hashtable]::new()
	}

	# process each property of input object
	ForEach ($Property in $InputObject.PSObject.Properties) {
		# if property contains multiple values...
		If ($Property.Value.Count -gt 1) {
			# define arraylist for property values
			$PropertyValues = [System.Collections.ArrayList]::new()
			# process each property value
			ForEach ($PropertyValue in $Property.Value) {
				# if property value is a pscustomobject...
				If ($PropertyValue -is [System.Management.Automation.PSCustomObject]) {
					# convert property value into collection
					$Value = ConvertTo-Collection -InputObject $PropertyValue -Ordered:$Ordered
					# add property value to arraylist
					$Values.Add($Value)
				}
				# if property value is not a pscustomobject...
				Else {
					# add value to arraylist
					$Values.Add($Property.Value)
				}
			}
			# convert arraylist to array then add array to collection
			$Collection[$Property.Name] = $PropertyValues.ToArray()
		}
		Else {
			# if property value is a pscustomobject...
			If ($Property.Value -is [System.Management.Automation.PSCustomObject]) {
				# convert property value into collection
				$Value = ConvertTo-Collection -InputObject $Property.Value -Ordered:$Ordered
				# add property name and value to collection
				$Collection[$Property.Name] = $Value
			}
			# if property value is not a pscustomobject...
			Else {
				# add property name and value to collection
				$Collection[$Property.Name] = $Property.Value
			}
		}
	}

	# return collection
	Return $Collection
}
