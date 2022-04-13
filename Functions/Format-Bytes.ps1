Function Format-Bytes {
	Param (
		[Parameter(Position = 0,Mandatory = $true)]
		[uint64]$Size,
		[Parameter(Position = 1)]
		[byte]$RoundTo = 2
	)
	Switch ($Size) {
		{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; Break }
		{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; Break }
		{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; Break }
		{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; Break }
		{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; Break }
		Default { "$([math]::Round($Size,$RoundTo)) B" }
	}
}
