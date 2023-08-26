[CmdletBinding()]
param (
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object[]]$VM,
	[Parameter(Mandatory = $true)]
	[string]$ComputerName,
	[Parameter(Mandatory = $true)][ValidateScript({ ([Uri]$_).IsUnc })]
	[string]$Path,
	[Parameter()]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	Function Test-PSSessionByName {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# if computername matches hostname...
		If ($ComputerName -eq $Hostname) {
			# ...return false as no session is needed
			Return $false
		}

		# if hashtable is missing...
		If ($script:PSSessions -isnot [hashtable]) {
			# ...create hashtable
			$script:PSSessions = @{}
		}

		# if session exists for computer...
		If ($script:PSSessions.ContainsKey($ComputerName) -and $script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# ...return true as session can already be referenced
			Return $true
		}
		Else {
			# ...try to create a session
			Try {
				$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
			}
			Catch {
				Return $false
			}
			# ...validate session
			If ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
				Return $true
			}
			Else {
				Return $false
			}
		}
	}

	Function Get-PSSessionInvoke {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[hashtable]$ArgumentList
		)

		# default arguments passed to ScriptBlock run by Invoke-Command
		$ArgumentListForInvokeCommand = @{
			# ErrorAction for ScriptBlock run by Invoke-Command
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# optional arguments passed to ScriptBlock run by Invoke-Command
		ForEach ($Key in $ArgumentList.Keys) {
			$ArgumentListForInvokeCommand[$Key] = $ArgumentList[$Key]
		}

		# define hashtable for Invoke-Command
		$InvokeCommand = @{
			# ErrorAction for Invoke-Command itself
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			# arguments passed to script block executed by Invoke-Command
			ArgumentList = $ArgumentListForInvokeCommand
		}

		# if computername matches hostname...
		If ($ComputerName -eq $Hostname) {
			# ...update hashtable to invoke commands in the current scope on the local computer
			$InvokeCommand['NoNewScope'] = $true
			# ...return hashtable
			Return $InvokeCommand
		}

		# check for session
		Try {
			$SessionExists = Test-PSSessionByName -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# if a session exists...
		If ($SessionExists) {
			# ...update hashtable to invoke commands in the session
			$InvokeCommand['Session'] = $script:PSSessions[$ComputerName]
			# ...return hashtable
			Return $InvokeCommand
		}
		Else {
			# ...update hashtable to invoke commands in a standalone session
			$InvokeCommand['ComputerName'] = $ComputerName
			# ...return hashtable
			Return $InvokeCommand
		}
	}

	Function Get-ClusterName {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# test for cluster
		Try {
			$ClusterName = Invoke-Command @InvokeCommand -ScriptBlock {
				$GetItemProperty = @{
					Path        = 'HKLM:\System\CurrentControlSet\Services\ClusSvc\Parameters'
					Name        = 'ClusterName'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		Catch {
			Throw $_
		}

		# return the cluster name
		If ($null -ne $ClusterName) {
			Return $ClusterName
		}
		Else {
			Return [string]::Empty
		}
	}

	# get hashtable for InvokeCommand splat
	Try {
		$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# get local computer cluster name
	Try {
		$LocalClusterName = Get-ClusterName -ComputerName $HostName
	}
	Catch {
		Throw $_
	}

	# get remote computer cluster name
	Try {
		$RemoteClusterName = Get-ClusterName -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# get properties of local computer system
	Try {
		$ComputerSystem = Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'Name', 'Domain'
	}
	Catch {
		Throw $_
	}

	# get name of local windows identity
	Try {
		$WindowsIdentityName = [System.Security.Principal.NTAccount]::new("$($ComputerSystem.Name)$@$($ComputerSystem.Domain)").Translate([System.Security.Principal.SecurityIdentifier]).Translate([System.Security.Principal.NTAccount]).Value
	}
	Catch {
		Throw $_
	}

	# add local computer to remote computer administrators group
	Try {
		Invoke-Command @InvokeCommand -ScriptBlock {
			Add-LocalGroupMember -Group 'Administrators' -Member $using:WindowsIdentityName -ErrorAction Stop
		}
	}
	Catch {
		Throw $_
	}

	# check path from local computer
	If (-not (Test-Path -Path $Path -PathType Container)) {
		# create folder
		Try {
			$null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop
		}
		Catch {
			Throw $_
		}
	}

	# split path
	$ComputerPath, $SharePath, $ChildPath = $Path.Split('\', 3, [System.StringSplitOptions]::RemoveEmptyEntries)

	# get remote parent path from share path
	Try {
		$ParentPath = Invoke-Command @InvokeCommand -ScriptBlock {
			(Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -eq $using:SharePath }).Path
		}
	}
	Catch {
		Throw $_
	}
}

Process {
	# convert any string input to VM objects
	If ($VM -isnot [Microsoft.HyperV.PowerShell.VirtualMachine]) {
		Try {
			$VM = Get-VM -Name $VM -ErrorAction Stop
		}
		Catch {
			Throw $_
		}
	}

	# get VM name
	$Id = $VM.Id
	$Name = $VM.Name
	$State = $VM.State

	# get VM from remote server
	Try {
		$VmOnServer = Invoke-Command @InvokeCommand -ScriptBlock {
			Get-VM -Id $using:Id -ErrorAction SilentlyContinue
		}
	}
	Catch {
		Throw $_
	}

	# return if VM found on remote server
	If ($null -ne $VmOnServer) {
		Write-Warning 'VM has already been dead migrated to destination server'
		Return
	}

	# get VM from cluster on remote server
	If (-not [string]::IsNullOrEmpty($RemoteClusterName)) {
		Try {
			$VmInCluster = Invoke-Command @InvokeCommand -ScriptBlock {
				Get-ClusterGroup -VMId $using:Id -ErrorAction SilentlyContinue
			}
		}
		Catch {
			Throw $_
		}
	}

	# return if VM found in cluster on remote server
	If ($null -ne $VmInCluster) {
		Write-Warning 'VM has already been dead migrated to destination cluster'
		Return
	}

	# get VM from local cluster
	If (-not [string]::IsNullOrEmpty($LocalClusterName)) {
		Try {
			$ClusterGroup = Get-ClusterGroup -VMId $Id -ErrorAction SilentlyContinue
		}
		Catch {
			Throw $_
		}
	}

	# remove VM from local cluster
	If ($null -ne $ClusterGroup) {
		Try {
			$null = Remove-ClusterGroup -VMId $Id -RemoveResources -Force -ErrorAction Stop
		}
		Catch {
			Throw $_
		}
	}

	# stop VM if running
	If ($State -eq 'running') {
		Try {
			Stop-VM -VM $VM -Force -ErrorAction Stop
		}
		Catch {
			Throw $_
		}
	}

	# set VM to not start
	Try {
		Set-VM -VM $VM -AutomaticStartAction Nothing -ErrorAction Stop
	}
	Catch {
		Throw $_
	}

	# export VM
	Try {
		Export-VM -VM $VM -Path $Path -ErrorAction Stop
	}
	Catch {
		Throw $_
	}

	# define file on remote computer
	$FilePath = "$ChildPath\$Name\Virtual Machines\$Id.vmcx"

	# create remote path 
	Try {
		$PathForImport = Invoke-Command @InvokeCommand -ScriptBlock {
			Join-Path -Path $using:ParentPath -ChildPath $using:FilePath
		}
	}
	Catch {
		Throw $_
	}

	# import VM on remote computer
	Try {
		Invoke-Command @InvokeCommand -ScriptBlock {
			$null = Import-VM -Path $using:PathForImport -Register -ErrorAction Stop
		}
	}
	Catch {
		Throw $_
	}

	# if remote computer is clustered...
	If (-not [string]::IsNullOrEmpty($RemoteClusterName)) {
		# ...add VM to cluster by ID
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				$null = Add-ClusterVirtualMachineRole -VMId $using:Id -ErrorAction Stop
			}
		}
		Catch {
			Throw $_
		}
	}

	# if VM was running on local computer...
	If ($State -eq 'running') {
		# ...get VM by Id on remote computer then start VM
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Get-VM -Id $using:Id -ErrorAction Stop | Start-VM -ErrorAction Stop
			}
		}
		Catch {
			Throw $_
		}
	}

	# remove VM on local computer
	# to be completed
}

End {
	# remove local computer from remote computer administrators group
	Try {
		Invoke-Command @InvokeCommand -ScriptBlock {
			$Administrators = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
			If ($Administrators.Name -contains $using:WindowsIdentityName) {
				Remove-LocalGroupMember -Group 'Administrators' -Member $using:WindowsIdentityName -ErrorAction Stop
			}
		}
	}
	Catch {
		Throw $_
	}
}
