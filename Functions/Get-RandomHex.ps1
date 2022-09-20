Function Get-RandomHex {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, Position = 0)]
		[int]$Length
	)

	# clear required objects
	$key = $null
	switch ($true) {
		{ $Length -gt 0 } {
			Do { $key += '{0:x}' -f (Get-Random -Max 16) } Until ($key.Length -eq $Length)
			$key
		}
		Default {
			Write-Output 'Provide a length!'
		}
	}
}
