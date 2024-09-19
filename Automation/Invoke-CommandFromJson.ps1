#requires -Module TranscriptWithHostAndDate

<#
.SYNOPSIS
Run a PowerShell command with optional parameters from a JSON file.

.DESCRIPTION
Run a PowerShell command with optional parameters from a JSON file. The command can be an existing cmdlet, function, or script.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, or Add parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Add parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Remove parameters.

.PARAMETER Command
The command to run. This parameter can be an existing cmdlet, function, or script. A script must be a fully qualified path.

.PARAMETER Parameters
Hashtable with parameters for the command.

.PARAMETER Order
An unsigned 16-bit integer representing the order that the command will be run when multiple commands are defined in a JSON file. The first command is assigned a value of 1 and each additional command is assigned an incrementing value. Providing a value that is already assigned will prompt the user to overwrite the command assigned the provided value.

.INPUTS
String. The path to a JSON file.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Show

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Clear

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'Restart-Service'

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'Restart-Service' -Order 2

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'C:\path\to\script.ps1'

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'C:\path\to\script.ps1' -Order 3

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'Restart-Service' -Parameters @{ Name = 'DnsClient' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'Restart-Service' -Order 4 -Parameters @{ Name = 'DnsClient' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'C:\path\to\script.ps1' -Parameters @{ FirstParameterName = 'FirstParameterValue'; SecondParameterName = 'SecondParameterValue' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'C:\path\to\script.ps1' -Order 5 -Parameters @{ FirstParameterName = 'FirstParameterValue'; SecondParameterName = 'SecondParameterValue' }

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True, Position = 0)]
	[string]$Json,
	# script parameters - mode
	[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	# script parameter - command to run
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Command,
	# script parameter - parameters for command
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[hashtable]$Parameters,
	# script parameter - expression for evaluating command
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[string]$Expression,
	# script parameter - order of command
	[Parameter(Mandatory = $False, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[uint16]$Order = 1,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
)

Begin {
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

	# start transcript with default parameters
	Try {
		Start-TranscriptWithHostAndDate
	}
	Catch {
		Throw $_
	}
}

Process {
	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction 'Stop' | ConvertFrom-Json)
		}
		Catch {
			Write-Warning -Message "could not read configuration file: '$Json'"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# ...and Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create configuration file: '$Json'"
				Return $_
			}
			# ...create JSON data object as empty array
			$JsonData = @()
		}
		# ...and Add not set...
		Else {
			# ...report and return
			Write-Warning -Message "could not find configuration file: '$Json'"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		# show configuration file
		$Show {
			Write-Verbose -Verbose -Message "Displaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			Try {
				[string]::Empty | Set-Content -Path $Json
				Write-Verbose -Verbose -Message "Cleared configuration file: '$Json'"
			}
			Catch {
				Write-Warning -Message "could not clear configuration file: '$Json'"
				Return $_
			}
		}
		# remove entry from configuration file
		$Remove {
			# if order provided...
			If ($PSBoundParameters.ContainsKey('Order')) {
				# remove existing entry by primary key(s)...
				$JsonData = [array]($JsonData.Where({ $_.Command -ne $Command -and $_.Order -ne $Order }))
			}
			# if order not provided...
			Else {
				# remove existing entry by primary key(s)...
				$JsonDataToRemove = [array]($JsonData.Where({ $_.Command -eq $Command }))
				# if JSON data empty...
				If ($JsonDataToRemove.Count -gt 1) {
					# warn and inquire
					Write-Warning -Message "Found multiple entries with '$Command' in configuration file: '$Json' `nAll matching entries will be removed" -WarningAction 'Inquire'
				}
				# remove existing entry by primary key(s)...
				$JsonData = [array]($JsonData.Where({ $_.Command -ne $Command }))
			}

			# update JSON file
			Try {
				# if JSON data empty...
				If ($JsonData.Count -eq 0) {
					# clear JSON data
					[string]::Empty | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Removed '$Command' from configuration file: '$Json'"
				}
				Else {
					# export JSON data
					$JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Removed '$Command' from configuration file: '$Json'"
					$JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
				Return $_
			}
		}
		# add entry to configuration file
		$Add {
			# if order parameter not provided...
			If (!$PSBoundParameters.ContainsKey('Order')) {
				# find first unassigned order value
				For ($Order = 1; $null -eq $JsonEntryWithOrderValue; $Order++) {
					# if order assigned to existing entry...
					$JsonEntryWithOrderValue = $JsonData.Where({ $_.Order -eq $Order })
				}
			}

			# if existing entry has same primary key(s)...
			If ($JsonData.Where({ $_.Order -eq $Order })) {
				# inquire before removing existing entry
				Write-Warning -Message "Will overwrite existing entry for '$Command' with order '$Order' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction 'Inquire'
				# remove existing entry with same primary key(s)
				$JsonData = [array]($JsonData.Where({ $_.Command -ne $Command -and $_.Order -ne $Order }))
			}

			# create ordered dictionary for custom object
			$JsonParameters = [ordered]@{
				Order      = [uint16]$Order
				Command    = [string]$Command
				Parameters = [hashtable]$Parameters
			}

			# add Expression if provided
			If ($script:Expression) {
				$JsonParameters['Expression'] = [string]$Expression
			}

			# add current time as FileDateTimeUniversal
			$JsonParameters['Updated'] = (Get-Date -Format FileDateTimeUniversal)

			# create custom object from hashtable
			$JsonEntry = [pscustomobject]$JsonParameters

			# add entry to data
			$JsonData += $JsonEntry

			# update JSON file
			Try {
				# export JSON data
				$JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Verbose -Verbose -Message "Added '$Command' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
				Return $_
			}
		}
		# process entries in configuration file
		Default {
			# declare start
			Write-Host "`nCalling commands from '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: $Json"
				Return
			}

			# sort JsonData by Order then Path
			$JsonData = $JsonData | Sort-Object -Property 'Order', 'Command'

			# initialize exception boolean
			$ExceptionCaught = $false

			# process configuration file
			:JsonEntry ForEach ($JsonEntry in $JsonData) {
				# if exception caught on previous pass...
				If ($ExceptionCaught) {
					# return immediately
					Return
				}

				# validate values present in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($JsonEntry.Command)) {
						Write-Warning -Message "required entry (Command) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.Order)) {
						Write-Warning -Message "required value (Order) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.Order -and -not [uint16]::TryParse($JsonEntry.Order, [ref][uint16]::MinValue)) {
						Write-Warning -Message 'required value (Order) found in configuration file but cannot be parsed into a UInt16 object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.Parameters -and $JsonEntry.Parameters -isnot [System.Management.Automation.PSCustomObject]) {
						Write-Warning -Message 'optional value (Parameters) found in configuration file but was not parsed into a PSCustomObject object'
						Continue NextJsonEntry
					}
				}

				# if command is a file
				If (Test-Path -Path $JsonEntry.Command -PathType 'Leaf') {
					# retrieve file
					Try {
						$Item = Get-Item -Path $JsonEntry.Command -ErrorAction 'Stop'
					}
					Catch {
						Write-Warning -Message "could not access file for Command: '$($JsonEntry.Command)'"
						Continue NextJsonEntry
					}

					# check extension of file
					switch ($Item.Extension) {
						'.bat' { $CommandType = 'Batch' }
						'.exe' { $CommandType = 'Executable' }
						'.ps1' { $CommandType = 'Script' }
						Default {
							Write-Warning -Message "unsupported '$($Item.Extension)' extension found on file for Command: '$($JsonEntry.Command)'"
							Continue NextJsonEntry
						}
					}

					# define command name from basename of file
					$CommandName = $Item.BaseName
				}
				# if command is not a file...
				Else {
					# retrieve command and return command type
					Try {
						$CommandType = Get-Command -Name $JsonEntry.Command -ErrorAction 'Stop' | Select-Object -ExpandProperty 'CommandType'
					}
					Catch {
						Write-Warning -Message "could not locate PowerShell command for Command: '$($JsonEntry.Command)'"
						Continue NextJsonEntry
					}

					# define command name from PowerShell command
					$CommandName = $JsonEntry.Command
				}

				# if trigger expression defined...
				If ($null -ne $JsonEntry.Expression) {
					# invoke trigger expression
					Try {
						$Evaluation = Invoke-Expression -Command $JsonEntry.Expression
					}
					Catch {
						Write-Warning -Message "exception caught calling '$($JsonEntry.Expression)' Expression: $($_.Exception.ToString())"
						Continue NextJsonEntry
					}

					# if trigger evaluation is not a boolean...
					If ($Evaluation -isnot [boolean]) {
						Write-Warning -Message "the evaluation of the '$($JsonEntry.Expression)' Expression returned an invalid type: '$($Evaluation.GetType().FullName)'"
						Continue NextJsonEntry
					}

					# if trigger evaluation is false...
					If ($Evaluation -eq $false) {
						Write-Warning -Message "the evaluation of the '$($JsonEntry.Expression)' Expression returned 'false'"
						Continue NextJsonEntry
					}
				}

				# if parameters provided...
				If ($null -ne $JsonEntry.Parameters) {
					# convert parameters to a hashtable
					Try {
						$Parameters = ConvertTo-Collection -InputObject $JsonEntry.Parameters -Ordered:$false
					}
					Catch {
						Write-Warning -Message "exception caught converting the Parameters object to a hashtable: $($_.Exception.ToString())"
						Continue NextJsonEntry
					}
				}
				# if parameters not provided...
				Else {
					# create empty hashtable to allow splatting without changing call in next section
					$Parameters = @{}
				}

				# suspend current transcript
				Try {
					Suspend-TranscriptWithHostAndDate
				}
				Catch {
					Write-Warning -Message "could not suspend transcript for script: $((Get-PSCallStack)[0].Command)"
					Continue NextJsonEntry
				}

				# start transcript for command
				Try {
					Start-TranscriptWithHostAndDate -TranscriptName $CommandName
				}
				Catch {
					Write-Warning -Message "could not start transcript for command: $($JsonEntry.Command)"
					Continue NextJsonEntry
				}

				# call script or function with parameters
				Try {
					& $JsonEntry.Command @Parameters
				}
				Catch {
					Write-Warning -Message "exception caught calling '$($JsonEntry.Command)' $CommandType command: $($_.Exception.ToString())"
					$ExceptionCaught = $true
				}

				# stop transcript for command
				Try {
					Stop-TranscriptWithHostAndDate -TranscriptName $CommandName
				}
				Catch {
					Write-Warning -Message "could not stop transcript for command: $($JsonEntry.Command)"
					Continue NextJsonEntry
				}

				# resume current transcript
				Try {
					Resume-TranscriptWithHostAndDate
				}
				Catch {
					Write-Warning -Message "could not resume transcript for script: $((Get-PSCallStack)[0].Command)"
					Continue NextJsonEntry
				}
			}
		}
	}
}

End {
	# stop transcript with default parameters
	Try {
		Stop-TranscriptWithHostAndDate
	}
	Catch {
		Throw $_
	}
}
