#Requires -Modules ActiveDirectory

Function Add-ADSchemaAttributes {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param(
		[Parameter(Position = 0, Mandatory)]
		[string]$OIDPrefix,
		[Parameter(Position = 1, Mandatory)]
		[string]$NamePrefix,
		[Parameter(Position = 2, Mandatory)]
		[string]$Type,
		[Parameter(Position = 3)][ValidateRange(1, 65535)]
		[uint16]$Suffix = 1,
		[Parameter(Position = 4)][ValidateRange(1, 65535)]
		[uint16]$Count = 1,
		[Parameter(Position = 5)][ValidateRange(0, 8191)]
		[uint16]$SearchFlags = 0,
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[string]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
	)

	# set values for attribute
	switch ($Type) {
		'single' {
			$ad_attribute_definition = [PSCustomObject]@{
				adminTextPrefix = 'custom-single-valued-attribute-'
				attributeSyntax = '2.5.5.12'
				isSingleValued  = $true
				oMSyntax        = '64'
			}
		}
		'multi' {
			$ad_attribute_definition = [PSCustomObject]@{
				adminTextPrefix = 'custom-multi-valued-attribute-'
				attributeSyntax = '2.5.5.12'
				isSingleValued  = $false
				oMSyntax        = '64'
			}
		}
		'time' {
			$ad_attribute_definition = [PSCustomObject]@{
				adminTextPrefix = 'custom-time-attribute-'
				attributeSyntax = '2.5.5.11'
				isSingleValued  = $true
				oMSyntax        = '24'
			}
		}
		'bool' {
			$ad_attribute_definition = [PSCustomObject]@{
				adminTextPrefix = 'custom-boolean-attribute-'
				attributeSyntax = '2.5.5.8'
				isSingleValued  = $true
				oMSyntax        = '1'
			}
		}
		Default {
			Write-Host 'Invalid attribute type, exiting...'
			Exit
		}
	}

	# force refresh of schema before update
	$ad_root_dse = Get-ADRootDSE -Server $Server
	$ad_root_dse.schemaUpdateNow = $true	

	# create each attribute object
	For ($index = 0; $index -lt $Count; $index++) {
		# create strings
		$ad_attribute_suffix = ($Suffix + $index).ToString()
		$ad_attribute_name = ($NamePrefix + (Get-Culture).TextInfo.ToTitleCase($Type.ToLower()) + $ad_attribute_suffix)
		$ad_attribute_path = "CN=$ad_attribute_name,$Schema"

		# check if attribute exists
		Try {
			$ad_attribute_found = Get-ADObject -Server $Server -Identity $ad_attribute_path
			#report attribute WAS found
			Write-Host "Attribute '$($ad_attribute_found.Name)' was ALREADY created"
		}
		Catch {
			# create strings for schema object
			$ad_attribute_text = ($ad_attribute_definition.adminTextPrefix + $ad_attribute_suffix)
			$ad_attribute_id = "$OIDPrefix.$ad_attribute_suffix"
	
			# create attribute hashtable for schema object
			$ad_attributes_object = @{
				lDAPDisplayName  = $ad_attribute_name
				adminDisplayName = $ad_attribute_text
				adminDescription = $ad_attribute_text
				attributeId      = $ad_attribute_id
				attributeSyntax  = $ad_attribute_definition.attributeSyntax
				isSingleValued   = $ad_attribute_definition.isSingleValued
				oMSyntax         = $ad_attribute_definition.oMSyntax
				searchFlags      = $SearchFlags
			}

			# declare values
			Write-Host ''
			Write-Host "Attribute '$($ad_attribute_name)' was NOT found and WILL be created as:"
			$ad_attributes_object
			Write-Host ''

			# create attribute
			If ($PSCmdlet.ShouldProcess($ad_attribute_name)) {
				Try {
					New-ADObject -Server $Server -Name $ad_attribute_name -Type 'attributeSchema' -Path $Schema -OtherAttributes $ad_attributes_object
					Write-Host "Attribute '$($ad_attribute_name)' was SUCCESSFULLY created"
				}
				Catch {
					Write-Host "Attribute '$($ad_attribute_name)' was NOT created"
					Return $_
				}	
			}
			Else {
				Write-Host "Attribute '$($ad_attribute_name)' WOULD have been created"
			}
		}
	}

	# force refresh of schema after update
	$ad_root_dse.schemaUpdateNow = $true
}

