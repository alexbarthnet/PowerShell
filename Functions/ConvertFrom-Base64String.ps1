Function ConvertFrom-Base64String {
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$String,
		[Parameter(Position = 1)][ValidateSet('ASCII', 'UTF8', 'Unicode')]
		[string]$Encoding = 'Unicode'
	)

	Switch ($Encoding) {
		{ 'Unicode' } { [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($String)); Break }
		{ 'ASCII' } { [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($String)); Break }
		{ 'UTF8' } { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($String)); Break }
		Default { Write-Error -Message 'Unsupported or unknown encoding format' }
	}
}
