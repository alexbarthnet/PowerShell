#Requires -Modules ActiveDirectory

Function Add-ADSchemaAttributes {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param(
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
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
		[Parameter(Position = 6)]
		[switch]$AddToGlobalCatalog
	)

	# set values for attribute
	switch ($Type) {
		'single' {
			$AttributeProperties = [PSCustomObject]@{
				adminTextPrefix = 'custom-single-valued-attribute-'
				attributeSyntax = '2.5.5.12'
				isSingleValued  = $true
				oMSyntax        = '64'
			}
		}
		'multi' {
			$AttributeProperties = [PSCustomObject]@{
				adminTextPrefix = 'custom-multi-valued-attribute-'
				attributeSyntax = '2.5.5.12'
				isSingleValued  = $false
				oMSyntax        = '64'
			}
		}
		'time' {
			$AttributeProperties = [PSCustomObject]@{
				adminTextPrefix = 'custom-time-attribute-'
				attributeSyntax = '2.5.5.11'
				isSingleValued  = $true
				oMSyntax        = '24'
			}
		}
		'bool' {
			$AttributeProperties = [PSCustomObject]@{
				adminTextPrefix = 'custom-boolean-attribute-'
				attributeSyntax = '2.5.5.8'
				isSingleValued  = $true
				oMSyntax        = '1'
			}
		}
		Default {
			Write-Host 'Unsupported attribute type provided, exiting...'
			Return
		}
	}

	# refresh schema before update
	Try {
		$Schema.RefreshSchema()
	}
	Catch {
		Return $_
	}

	# format type
	$FormattedType = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($Type.ToLower())

	# create each attribute object
	For ($Index = 0; $Index -lt $Count; $Index++) {
		# create strings
		$AttributeName = '{0}{1}{2}' -f $NamePrefix, $FormattedType, ($Suffix + $Index)
		$Identity = 'CN={0},{1}' -f $AttributeName, $SchemaNamingContext

		# check if attribute exists
		Try {
			$ADObject = Get-ADObject -Server $Server -Identity $Identity
		}
		Catch {
			$ADObject = $null
		}

		If ($null -ne $ADObject) {
			#report attribute WAS found
			Write-Host "Attribute '$($ADObject.Name)' was ALREADY created"
			Continue
		}

		# create attribute hashtable for schema object
		$OtherAttributes = @{
			lDAPDisplayName  = $AttributeName
			adminDisplayName = $AttributeName
			adminDescription = '{0}.{1}' -f $AttributeProperties.adminTextPrefix, ($Suffix + $Index)
			attributeId      = '{0}.{1}' -f $OIDPrefix, ($Suffix + $Index)
			attributeSyntax  = $AttributeProperties.attributeSyntax
			isSingleValued   = $AttributeProperties.isSingleValued
			oMSyntax         = $AttributeProperties.oMSyntax
			searchFlags      = $SearchFlags
		}

		# if attribute should be added to global catalog...
		If ($AddToGlobalCatalog) {
			$OtherAttributes['isMemberOfPartialAttributeSet'] = $true
		}
		
		# declare values
		Write-Host ''
		Write-Host "Attribute '$($AttributeName)' was NOT found and WILL be created as:"
		$OtherAttributes
		Write-Host ''
		
		# define ShouldProcess values
		$ShouldProcessMessage = "Attribute '$AttributeName' WOULD have been created"
		$ShouldProcessAction = 'Create attribute'
		$ShouldProcessTarget = $AttributeName

		# create attribute
		If ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessAction, $ShouldProcessTarget)) {
			# create schema object
			Try {
				New-ADObject -Server $Server -Name $AttributeName -Type 'attributeSchema' -Path $SchemaNamingContext -OtherAttributes $OtherAttributes
			}
			Catch {
				Write-Error "Attribute '$($AttributeName)' was NOT created"
				Return $_
			}

			# report created
			Write-Host "Attribute '$AttributeName' was SUCCESSFULLY created"
		}
	}

	# reload schema after update
	If ($PSCmdlet.ShouldProcess($Server, 'Update active schema')) {
		$RootDSE.Put('schemaUpdateNow', 1)
		$RootDSE.SetInfo()
	}
}