Function Add-ADSchemaAttributesToClass {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param (
		[Parameter(Position = 0, Mandatory)]
		[string]$Class,
		[Parameter(Position = 1, Mandatory)]
		[string]$NamePrefix,
		[Parameter(Position = 2, Mandatory)]
		[string]$Type,
		[Parameter(Position = 3)][ValidateRange(1, 65535)]
		[uint16]$Suffix = 1,
		[Parameter(Position = 4)][ValidateRange(1, 65535)]
		[uint16]$Count = 1,
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[string]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
	)

	# force refresh of schema before update
	$ad_root_dse = Get-ADRootDSE -Server $Server
	$ad_root_dse.schemaUpdateNow = $true	

	# verify class
	Try {
		$ad_class_path = "CN=$Class,$Schema"
		$ad_class_object = Get-ADObject -Server $Server -Identity $ad_class_path -Properties mayContain    
	}
	Catch {
		Write-Host 'Class '$Class' does NOT exist, exiting!'
		Return $null
	}

	# add each attribute object to class
	For ($index = 0; $index -lt $Count; $index++) {
		# create strings
		$ad_attribute_suffix = ($Suffix + $index).ToString()
		$ad_attribute_name = ($NamePrefix + (Get-Culture).TextInfo.ToTitleCase($Type.ToLower()) + $ad_attribute_suffix)

		# verify attribute
		Try {
			$ad_attribute_path = "CN=$ad_attribute_name,$Schema"
			$null = Get-ADObject -Server $Server -Identity $ad_attribute_path -Properties 'mayContain'
		}
		Catch {
			Write-Host "Attribute '$ad_attribute_name' does NOT exist, exiting!"
			Return $null
		}

		# check for attribute in mayContain of class
		If ($ad_class_object.mayContain -match $ad_attribute_name) {
			Write-Host "Attribute '$ad_attribute_name' was ALREADY in the MayContain of '$Class'"
		}
		Else {
			# add attribute to mayContain attribute of class
			If ($PSCmdlet.ShouldProcess("$ad_attribute_name to $Class")) {
				Try {
					Set-ADObject -Server $Server -Identity $ad_class_path -Add @{ mayContain = $ad_attribute_name }
					Write-Host "Attribute '$ad_attribute_name' was SUCCESSFULLY added to the MayContain of '$Class'"
				}
				Catch {
					Write-Host "Attribute '$ad_attribute_name' was NOT added to the MayContain of '$Class', exiting!"
					Return $_
				}	
			}
			Else {
				Write-Host "Attribute '$ad_attribute_name' WOULD have been added to the MayContain of '$Class'"
			}
		}		
	}

	# force refresh of schema after update
	$ad_root_dse.schemaUpdateNow = $true
}

