[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# CertEnroll path on CA
	[Parameter(Position = 0)]
	$CertEnroll = 'C:\Windows\system32\CertSrv\CertEnroll',
	# destination path
	[Parameter(Position = 1)]
	$Destination = 'C:\Content\pki\certsrv',
	# header for certificate files
	[Parameter(DontShow)]
	[string]$Header = '-----BEGIN CERTIFICATE-----',
	# header for certificate files
	[Parameter(DontShow)]
	[string]$Footer = '-----END CERTIFICATE-----',
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.' -replace '\.$')
)

Begin {
	# if destination not found...
	If (![System.IO.Directory]::Exists($Destination)) {
		# create destination directory
		Try {
			$null = New-Item -Type Directory -Path $Destination -ErrorAction Stop
		}
		Catch {
			Write-Error -Message 'creating destination directory'
			Throw $_
		}
	}
}

Process {
	# if certificate services directory not found...
	If (![System.IO.Directory]::Exists($CertEnroll)) {
		# report and return
		Write-Warning -Message "could not locate certificate services directory: $CertEnroll"
		Return
	}

	# define dictionary for source files
	$SourceFileDictionary = [System.Collections.Generic.SortedDictionary[[System.String], [System.String]]]::new()

	####################
	# CRL files
	####################

	# retrieve CRL files
	$CrlFiles = Get-ChildItem -Path $CertEnroll | Where-Object { $_.Extension -eq '.crl' }

	# process CRL files
	ForEach ($CrlFile in $CrlFiles) {
		# add CRL file to dictionary
		$SourceFileDictionary.Add($CrlFile.Name, $CrlFile.FullName)
	}

	####################
	# CRT file
	####################

	# retrieve latest CRT file
	$CrtFile = Get-ChildItem -Path $CertEnroll | Where-Object { $_.Extension -eq '.crt' } | Sort-Object LastWriteTime | Select-Object -Last 1

	# define preferred CRT file name
	$CrtName = $CrtFile.Name -replace ('{0}_' -f $DnsHostName)

	# add CRT file to dictionary
	$SourceFileDictionary.Add($CrtName, $CrtFile.FullName)

	####################
	# CRT bytes
	####################

	# create certificate object from CRT file
	$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CrtFile.FullName)

	# create base64-encoded string of certificate data
	$Base64String = [System.Convert]::ToBase64String($Certificate.RawData, [Base64FormattingOptions]::None)

	####################
	# CER file
	####################

	# define temporary CER file
	$CerFile = New-TemporaryFile

	# define newline for CER file
	$CerLine = "`r`n"

	# define text for CER file
	$CerText = $Base64String -replace '.{64}', "`$&$CerLine"

	# define value of CER file
	$CerValue = '{0}{1}{2}{1}{3}' -f $Header, $CerLine, $CerText, $Footer

	# write value to CER file
	Set-Content -Path $CerFile -Value $CerValue

	# define preferred CER file name
	$CerName = $CrtName.Replace('.crt', '.cer')

	# add CER file to dictionary
	$SourceFileDictionary.Add($CerName, $CerFile.FullName)

	####################
	# PEM file
	####################

	# create temporary PEM file
	$PemFile = New-TemporaryFile

	# define newline for PEM file
	$PemLine = "`n"

	# define text for CER file
	$PemText = $Base64String -replace '.{64}', "`$&$PemLine"

	# define value of PEM file
	$PemValue = '{0}{1}{2}{1}{3}' -f $Header, $PemLine, $PemText, $Footer

	# write value to PEM file
	Set-Content -Path $PemFile -Value $PemValue

	# define preferred PEM file name
	$PemName = $CrtName.Replace('.crt', '.pem')

	# add PEM file to dictionary
	$SourceFileDictionary.Add($PemName, $PemFile.FullName)

	####################
	# process files
	####################

	# process each source file in dictionary
	:NextSourceFile ForEach ($SourceFile in $SourceFileDictionary.Keys) {
		# retrieve path from dictionary and report path
		$SourcePath = $SourceFileDictionary[$SourceFile]
		Write-Host "source file: $SourcePath"

		# define target path in destination and report path
		$TargetPath = Join-Path -Path $Destination -ChildPath $SourceFile
		Write-Host "target file: $TargetPath"

		# if target exists...
		If ([System.IO.File]::Exists($TargetPath)) {
			# retrieve source hash
			$SourceHash = Get-FileHash -Path $SourcePath -Algorithm SHA512

			# retrieve target hash
			$TargetHash = Get-FileHash -Path $TargetPath -Algorithm SHA512

			# if source and target hashes match...
			If ($SourceHash.Hash -eq $TargetHash.Hash) {
				# report and continue to next CRL file
				Write-Host "found expected '$SourceFile' file in destination folder: $TargetPath"
				Continue NextSourceFile
			}
		}

		# copy file
		Try {
			Copy-Item -Path $SourcePath -Destination $TargetPath
		}
		Catch {
			Write-Warning -Message "could not copy '$SourceFile' file (path: $SourcePath) file to destination (path: $TargetPath): $($_.Exception.Message)"
			Continue NextSourceFile
		}

		# report state
		Write-Host "copied current '$SourceFile' file to destination folder: $TargetPath"
	}

	####################
	# remove files
	####################

	# remove temporary CER file
	Try {
		Remove-Item -Path $CerFile.FullName
	}
	Catch {
		Write-Warning -Message "could not remove '$($CerFile.FullName)' temporary CER file: $($_.Exception.Message)"
	}

	# remove temporary PEM file
	Try {
		Remove-Item -Path $PemFile.FullName
	}
	Catch {
		Write-Warning -Message "could not remove '$($PemFile.FullName)' temporary PEM file: $($_.Exception.Message)"
	}
}
