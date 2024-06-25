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
			# define list for property values
			$PropertyValues = [System.Collections.Generic.List[object]]::new($Property.Value.Count)
			# process each property value
			ForEach ($PropertyValue in $Property.Value) {
				# if property value is a pscustomobject...
				If ($PropertyValue -is [System.Management.Automation.PSCustomObject]) {
					# convert property value into collection
					$PropertyValueCollection = ConvertTo-Collection -InputObject $PropertyValue -Ordered:$Ordered
					# add property value collection to list
					$PropertyValues.Add($PropertyValueCollection)
				}
				# if property value is not a pscustomobject...
				Else {
					# add property value to list
					$PropertyValues.Add($PropertyValue)
				}
			}
			# convert list to array then add array to collection
			$Collection[$Property.Name] = $PropertyValues.ToArray()
		}
		Else {
			# if property value is a pscustomobject...
			If ($Property.Value -is [System.Management.Automation.PSCustomObject]) {
				# convert property value into collection
				$PropertyValueCollection = ConvertTo-Collection -InputObject $Property.Value -Ordered:$Ordered
				# add property name and value to collection
				$Collection[$Property.Name] = $PropertyValueCollection
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