Function Add-ADSchemaClass {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param (
		[Parameter(Position = 0, Mandatory)]
		[string]$OIDPrefix,
		[Parameter(Position = 1, Mandatory)]
		[string]$NamePrefix,
		[Parameter(Position = 2, Mandatory)]
		[string]$Type,
		[Parameter(Position = 3)][ValidateRange(1, 65535)]
		[uint16]$Suffix = 1,
		[switch]$IncludeSuffixInName,
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[string]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
	)

	#c heck attribute type variable
	switch ($Type) {
		'aux' {
			$ad_class_definition = [PSCustomObject]@{
				adminTextPrefix     = 'custom-auxiliary-class-'	
				objectClass         = 'classSchema'
				objectClassCategory = 3
				rdnAttId            = '2.5.4.3'
				subClassOf          = '2.5.6.0'
				systemOnly          = $false
			}
		}
		default {
			Write-Host 'Invalid class type, exiting...'
			Return
		}
	}

	# force refresh of schema before update
	$ad_root_dse = Get-ADRootDSE -Server $Server
	$ad_root_dse.schemaUpdateNow = $true

	# create strings
	$ad_class_suffix = ($Suffix).ToString()
	If ($IncludeSuffixInName) {
		$ad_class_name = "$NamePrefix$((Get-Culture).TextInfo.ToTitleCase($Type.ToLower()))$ad_class_suffix"
	}
	Else { 
		$ad_class_name = "$NamePrefix$((Get-Culture).TextInfo.ToTitleCase($Type.ToLower()))Class"
	}

	#check if class exists
	Try {
		$ad_class_path = "CN=$ad_class_name,$Schema"
		$ad_class_found = Get-ADObject -Server $Server -Identity $ad_class_path 
		Write-Host "Class '$($ad_class_found.Name)' was ALREADY created"
	}
	Catch {
		# create strings for schema object
		$ad_class_text = ($ad_class_definition.adminTextPrefix + $ad_class_suffix)
		$ad_class_governsID = "$OIDPrefix.$ad_class_suffix"

		# create class
		$ad_class_object = @{
			lDAPDisplayName     = $ad_class_name
			adminDisplayName    = $ad_class_text
			adminDescription    = $ad_class_text
			governsID           = $ad_class_governsID
			# objectClass         = $ad_class_definition.objectClass
			objectClassCategory = $ad_class_definition.objectClassCategory
			subClassOf          = $ad_class_definition.subClassOf
			rdnAttId            = $ad_class_definition.rdnAttId
			systemOnly          = $ad_class_definition.systemOnly
		}

		# declare values
		Write-Host ''
		Write-Host "Class '$ad_class_name' was NOT found and WILL be created as:"
		$ad_class_object
		Write-Host ''

		# create the class
		If ($PSCmdlet.ShouldProcess($ad_class_name)) {
			Try {
				New-ADObject -Server $Server -Name $ad_class_name -Type 'classSchema' -Path $Schema -OtherAttributes $ad_class_object
				Write-Host "Class '$ad_class_name' was SUCCESSFULLY created"
			}
			Catch {
				Write-Host "Class '$ad_class_name' was NOT created"
				$_
			}
		}
		Else {
			Write-Host "Class '$ad_class_name' WOULD have been created"
		}
	}

	# force refresh of schema after update
	$ad_root_dse.schemaUpdateNow = $true
}

Function Add-ADSchemaClassToParent {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param (
		[Parameter(Position = 0, Mandatory)]
		[string]$Class,
		[Parameter(Position = 1, Mandatory)]
		[string]$ParentClass,
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[string]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
	)

	# force refresh of schema before update
	$ad_root_dse = Get-ADRootDSE -Server $Server
	$ad_root_dse.schemaUpdateNow = $true	

	# verify the child class object
	Try {
		$ad_class_path = "CN=$Class,$Schema"
		$ad_class_object = Get-ADObject -Server $Server -Identity $ad_class_path -Properties 'governsID'
	}
	Catch {
		Write-Host "Class '$Class' does NOT exist, exiting!"
		Return $null
	}

	# verify the parent class object
	Try {
		$ad_parent_path = "CN=$ParentClass,$Schema"
		$ad_parent_object = Get-ADObject -Server $Server -Identity $ad_parent_path -Properties 'auxiliaryClass'
	}
	Catch {
		Write-Host "Class '$ParentClass' does NOT exist, exiting!"
		Return $null
	}

	# check auxiliaryClass attribute of parent class for name of child class
	If ($ad_parent_object.auxiliaryClass -match $Class) {
		Write-Host "Class '$Class' was ALREADY an auxiliary class of '$ParentClass'"
	}
	Else {
		# add governsID of child class to auxiliaryClass attribute of parent class
		If ($PSCmdlet.ShouldProcess("$Class to $ParentClass")) {
			Try {
				Set-ADObject -Server $Server -Identity $ad_parent_path -Add @{ auxiliaryClass = $ad_class_object.governsID }
				Write-Host "Class '$Class' was SUCCESSFULLY added as an auxiliary class of '$ParentClass'"
			}
			Catch {
				Write-Host "Class '$Class' was NOT added as an auxiliary class of '$ParentClass'"
				Return $_
			}	
		}
		Else {
			Write-Host "Class '$Class' WOULD have been added as an auxiliary class of '$ParentClass'"
		}
	}

	# force refresh of schema after update
	$ad_root_dse.schemaUpdateNow = $true
}