Function Add-ADSchemaAttributesToClass {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param (
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory)]
		[string]$Class,
		[Parameter(Position = 1, Mandatory)]
		[string]$NamePrefix,
		[Parameter(Position = 2, Mandatory)]
		[string]$Type,
		[Parameter(Position = 3)][ValidateRange(1, 65535)]
		[uint16]$Suffix = 1,
		[Parameter(Position = 4)][ValidateRange(1, 65535)]
		[uint16]$Count = 1
	)

	# refresh schema before update
	Try {
		$Schema.RefreshSchema()
	}
	Catch {
		Return $_
	}

	# create strings
	$ClassIdentity = 'CN={0},{1}' -f $Class, $SchemaNamingContext

	# retrieve class
	Try {
		$ClassObject = Get-ADObject -Server $Server -Identity $ClassIdentity -Properties 'mayContain'
	}
	Catch {
		Write-Wanring -Message "Class '$Class' does NOT exist"
		Return $null
	}

	# format type
	$FormattedType = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($Type.ToLower())

	# add each attribute object to class
	For ($Index = 0; $Index -lt $Count; $Index++) {
		# create strings
		$AttributeName = '{0}{1}{2}' -f $NamePrefix, $FormattedType, ($Suffix + $Index)
		$Identity = 'CN={0},{1}' -f $AttributeName, $SchemaNamingContext

		# verify attribute
		Try {
			$null = Get-ADObject -Server $Server -Identity $Identity
		}
		Catch {
			Write-Warning -Message "Attribute '$AttributeName' was NOT found"
			Return
		}

		# if class object already contains attribute...
		If ($ClassObject.mayContain.Contains($AttributeName)) {
			# report and continue
			Write-Host "Attribute '$AttributeName' was ALREADY in the MayContain of '$Class'"
			Continue
		}

		# define ShouldProcess values
		$ShouldProcessMessage = "Attribute '$AttributeName' WOULD have been added to the MayContain of '$Class'"
		$ShouldProcessAction = "Add attribute to '$Class' class"
		$ShouldProcessTarget = $AttributeName

		# add attribute to mayContain attribute of class
		If ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessAction, $ShouldProcessTarget)) {
			# update schema object
			Try {
				Set-ADObject -Server $Server -Identity $ClassObject -Add @{ mayContain = $AttributeName }
			}
			Catch {
				Write-Warning -Message "Attribute '$AttributeName' was NOT added to the MayContain of '$Class'"
				Return $_
			}

			# report updated
			Write-Host "Attribute '$AttributeName' was SUCCESSFULLY added to the MayContain of '$Class'"
		}
	}

	# reload schema after update
	If ($PSCmdlet.ShouldProcess($Server, 'Update active schema')) {
		$RootDSE.Put('schemaUpdateNow', 1)
		$RootDSE.SetInfo()
	}
}

