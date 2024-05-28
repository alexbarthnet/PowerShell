#requires -Module IISAdministration, TranscriptWithHostAndDate

[CmdletBinding()]
Param(
	[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
)

Begin {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# create list of hashtables
	$BindingsToUpdate = [System.Collections.Generic.List[hashtable]]::new()

	# retrieve IIS sites
	Try {
		$IISSites = Get-IISSite
	}
	Catch {
		Return $_
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
			# if certificate is not latest...
			Else {
				# report
				Write-Information "'$($IISSiteBinding.BindingInformation)' binding on '$($IISSite.Name)' site had old certificate: $($Certificate.Thumbprint)"
			}

			# create hashtable with values for binding to update
			$BindingToUpdate = @{
				Name                  = $IISSite.Name
				Protocol              = $IISSiteBinding.Protocol
				BindingInformation    = $IISSiteBinding.BindingInformation
				CertificateThumbprint = $LatestCertificate.Thumbprint
				CertStoreLocation     = $CertStoreLocation
			}

			# add hashtable to list
			$BindingsToUpdate.Add($BindingToUpdate)
		}
	}

	# process bindings to update
	ForEach ($BindingToUpdate in $BindingsToUpdate) {
		# define parameters for Remove-IISSiteBinding
		$RemoveIISSiteBinding = @{
			Name               = $BindingToUpdate.Name
			Protocol           = $BindingToUpdate.Protocol
			BindingInformation = $BindingToUpdate.BindingInformation
			Confirm            = $false
		}

		# remove IIS Site Binding
		Try {
			Remove-IISSiteBinding @RemoveIISSiteBinding
		}
		Catch {
			Write-Warning "could not remove '$($BindingToUpdate.BindingInformation)' binding from '$($BindingToUpdate.Name)' site: $($_.ToString())"
		}

		# define parameters for New-IISSiteBinding
		$NewIISSiteBinding = @{
			Name                  = $BindingToUpdate.Name
			Protocol              = $BindingToUpdate.Protocol
			BindingInformation    = $BindingToUpdate.BindingInformation
			CertificateThumbprint = $BindingToUpdate.CertificateThumbprint
			CertStoreLocation     = $BindingToUpdate.CertStoreLocation
		}


		# restore IIS Site Binding
		Try {
			New-IISSiteBinding @NewIISSiteBinding
		}
		Catch {
			Write-Warning "could not add '$($BindingToUpdate.BindingInformation)' binding to '$($BindingToUpdate.Name)' site: $($_.ToString())"
		}

		# declare updated
		Write-Information "'$($BindingToUpdate.BindingInformation)' binding on '$($BindingToUpdate.Name)' site has new certificate: $($BindingToUpdate.CertificateThumbprint)"
	}
}

End {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
