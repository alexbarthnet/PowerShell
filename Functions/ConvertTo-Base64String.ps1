Function ConvertTo-Base64String {
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$String,
		[Parameter(Position = 1)][ValidateSet('ASCII', 'UTF8', 'Unicode')]
		[string]$Encoding = 'Unicode'
	)

	Switch ($Encoding) {
		'Unicode' { [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($String)); Break }
		'ASCII' { [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($String)); Break }
		'UTF8' { [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($String)); Break }
		Default { Write-Error -Message 'Unsupported or unknown encoding format' }
	}
}