Function Add-ADSchemaClass {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	Param (
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory)]
		[string]$OIDPrefix,
		[Parameter(Position = 1, Mandatory)]
		[string]$NamePrefix,
		[Parameter(Position = 2, Mandatory)]
		[string]$Type,
		[Parameter(Position = 3)][ValidateRange(1, 65535)]
		[uint16]$Suffix = 1,
		[switch]$IncludeSuffixInName
	)

	#check attribute type variable
	switch ($Type) {
		'aux' {
			$ClassProperties = [PSCustomObject]@{
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

	# refresh schema before update
	Try {
		$Schema.RefreshSchema()
	}
	Catch {
		Return $_
	}

	# create suffix string
	If ($IncludeSuffixInName) {
		$SuffixString = $Suffix.ToString()
	}
	Else {
		$SuffixString = 'Class'
	}

	# create strings
	$ClassName = '{0}{1}{2}' -f $NamePrefix, [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($Type.ToLower()), $SuffixString
	$ClassIdentity = '{0}{1}{2}' -f $ClassName, $SchemaNamingContext

	# retrieve class object
	Try {
		$ClassObject = Get-ADObject -Server $Server -Identity $ClassIdentity
	}
	Catch {
		$ClassObject = $null
	}

	# if class object already exists...
	If ($null -ne $ClassObject) {
		# report and return
		Write-Host "Class '$($ClassObject.Name)' was ALREADY created"
		Return
	}

	# create class
	$OtherAttributes = @{
		lDAPDisplayName     = $ClassName
		adminDisplayName    = $ClassName
		adminDescription    = $ClassName
		governsID           = '{0}.{1}' -f $OIDPrefix, $Suffix
		objectClassCategory = $ClassProperties.objectClassCategory
		subClassOf          = $ClassProperties.subClassOf
		rdnAttId            = $ClassProperties.rdnAttId
		systemOnly          = $ClassProperties.systemOnly
	}

	# declare values
	Write-Host ''
	Write-Host "Class '$ClassName' was NOT found and WILL be created as:"
	$OtherAttributes
	Write-Host ''

	# define ShouldProcess values
	$ShouldProcessMessage = "Class '$ClassName' WOULD have been created"
	$ShouldProcessAction = 'Create auxiliary class'
	$ShouldProcessTarget = $ClassName

	# create the class
	If ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessAction, $ShouldProcessTarget)) {
		# create schema object
		Try {
			New-ADObject -Server $Server -Name $ClassName -Type 'classSchema' -Path $SchemaNamingContext -OtherAttributes $OtherAttributes
		}
		Catch {
			Write-Warning -Message "Class '$ClassName' was NOT created"
			Return $_
		}

		# report created
		Write-Host "Class '$ClassName' was SUCCESSFULLY created"
	}

	# reload schema after update
	If ($PSCmdlet.ShouldProcess($Server, 'Update active schema')) {
		$RootDSE.Put('schemaUpdateNow', 1)
		$RootDSE.SetInfo()
	}
}

Function Add-ADSchemaClassToParent {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param (
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory)]
		[string]$Class,
		[Parameter(Position = 1, Mandatory)]
		[string]$ParentClass
	)

	# refresh schema before update
	Try {
		$Schema.RefreshSchema()
	}
	Catch {
		Return $_
	}

	# create strings
	$ClassIdentity = 'CN={0},{1}' -f $Class, $SchemaNamingContext
	$ParentClassIdentity = 'CN={0},{1}' -f $ParentClass, $SchemaNamingContext

	# verify class
	Try {
		$ClassObject = Get-ADObject -Server $Server -Identity $ClassIdentity -Properties 'governsID'
	}
	Catch {
		Write-Warning -Message "Class '$Class' was NOT found"
		Return
	}

	# verify the parent class object
	Try {
		$ParentClassObject = Get-ADObject -Server $Server -Identity $ParentClassIdentity -Properties 'auxiliaryClass'
	}
	Catch {
		Write-Warning -Message "Class '$ParentClass' was NOT found"
		Return
	}

	# if parent class auxiliary class attribute already contains child class...
	If ($ParentClassObject.auxiliaryClass.Contains($Class)) {
		# report and return
		Write-Host "Class '$Class' was ALREADY an auxiliary class of '$ParentClass'"
		Return
	}

	# define ShouldProcess values
	$ShouldProcessMessage = "Class '$Class' WOULD have been added as an auxiliary class of '$ParentClass'"
	$ShouldProcessAction = "Add auxiliary class to '$ParentClass' class"
	$ShouldProcessTarget = $Class

	# add governsID of child class to auxiliaryClass attribute of parent class
	If ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessAction, $ShouldProcessTarget)) {
		Try {
			Set-ADObject -Server $Server -Identity $ParentClassIdentity -Add @{ auxiliaryClass = $ClassObject.governsID }
			Write-Host "Class '$Class' was SUCCESSFULLY added as an auxiliary class of '$ParentClass'"
		}
		Catch {
			Write-Warning -Message "Class '$Class' was NOT added as an auxiliary class of '$ParentClass'"
			Return $_
		}
	}

	# reload schema after update
	If ($PSCmdlet.ShouldProcess($Server, 'Update active schema')) {
		$RootDSE.Put('schemaUpdateNow', 1)
		$RootDSE.SetInfo()
	}
}

Function Get-ADSchemaClass {
	[CmdletBinding()]
	Param (
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

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
		$ad_schema_object = Get-ADObject -Server $Server -SearchBase $SchemaNamingContext -LDAPFilter $ad_schema_classes_ldapquery -Properties *

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
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
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
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$ObjectClass,
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
		[Parameter(DontShow)]
		[object]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema(),
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = $Schema.Name,
		[Parameter(DontShow)]
		[string]$Server = $Schema.SchemaRoleOwner.Name,
		[Parameter(DontShow)]
		[object]$RootDSE = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$Server/RootDSE"),
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$Attribute,
		[Parameter(Position = 2)]
		[switch]$Reset
	)

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
		$ad_schema_object = Get-ADObject -Server $Server -SearchBase $SchemaNamingContext -LDAPFilter $ad_schema_attribute_ldapquery -Properties *

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
			$function_reply += 'ERROR-attribute-not-valid-for-object'
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Clear $Attribute
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Add @{ $Attribute = $attribute_singlevalue }
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Replace @{ $Attribute = $attribute_singlevalue }
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Replace @{ $Attribute = $AttributeValues }
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Add @{ $Attribute = $attr_values_to_add }
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
						Set-ADObject -Server $Server -Identity $object_to_update.DistinguishedName -Remove @{ $Attribute = $attr_values_to_rem }
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
$FunctionsToExport = @(
	'Add-ADSchemaAttributes'
	'Add-ADSchemaAttributesToClass'
	'Add-ADSchemaClassToParent'
	'Add-ADSchemaClass'
	'Get-ADSchemaClass'
	'Get-ADSchemaClassAncestry'
	'Get-ADSchemaClassAttributes'
	'Get-ADSchemaAttribute'
	'Set-ADAttribute'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport