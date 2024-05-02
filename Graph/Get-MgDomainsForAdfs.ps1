#requires -Modules Microsoft.Graph.Identity.DirectoryManagement

[CmdletBinding()]
Param(
	[Parameter(Mandatory)][ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
	[string]$Json,
	[Parameter]
	[string]$Datetime = ([datetime]::Now.ToString('yyyyMMddThhmmssfffZ'))
)

Begin {
	Function Assert-InteractiveSession {
		[Environment]::UserInteractive -and -not [System.Environment]::GetCommandLineArgs().Where({ $_.StartsWith('-NonI', [System.StringComparison]::InvariantCultureIgnoreCase) })
	}

	# define error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
}

Process {
	# retrieve JSON data
	Try {
		$JsonData = [array](Get-Content -Path $Json | ConvertFrom-Json)
	}
	Catch {
		Write-Output 'ERROR: retrieving ADFS JSON file'
		Throw $_
	}

	# test FQDN from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Hash)) {
		Write-Output 'Hash was not found in JSON file'
		Return
	}

	# test path from JSON data
	If ([string]::IsNullOrEmpty($JsonData.Path)) {
		Write-Output 'Path was not found in JSON file'
		Return
	}

	# define folder path
	$DirectoryPath = Join-Path -Path $JsonData.Path -ChildPath 'mgdomains'

	# if path not found...
	If ((Test-Path -Path $DirectoryPath -PathType Container) -eq $false) {
		# create file
		Try {
			New-Item -ItemType Directory -Path $DirectoryPath
		}
		Catch {
			Throw $_
		}
	}

	# define file path
	$FilePath = Join-Path -Path $Path -ChildPath "mgdomains-for-adfs-csv-$DateTime.txt"

	# if path not found...
	If ((Test-Path -Path $FilePath -PathType Leaf) -eq $false) {
		# create file
		Try {
			New-Item -ItemType File -Path $FilePath
		}
		Catch {
			Throw $_
		}
	}

	# define parameters
	$ConnectMgGraph = @{
		Scope = 'Domain.Read.All'
		TenantId = $TenantId
	}

	# if not interactive...
	If (Assert-InteractiveSession -eq $false) {
		# update parameters
		$ConnectMgGraph['ClientId'] = $ClientId
		$ConnectMgGraph['Certificate'] = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.Thumbprint -eq $JsonData.Hash }
	}

	# connect to graph
	Try {
		$null = Connect-MgGraph @ConnectMgGraph
	}
	Catch {
		Write-Warning "could not connect to graph: $($_.ToString())"
		Throw $_
	}

	# retrieve domains from graph
	Try {
		$MgDomains = Get-MgDomain
	}
	Catch {
		Throw $_
	}

	# create list for objects
	$MgOutput = [System.Collections.Generic.List[System.String]]::new()

	# add header
	$MgOutput.Add('Name,RootDomain,Authentication')

	# process domains
	:NextMgDomain ForEach ($MgDomain in $MgDomains) {
		# define values for ease
		$DomainId = $MgDomain.Id
		$AuthType = $MgDomain.AuthenticationType
	
		# add root domains to list immediately
		If ($MgDomain.IsRoot) {
			$MgOutput.Add("$DomainId,,$AuthType")
			Continue NextMgDomain
		}

		# get parent domain
		$ParentDomainId = $DomainId.Split('.', 2)[1]

		# find root domain
		For ($ParentDomainId = $DomainId.Split('.', 2)[1], [string]::IsNullOrEmpty($ParentDomainId), $ParentDomainId = $ParentDomainId.Split('.', 2)[1]) {
			If ($MgDomains.Where({ $_.Id -eq $ParentDomainId -and $_.IsRoot })) {
				# ...add child domain and root 
				$MgOutput.Add("$DomainId,$ParentDomainId,$AuthType")
				# clear parent domain
				$ParentDomainId = [string]::Empty
			}
		}

		# while parent domain is not empty...
		While (![string]::IsNullOrEmpty($ParentDomainId)) {
			# if parent domain is a root domain...
			If ($MgDomains.Where({ $_.Id -eq $ParentDomainId -and $_.IsRoot })) {
				# ...add child domain and root 
				$MgOutput.Add("$DomainId,$ParentDomainId,$AuthType")
				Continue NextMgDomain
			}
			# get next parent domain
			$ParentDomainId = $ParentDomainId.Split('.', 2)[1]
		}
	}

	# write output
	Try {
		Set-Content -Path $FilePath -Value $MgOutput
	}
	Catch {
		Throw $_
	}
}
