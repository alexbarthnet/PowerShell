function Lock-Workstation {
    param(
        [string]$AssemblyName = 'DynamicAssembly',
        [string]$ModuleName = 'DynamicModule',
        [string]$TypeName = 'DynamicType'
    )

    begin {
        ################################
        # define PowerShell functions
        ################################

        function Add-MethodToType {
            [OutputType([System.Reflection.Emit.MethodBuilder])]
            param(
                [Parameter(Mandatory = $true, Position = 0)]
                [System.Reflection.Emit.TypeBuilder]$TypeBuilder,
                [Parameter(Mandatory = $true, Position = 1)]
                [String]$MethodName,
                [Parameter(Mandatory = $true, Position = 2)]
                [System.Reflection.MethodAttributes]$MethodAttributes,
                [Parameter(Mandatory = $true, Position = 3)]
                [Type]$ReturnType,
                [Parameter(Mandatory = $true, Position = 4)][AllowEmptyCollection()]
                [Type[]]$MethodParameters
            )

            # create the method
            try {
                return $TypeBuilder.DefineMethod($MethodName, $MethodAttributes, [System.Reflection.CallingConventions]::Standard, $ReturnType, $MethodParameters)
            }
            catch {
                return $_
            }
        }

        function New-DllImportAttribute {
            [OutputType([System.Reflection.Emit.CustomAttributeBuilder])]
            param(
                [Parameter(Mandatory = $true, Position = 0)]
                [String]$Library,
                [Parameter(Mandatory = $true, Position = 1)]
                [String]$EntryPoint
            )

            # retrieve the constructor for importing the DLL
            $DllImportConstructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([String]))

            # define the named fields for the import
            [System.Reflection.FieldInfo[]]$NamedFields = @(
                [Runtime.InteropServices.DllImportAttribute].GetField('EntryPoint'),
                [Runtime.InteropServices.DllImportAttribute].GetField('PreserveSig'),
                [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError'),
                [Runtime.InteropServices.DllImportAttribute].GetField('CallingConvention'),
                [Runtime.InteropServices.DllImportAttribute].GetField('CharSet')
            )

            # define the values of the named fields
            [Object[]]$FieldValues = @(
                $EntryPoint,
                $true,
                $true,
                [Runtime.InteropServices.CallingConvention]::Winapi,
                [Runtime.InteropServices.CharSet]::Unicode
            )

            # create the method attributes
            try {
                return [System.Reflection.Emit.CustomAttributeBuilder]::new($DllImportConstructor, @($Library), $NamedFields, $FieldValues)
            }
            catch {
                return $_
            }
        }

        ################################
        # define dynamic assembly
        ################################

        # create the name for the dynamic assembly
        $DynamicAssemblyName = [System.Reflection.AssemblyName]::new($AssemblyName)

        # define the builder for a new assembly (the container for modules) and limit it to memory only (second parameter)
        [System.Reflection.Emit.AssemblyBuilder]$AssemblyBuilder = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($DynamicAssemblyName, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)

        # define the builder for a new module (the container for types) that does not emit symbol information
        [System.Reflection.Emit.ModuleBuilder]$ModuleBuilder = $AssemblyBuilder.DefineDynamicModule($ModuleName)

        # define the builder for a new type and make it public (second parameter)
        [System.Reflection.Emit.TypeBuilder]$TypeBuilder = $ModuleBuilder.DefineType($TypeName, [System.Reflection.TypeAttributes]::Public)

        ################################
        # define unmanaged methods
        ################################

        ### LockWorkStation method

        # define original function
        $OriginalFunction = @{
            Library    = 'user32.dll'
            Name       = 'LockWorkStation'
            Parameters = @([System.Type]::EmptyTypes)
            ReturnType = [Int32]
        }

        # define parameters for adding method to type definition
        $AddMethodToType = @{
            TypeBuilder      = $TypeBuilder
            MethodAttributes = [System.Reflection.MethodAttributes]::Public -bor [System.Reflection.MethodAttributes]::Static
            MethodName       = $OriginalFunction.Name
            MethodParameters = $OriginalFunction.Parameters
            ReturnType       = $OriginalFunction.ReturnType
        }

        # add method to type definition
        [System.Reflection.Emit.MethodBuilder]$DynamicMethod = Add-MethodToType @AddMethodToType

        # create custom attribute for importing method from DLL
        [System.Reflection.Emit.CustomAttributeBuilder]$DllImportAttribute = New-DllImportAttribute -Library $OriginalFunction.Library -EntryPoint $OriginalFunction.Name

        # apply custom attribute to method
        $DynamicMethod.SetCustomAttribute($DllImportAttribute)

        ################################
        # create dynamic assembly
        ################################

        # create the dynamic type
        $DynamicType = $TypeBuilder.CreateType()
    }

    process {
        # call method
        $MethodReturn = $DynamicType::LockWorkstation()

        # if method return was not 1...
        If ($MethodReturn -ne 1) {
            Write-Warning -Message "could not lock workstation"
        }
    }

    end {
        ################################
        # destroy dynamic assembly
        ################################

        # destroy the dynamic type
        $null = $DynamicType
    }
}