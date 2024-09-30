Function Get-TimeSpanAsFormattedString {
	Param(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[timespan]$TimeSpan
	)

	# create list
	$StringList = [System.Collections.Generic.List[System.String]]::new()

	# if Days is not zero...
	If ($TimeSpan.Days) {
		# if Days is one or negative one...
		If ($TimeSpan.Days -eq 1 -or $TimeSpan.Days -eq -1) {
			$StringList.Add('{0} day' -f $TimeSpan.Days)
		}
		# if Days is not one or negative one...
		Else {
			$StringList.Add('{0} days' -f $TimeSpan.Days)
		}
	}

	# if Hours is not zero...
	If ($TimeSpan.Hours) {
		# if Hours is one or negative one...
		If ($TimeSpan.Hours -eq 1 -or $TimeSpan.Hours -eq -1) {
			$StringList.Add('{0} hour' -f $TimeSpan.Hours)
		}
		# if Hours is not one or negative one...
		Else {
			$StringList.Add('{0} hours' -f $TimeSpan.Hours)
		}
	}

	# if Minutes is not zero...
	If ($TimeSpan.Minutes) {
		# if Minutes is one or negative one...
		If ($TimeSpan.Minutes -eq 1 -or $TimeSpan.Minutes -eq -1) {
			$StringList.Add('{0} minute' -f $TimeSpan.Minutes)
		}
		# if Minutes is not one or negative one...
		Else {
			$StringList.Add('{0} minutes' -f $TimeSpan.Minutes)
		}
	}

	# if Seconds is not zero...
	If ($TimeSpan.Seconds) {
		# if Seconds is one or negative one...
		If ($TimeSpan.Seconds -eq 1 -or $TimeSpan.Seconds -eq -1) {
			$StringList.Add('{0} second' -f $TimeSpan.Seconds)
		}
		# if Seconds is not one or negative one...
		Else {
			$StringList.Add('{0} seconds' -f $TimeSpan.Seconds)
		}
	}

	# if Milliseconds is not zero...
	If ($TimeSpan.Milliseconds) {
		# if Milliseconds is one or negative one...
		If ($TimeSpan.Milliseconds -eq 1 -or $TimeSpan.Milliseconds -eq -1) {
			$StringList.Add('{0} millisecond' -f $TimeSpan.Milliseconds)
		}
		# if Milliseconds is not one or negative one...
		Else {
			$StringList.Add('{0} milliseconds' -f $TimeSpan.Milliseconds)
		}
	}

	# join strings together
	$String = $StringList -join ', '

	# format string
	switch ($StringList.Count) {
		1 { 
			Return $String
		}
		2 { 
			Return $String.Replace(', ', ' and ')
		}
		Default {
			Return $String.Insert($String.LastIndexOf(',')+1, ' and')
		}
	}
}
