#Requires -Modules ActiveDirectory, CertFunctions

[CmdletBinding()]
Param(
	[Parameter(Position = 0)]
	[string]$ComputerName,
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name

)

# if computer name provided...
If ($PSBoundParameters.ContainsKey($ComputerName)) {
	# retrieve computer by name
	$Filter = "SamAccountName -eq '$ComputerName$'"
}
Else {
	# retrieve all computers with values in specified properties
	$Filter = "userCertificate -like '*' -or altSecurityIdentities -like '*'"
}

# retrieve computers with usercertificate
Try {
	$Computers = Get-ADComputer -Server $Server -Filter $Filter -Properties 'altSecurityIdentities', 'userCertificate'
}
Catch {
	Return $_
}

# process each computer
ForEach ($Computer in $Computers) {
	# create list for certificate objects
	$Certificates = [System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]]::new()

	# populate certificates list
	ForEach ($UserCertificate in $Computer.UserCertificate) {
		# create certificate from computer attribute
		Try {
			$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($UserCertificate)
		}
		Catch {
			Write-Warning -Message "$($Computer.SamAccountName), could not create certificate from value in userCertificate attribute: $($_.Exception.Message)"
			Return $_
		}

		# add certificate to list
		Try {
			$Certificates.Add($Certificate)
		}
		Catch {
			Write-Warning -Message "$($Computer.SamAccountName), could not add '$($Certificate.Thumbprint)' certificate to list: $($_.Exception.Message)"
			Return $_
		}
	}

	# create list for missing alt security identities
	$MissingAltSecurityIdentities = [System.Collections.Generic.List[System.String]]::new()

	# define missing alternate security identities from certificates
	:NextCertificate ForEach ($Certificate in $Certificates) {
		# create alternate security identity from certificate
		Try {
			$AltSecurityIdentity = Get-CertificateAltSecurityIdentity -Certificate $Certificate
		}
		Catch {
			Write-Warning -Message "$($Computer.SamAccountName), could not create alt security identity from '$($Certificate.Thumbprint)' certificate: $($_.Exception.Message)"
			Return $_
		}

		# if alternate security identity already set...
		If ($Computer.altSecurityIdentities -notcontains $AltSecurityIdentity) {
			# continue to next certificate
			$MissingAltSecurityIdentities.Add($AltSecurityIdentity)
		}
	}

	# create list for revoked alternate security identities
	$RevokedAltSecurityIdentities = [System.Collections.Generic.List[System.String]]::new()

	# define revoked alternate security identities from certificates
	:NextAltSecurityIdentity ForEach ($AltSecurityIdentity in $Computer.altSecurityIdentities) {
		# if alternate security identity format matches...
		switch -regex ($AltSecurityIdentity) {
			# IssuerAndSerialNumber
			'^X509:<I>(?<ReversedIssuer>.+)<SR>(?<ReversedSerialNumber>[0-9a-fA-F]+)$' {
				# un-reverse the reversed issuer
				$Issuer = Format-ReversedDistinguishedName -DistinguishedName $Matches['ReversedIssuer']
	
				# un-reverse the reversed serial number respecting byte boundaries
				$SerialNumber = Format-ReversedString -String $Matches['ReversedSerialNumber'] -Count 2

				# if certificate exists with matching issuer and serial number...
				If ($Certificates.Where({ $_.Issuer -eq $Issuer -and $_.SerialNumber -eq $SerialNumber })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# SKI
			'^X509:<SKI>(?<SubjectKeyIdentifier>[0-9a-fA-F]+)$' {
				# if certificate exists with matching subject key identifier...
				If ($Certificates.Where({ $_.Extensions.SubjectKeyIdentifier -eq $Matches['SubjectKeyIdentifier'] })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# SHA1PublicKey
			'^X509:<SHA1-PUKEY>(?<Thumbprint>[0-9a-fA-F]*)$' {
				# if certificate exists with matching thumbprint...
				If ($Certificates.Where({ $_.Thumbprint -eq $Matches['Thumbprint'] })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# IssuerAndSubject
			'^X509:<I>(?<ReversedIssuer>.+)<S>(?<ReversedSubject>.+)$' {
				# un-reverse the reversed issuer
				$Issuer = Format-ReversedDistinguishedName -DistinguishedName $Matches['ReversedIssuer']
	
				# un-reverse the reversed subject
				$Subject = Format-ReversedDistinguishedName -DistinguishedName $Matches['ReversedSubject']

				# if certificate exists with matching issuer and subject...
				If ($Certificates.Where({ $_.Issuer -eq $Issuer -and $_.Subject -eq $Subject })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# SubjectOnly
			'^X509:<S>(?<ReversedSubject>.+)$' {
				# un-reverse the reversed subject
				$Subject = Format-ReversedDistinguishedName -DistinguishedName $Matches['ReversedSubject']

				# if certificate exists with matching subject...
				If ($Certificates.Where({ $_.Subject -eq $Subject })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# RFC822
			'^X509:<RFC822>(?<RFC822Name>.+)$' {
				# if certificate exists with matching user principal name...
				If ($Certificates.Where({ $_.Extensions.UserPrincipalName -eq $Matches['RFC822Name'] })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# PN
			'^X509:<PN>(?<UserPrincipalName>.+)$' {
				# if certificate exists with matching user principal name...
				If ($Certificates.Where({ $_.Extensions.UserPrincipalName -eq $Matches['UserPrincipalName'] })) {
					# continiue to next alt security identity
					Continue NextAltSecurityIdentity
				}
			}
			# Kerberos
			'^Kerberos:.+' {
				# continiue to next alt security identity
				Continue NextAltSecurityIdentity
			}
		}
		# add alt security identity to revoked identities
		$RevokedAltSecurityIdentities.Add($AltSecurityIdentity)
	}

	# process missing identities
	ForEach ($MissingAltSecurityIdentity in $MissingAltSecurityIdentities) {
		# update computer object
		Try {
			Set-ADComputer -Server $Server -Identity $Computer -Add @{ altSecurityIdentities = $MissingAltSecurityIdentity } -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "$($Computer.SamAccountName), could not add '$MissingAltSecurityIdentity' to altSecurityIdentities: $($_.Exception.Message)"
			Return $_
		}
	}

	# process revoked identities
	ForEach ($RevokedAltSecurityIdentity in $RevokedAltSecurityIdentities) {
		# update computer object
		Try {
			Set-ADComputer -Server $Server -Identity $Computer -Remove @{ altSecurityIdentities = $RevokedAltSecurityIdentity } -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "$($Computer.SamAccountName), could not remove '$RevokedAltSecurityIdentity' from altSecurityIdentities: $($_.Exception.Message)"
			Return $_
		}
	}
}
