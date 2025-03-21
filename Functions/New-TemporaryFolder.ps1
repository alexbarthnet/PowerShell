Function New-TemporaryFolder {
	Param(
		[switch]$ForMachine
	)

	# if temporary folder for machine requested...
	If ($ForMachine) {
		# retrieve TEMP environment variable for machine
		$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
	}
	Else {
		# retrieve TEMP environment variable for user
		$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'User')
	}

	# clear 

	# define path for temporary folder
	Do {
		# define temporary folder name
		$NameForTemporaryFolder = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
		# combine TEMP path and temporary folder name
		$PathForTemporaryFolder = Join-Path -Path $PathForTEMP -ChildPath $NameForTemporaryFolder
	}
	Until ([System.IO.Directory]::Exists($PathForTemporaryFolder))

	# create temporary folder
	Try {
		$TemporaryFolder = New-Item -Force -ItemType Directory -Path $PathForTemporaryFolder
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# return temporary folder
	Return $TemporaryFolder
}