Function Get-ADSchemaClass {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
		[Parameter(Position = 1)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

	# check schema context
	If ($null -eq $ad_nc_schema) {
		New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_schema' -Value ([System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name)
	}

	# check class hastable
	If ($null -eq $ad_schema_classes) {
		New-Variable -Force -Scope 'Global' -Name 'ad_schema_classes' -Value @{}
	}

	# check class hashtable for requested class
	If ($ad_schema_classes[$ObjectClass] -is [Microsoft.ActiveDirectory.Management.ADObject] -and -not $Reset) {
		# return existing schema object for requested class
		Return $ad_schema_classes[$ObjectClass]	
	}
	Else {
		# define query for requested class
		$ad_schema_classes_ldapquery = "(&(objectCategory=classSchema)(objectClass=classSchema)(lDAPDisplayName=$ObjectClass))"

		# retrieve schema object for requested class
		$ad_schema_object = Get-ADObject -Server $Server -SearchBase $ad_nc_schema -LDAPFilter $ad_schema_classes_ldapquery -Properties *

		# verify requested class exists
		If ($null -ne $ad_schema_object) {
			# populate class hashtable with schema object for requested class
			$ad_schema_classes[$ObjectClass] = $ad_schema_object

			# return schema object for requested class
			Return $ad_schema_classes[$ObjectClass]
		}
		Else {
			# return null
			Return $null
		}
	}
}

Function Get-ADSchemaClassAncestry {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
		[Parameter(Position = 1)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

	# check class ancestry hashtable
	If ($null -eq $ad_schema_class_ancestry) {
		New-Variable -Force -Scope 'Global' -Name 'ad_schema_class_ancestry' -Value @{}
	}

	# check class ancestry hashtable for requested class
	If ($ad_schema_class_ancestry[$ObjectClass] -is [hashtable] -and $ad_schema_class_ancestry[$ObjectClass].Keys.Count -gt 0 -and -not $Reset) {
		# return existing class ancestry hashtable for requested class
		$ad_schema_class_ancestry[$ObjectClass]
	}
	Else {
		# create or reset class ancestry hashtable for requested class
		$ad_schema_class_ancestry[$ObjectClass] = @{}

		# retrieve schema object for requested class
		$ad_schema_class_object = Get-ADSchemaClass -Server $Server -ObjectClass $ObjectClass

		# verify requested class exists
		If ($null -ne $ad_schema_class_object) {
			# set requested class as focus of first loop iteration 
			$ad_schema_class_for_loop = $ObjectClass

			# populate class ancestry hashtable with ancestry for requested class
			Do {
				# retrieve schema object for current class
				$ad_schema_class_object = Get-ADSchemaClass -Server $Server -ObjectClass $ad_schema_class_for_loop

				# add values in ldapDisplayName, auxiliaryClass, systemAuxiliaryClass attributes to class ancestry hashtable for requested class
				ForEach ($ad_schema_class in $ad_schema_class_object.ldapDisplayName) { $ad_schema_class_ancestry[$ObjectClass][$ad_schema_class] = $true }
				ForEach ($ad_schema_class in $ad_schema_class_object.auxiliaryClass) { $ad_schema_class_ancestry[$ObjectClass][$ad_schema_class] = $true }
				ForEach ($ad_schema_class in $ad_schema_class_object.systemAuxiliaryClass) { $ad_schema_class_ancestry[$ObjectClass][$ad_schema_class] = $true }

				# set parent class as focus of next loop iteration
				$ad_schema_class_for_loop = $ad_schema_class_object.SubClassOf
			}
			# exit loop when displayName and SubClassOf match
			Until ($ad_schema_class_object.ldapDisplayName -eq $ad_schema_class_object.SubClassOf)

			# return class ancestry hashtable for requested class
			Return $ad_schema_class_ancestry[$ObjectClass]
		}
		Else {
			# return null
			Return $null
		}
	}
}

Function Get-ADSchemaClassAttributes {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
		[Parameter(Position = 1)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

	# check class attributes hashtable
	If ($null -eq $ad_schema_class_attributes) {
		New-Variable -Force -Scope 'Global' -Name 'ad_schema_class_attributes' -Value @{}
	}

	# check class attributes hashtable for requested class
	If ($ad_schema_class_attributes[$ObjectClass] -is [hashtable] -and $ad_schema_class_attributes[$ObjectClass].Keys.Count -gt 0 -and -not $Reset) {
		# return existing class attributes hashtable for requested class
		$ad_schema_class_attributes[$ObjectClass]
	}
	Else {
		# create or reset class attributes hashtable for requested class
		$ad_schema_class_attributes[$ObjectClass] = @{}

		# retrieve ancestry for requested class
		$ad_schema_class_ancestry = Get-ADSchemaClassAncestry -Server $Server -ObjectClass $ObjectClass

		# verify ancestry for requested class exists
		If ($null -ne $ad_schema_class_ancestry) {
			# populate class attributes hashtable with all attributes for requested class
			ForEach ($ad_schema_class_ancestor in $ad_schema_class_ancestry.Keys) {
				# retrieve schema object for current class
				$ad_schema_class_object = Get-ADSchemaClass -Server $Server -ObjectClass $ad_schema_class_ancestor

				# add values in mayContain, mustContain, systemMayContain, systemMustContain attributes to class attributes hashtable for requested class
				ForEach ($ad_schema_attribute in $ad_schema_class_object.mayContain) { $ad_schema_class_attributes[$ObjectClass][$ad_schema_attribute] = $true }
				ForEach ($ad_schema_attribute in $ad_schema_class_object.mustContain) { $ad_schema_class_attributes[$ObjectClass][$ad_schema_attribute] = $true }
				ForEach ($ad_schema_attribute in $ad_schema_class_object.systemMayContain) { $ad_schema_class_attributes[$ObjectClass][$ad_schema_attribute] = $true }
				ForEach ($ad_schema_attribute in $ad_schema_class_object.systemMustContain) { $ad_schema_class_attributes[$ObjectClass][$ad_schema_attribute] = $true }
			}

			# return class attributes hashtable for requested class
			Return $ad_schema_class_attributes[$ObjectClass]
		}
		Else {
			# return null
			Return $null
		}
	}
}

Function Get-ADSchemaAttribute {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$Attribute,
		[Parameter(Position = 1)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

	# check for existing schema context
	If ($null -eq $ad_nc_schema) {
		New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_schema' -Value ([System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name)
	}

	# check for existing attribute hastable
	If ($null -eq $ad_schema_attributes) {
		New-Variable -Force -Scope 'Global' -Name 'ad_schema_attributes' -Value @{}
	}

	# check attribute hashtable for requested attribute
	If ($ad_schema_attributes[$Attribute] -is [Microsoft.ActiveDirectory.Management.ADObject] -and -not $Reset) {
		# return existing schema object for requested attribute
		Return $ad_schema_attributes[$Attribute]	
	}
	Else {
		# define query for requested attribute
		$ad_schema_attribute_ldapquery = "(&(objectCategory=attributeSchema)(objectClass=attributeSchema)(lDAPDisplayName=$Attribute))"
		
		# retrieve schema object for requested attribute
		$ad_schema_object = Get-ADObject -Server $Server -SearchBase $ad_nc_schema -LDAPFilter $ad_schema_attribute_ldapquery -Properties *
		
		# verify requested attribute exists
		If ($null -ne $ad_schema_object) {
			# populate attribute hashtable with schema object for requested attribute
			$ad_schema_attributes[$Attribute] = $ad_schema_object

			# return schema object for requested attribute
			Return $ad_schema_attributes[$Attribute]
		}
		Else {
			# return null
			Return $null
		}
	}
}

Function Set-ADAttribute {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1, Mandatory = $true)]
		[string]$Attribute,
		[Parameter(Position = 2, Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()]
		[object[]]$AttributeValues,
		[Parameter(Position = 3)]
		[string]$Separator = ';',
		[Parameter(Position = 4)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 5)]
		[switch]$Report
	)

	# create empty objects
	$object_to_update = $null
	$object_attribute = $null
	$function_error = @()
	$function_reply = @()

	# verify object
	Try {
		$object_to_update = Get-ADObject -Server $Server -Properties $Attribute -Identity $Identity
		$object_attribute = (Get-ADSchemaClassAttributes -Server $Server -ObjectClass $object_to_update.objectClass)[$Attribute]
		If ($null -eq $object_attribute) {
			$function_error += $null
			$function_reply += "ERROR-attribute-not-valid-for-object"
		}
	}
	Catch {
		$function_error += $_
		$function_reply += "ERROR-get-object: $Identity"
	}

	# check if attribute valid for requested object
	If ($null -ne $object_to_update -and $null -ne $object_attribute) {
		# clear attribute
		If ($AttributeValues.Count -eq 0) {
			# check if requested attribute is already clear
			If ($object_to_update.$Attribute.Count -gt 0) {
				# check -whatif before clearing attribute
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Clear $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Clear $Attribute	
						$function_error += $null
						$function_reply += "cleared-$Attribute"
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-clearing-$Attribute"
					}
				}
			}
		}
		# update single-valued attribute with multiple requested values
		ElseIf (($AttributeValues.Count -gt 1) -and (Get-ADSchemaAttribute -Server $Server -Attribute $Attribute).IsSingleValued) {
			# sort and join requested values
			$attribute_singlevalue = ($AttributeValues | Sort-Object) -join $Separator
			# check if requested attribute is empty
			If ($object_to_update.$Attribute.Count -eq 0) {
				# check -whatif before adding attribute
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Add $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Add @{ $Attribute = $attribute_singlevalue }
						$function_error += $null
						$function_reply += "added-joined-values-to-$Attribute"
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-adding-joined-values-to-$Attribute"
					}
				}
			}
			# check if requested attribute matches requsted values
			ElseIf ($object_to_update.$Attribute -ne $attribute_singlevalue) {
				# check -whatif before replacing attribute
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Replace $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Replace @{ $Attribute = $attribute_singlevalue }
						$function_error += $null
						$function_reply += "replaced-joined-values-on-$Attribute"	
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-replacing-joined-values-on-$Attribute"
					}
				}
			}
		}
		# update multi-valued attribute with one requested value and one existing value
		ElseIf (($AttributeValues.Count -eq 1) -and ($object_to_update.$Attribute.Count -eq 1)) {
			# check if requested value matches existing value
			If ($object_to_update.$Attribute -ne $AttributeValues) {
				# check -whatif before replacing attribute
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Replace $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Replace @{ $Attribute = $AttributeValues }
						$function_error += $null
						$function_reply += "replaced-value-on-$Attribute"	
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-replacing-value-on-$Attribute"
					}
				}
			} 
		}
		# update multi-valued attribute with either one or more requested values or one or more existing values
		Else {
			# create empty arrays
			$existing_values = @()
			$attr_values_to_add = @()
			$attr_values_to_rem = @()

			# add existing values to array
			ForEach ($value in $object_to_update.$Attribute) { $existing_values += $value }

			# retrieve diffs between requested values and existing values
			$attr_values_to_add += [array][System.Linq.Enumerable]::Except([string[]]$AttributeValues, [string[]]$existing_values)
			$attr_values_to_rem += [array][System.Linq.Enumerable]::Except([string[]]$existing_values, [string[]]$AttributeValues)

			# check for values to add
			If ($attr_values_to_add.Count -gt 0) {
				# check -whatif before adding values
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Add $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Add @{ $Attribute = $attr_values_to_add }
						$function_error += $null
						$function_reply += "added-value(s)-to-$Attribute"
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-adding-value(s)-to-$Attribute"
					}
				}
			}

			# check for values to remove
			If ($attr_values_to_rem.Count -gt 0) {
				# check -whatif before removing values
				If ($PSCmdlet.ShouldProcess($object_to_update.Name, "Remove $Attribute")) {
					Try {
						Set-AdObject -Server $Server -Identity $object_to_update.DistinguishedName -Remove @{ $Attribute = $attr_values_to_rem }
						$function_error += $null
						$function_reply += "removed-value(s)-from-$Attribute"
					}
					Catch {
						$function_error += $_
						$function_reply += "ERROR-removing-value(s)-from-$Attribute"
					}
				}
			}
		}
	}

	# report actions if requested
	If ($Report) {
		[PSCustomObject]@{ 
			FQDN    = $object_to_update.DistinguishedName
			Error   = $function_error
			Message = $function_reply
		}	
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Add-ADSchemaAttributes'
$functions_to_export += 'Add-ADSchemaAttributesToClass'
$functions_to_export += 'Add-ADSchemaClassToParent'
$functions_to_export += 'Add-ADSchemaClass'
$functions_to_export += 'Get-ADSchemaClass'
$functions_to_export += 'Get-ADSchemaClassAncestry'
$functions_to_export += 'Get-ADSchemaClassAttributes'
$functions_to_export += 'Get-ADSchemaAttribute'
$functions_to_export += 'Set-ADAttribute'

# export module members
Export-ModuleMember -Function $functions_to_export