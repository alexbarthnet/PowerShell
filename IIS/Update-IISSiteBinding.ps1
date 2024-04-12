#requires -Module IISAdministration

[CmdletBinding()]
Param(
	[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
)
# retrieve IIS sites
Try {
	$IISSites = Get-IISSite
}
Catch {
	Throw $_
}

# process IIS Sites
ForEach ($IISSite in $IISSites) {
	# retrieve https IIS Site bindings
	$IISSiteBindings = $IISSite | Get-IISSiteBinding

	# process IIS Site Bindings
	:NextIISSiteBinding ForEach ($IISSiteBinding in $IISSiteBindings) {
		# if IIS Site binding protocol is not https...
		If ($IISSiteBinding.Protocol -ne 'https') {
			# continue to next IIS Site Binding
			Continue NextIISSiteBinding
		}

		# if IIS Site binding lacks a certificate hash...
		If ($null -eq $IISSiteBinding.CertificateHash) {
			# warn about missing certificate hash
			Write-Warning "could not find certificate hash for '$($IISSiteBinding.BindingInformation)' binding of '$($IISSite.Name)' site"
			# continue to next IIS Site Binding
			Continue NextIISSiteBinding
		}

		# convert CertificateHash byte array to Thumbprint string
		$Thumbprint = [System.BitConverter]::ToString([byte[]]($IISSiteBinding.CertificateHash)).Replace('-', $null)

		# retrieve certificate by thumbprint
		$Certificate = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Thumbprint -eq $Thumbprint }

		# if certificate not found...
		If ($null -eq $Certificate) {
			# warn about missing certificate hash then continue to next IIS Site Binding
			Write-Warning "could not find certificate by thumbprint: $Thumbprint"
			Continue NextIISSiteBinding
		}

		# get latest certificate with matching subject
		$LatestCertificate = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Subject -eq $Certificate.Subject } | Sort-Object -Property NotBefore | Select-Object -Last 1

		# if certificate is latest...
		If ($LatestCertificate.Thumbprint -eq $Certificate.Thumbprint) {
			# report then continue to next IIS Site Binding
			Write-Information "'$($IISSiteBinding.BindingInformation)' binding on '$($IISSite.Name)' site has latest certificate: $($Certificate.Thumbprint)"
			Continue NextIISSiteBinding
		}

		# remove IIS Site Binding
		Try {
			Remove-IISSiteBinding -Name $IISSite.Name -Protocol $IISSiteBinding.Protocol -BindingInformation $IISSiteBinding.BindingInformation -Confirm:$false
		}
		Catch {
			Write-Warning "could not remove '$($IISSiteBinding.BindingInformation)' binding from '$($IISSite.Name)' site: $($_.ToString())"
		}
		
		# remove IIS Site Binding
		Try {
			New-IISSiteBinding -Name $IISSite.Name -Protocol $IISSiteBinding.Protocol -BindingInformation $IISSiteBinding.BindingInformation -CertificateThumbprint $LatestCertificate.Thumbprint -CertStoreLocation $CertStoreLocation
		}
		Catch {
			Write-Warning "could not add '$($IISSiteBinding.BindingInformation)' binding to '$($IISSite.Name)' site: $($_.ToString())"
		}
	}
}