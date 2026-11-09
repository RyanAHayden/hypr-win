$ErrorActionPreference = 'Stop'

$defaultShell = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $defaultShell)) {
	throw "PowerShell 7 was not found at the OpenSSH default-shell path: $defaultShell"
}
if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\OpenSSH')) {
	$null = New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force
}
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
	-Value "C:\Program Files\PowerShell\7\pwsh.exe" -PropertyType String -Force | Out-Null

$source = Join-Path $PSScriptRoot '.glzr\glazewm\sshd_window_hider.py'
if (-not (Test-Path -LiteralPath $source)) {
	throw "SSHD window hider script not found: $source"
}

$python = Get-Command python.exe -ErrorAction Stop
$runtimePath = & $python.Source -c 'import sys; print(sys.executable)'
if ($LASTEXITCODE -ne 0 -or -not $runtimePath) {
	throw 'Could not resolve the installed Python executable.'
}
$pythonwPath = Join-Path (Split-Path -Parent $runtimePath.Trim()) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonwPath)) {
	throw "pythonw.exe was not found next to the installed Python: $pythonwPath"
}

$installDirectory = Join-Path $env:LOCALAPPDATA 'ryha-config\sshd-window-hider'
$installedScript = Join-Path $installDirectory 'sshd_window_hider.py'
$null = New-Item -ItemType Directory -Path $installDirectory -Force
Copy-Item -LiteralPath $source -Destination $installedScript -Force

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskName = 'Ryha SSHD Window Hider'
$action = New-ScheduledTaskAction -Execute $pythonwPath `
	-Argument ('"{0}"' -f $installedScript) `
	-WorkingDirectory $installDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
	-ExecutionTimeLimit ([TimeSpan]::Zero) `
	-RestartCount 3 `
	-RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
	-Principal $principal -Settings $settings `
	-Description 'Hides windows owned by sshd.exe and its child processes.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$deadline = (Get-Date).AddSeconds(10)
do {
	Start-Sleep -Milliseconds 250
	$task = Get-ScheduledTask -TaskName $taskName
} while ($task.State -ne 'Running' -and (Get-Date) -lt $deadline)
if ($task.State -ne 'Running') {
	$info = Get-ScheduledTaskInfo -TaskName $taskName
	throw "Scheduled task '$taskName' did not start (state: $($task.State), result: $($info.LastTaskResult))."
}
Write-Host "Registered and started elevated task '$taskName'."
