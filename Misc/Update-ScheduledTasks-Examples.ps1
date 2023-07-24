$Json = 'C:\Content\local\tasks.json'

$UpdateScheduledTasks = @{
	Add                = $true
	TaskName           = 'ALEX-Import-CertificateFromPath'
	Taskpath           = 'Alex'
	Execute            = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
	Argument           = '-NoProfile -File "C:\Content\local\scripts\Import-CertificateFromPath.ps1" -Import'
	TriggerAt          = [datetime]'00:00:00'
	RandomDelay        = (New-TimeSpan -Minutes 5)
	RepetitionInterval = (New-TimeSpan -Hours 1)
	ExecutionTimeLimit = (New-TimeSpan -Minutes 15)
}

.\Update-ScheduledTasks.ps1 -Json $Json @UpdateScheduledTasks -Json $Json 
