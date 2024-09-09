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

	# queue updates to IIS
	Try {
		Start-IISCommitDelay
	}
	Catch {
		Throw $_
	}
}

Process {
	# create list of hashtables
	$BindingsToUpdate = [System.Collections.Generic.List[hashtable]]::new()

	# retrieve certificates from store
	Try {
		$Certificates = Get-ChildItem -Path $CertStoreLocation
	}
	Catch {
		Return $_
	}

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

			# if IIS Site binding certificate hash is empty...
			If ([string]::IsNullOrEmpty($IISSiteBinding.Attributes['certificateHash'].Value)) {
				# report empty certificate hash
				Write-Warning -Message "could not find certificate hash for '$($IISSiteBinding.BindingInformation)' binding of '$($IISSite.Name)' site"
				# continue to next IIS Site Binding
				Continue NextIISSiteBinding
			}
			# if IIS Site binding certificate hash is not empty...
			Else {
				# retrieve thumbprint from 'certificateHash' attribute on IIS
				$Thumbprint = $IISSiteBinding.Attributes['certificateHash'].Value
			}

			# retrieve certificate by thumbprint
			$Certificate = $Certificates.Where({ $_.Thumbprint -eq $Thumbprint })

			# if certificate not found...
			If ($null -eq $Certificate) {
				# warn about missing certificate hash then continue to next IIS Site Binding
				Write-Warning -Message "could not find certificate by thumbprint: $Thumbprint"
				Continue NextIISSiteBinding
			}

			# get latest certificate with matching subject
			$LatestCertificate = $Certificates.Where({ $_.GetNameInfo('SimpleName', $false) -eq $Certificate.GetNameInfo('SimpleName', $false) }) | Sort-Object -Property 'NotBefore' | Select-Object -Last 1

			# if certificate is latest...
			If ($LatestCertificate.Thumbprint -eq $Certificate.Thumbprint) {
				# report then continue to next IIS Site Binding
				Write-Information -MessageData "found '$($IISSiteBinding.BindingInformation)' binding on '$($IISSite.Name)' site with latest certificate: $($Certificate.Thumbprint)"
				Continue NextIISSiteBinding
			}
			# if certificate is not latest...
			Else {
				# report before updating hashtable
				Write-Information -MessageData "found '$($IISSiteBinding.BindingInformation)' binding on '$($IISSite.Name)' site with old certificate: $($Certificate.Thumbprint)"
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
	:NextBinding ForEach ($BindingToUpdate in $BindingsToUpdate) {
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
			Write-Warning -Message "could not remove '$($BindingToUpdate.BindingInformation)' binding from '$($BindingToUpdate.Name)' site: $($_.ToString())"
			Continue :NextBinding
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
			Continue :NextBinding
		}

		# declare updated
		Write-Information "updated '$($BindingToUpdate.BindingInformation)' binding on '$($BindingToUpdate.Name)' site with new certificate: $($BindingToUpdate.CertificateThumbprint)"
	}
}

End {
	# commit updates to IIS
	Try {
		Stop-IISCommitDelay -Commit $true
	}
	Catch {
		Throw $_
	}

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
