$ErrorActionPreference = 'Stop'

# Keep OpenSSH's DefaultShell on the installed PowerShell 7. A SYSTEM task re-syncs it at boot
# and hourly because the Microsoft Store pwsh path changes with every update.
$syncSource = Join-Path $PSScriptRoot 'sync-openssh-shell.ps1'
$syncDirectory = Join-Path $env:ProgramData 'ryha-config'
$syncScript = Join-Path $syncDirectory 'sync-openssh-shell.ps1'
$null = New-Item -ItemType Directory -Path $syncDirectory -Force
Copy-Item -LiteralPath $syncSource -Destination $syncScript -Force
& $syncScript

$syncTaskName = 'Ryha OpenSSH Shell Sync'
$syncAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
	-Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $syncScript)
$syncTriggers = @(
	New-ScheduledTaskTrigger -AtStartup
	New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1)
)
$syncPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$syncSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
	-ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $syncTaskName -Action $syncAction -Trigger $syncTriggers `
	-Principal $syncPrincipal -Settings $syncSettings `
	-Description 'Points the OpenSSH DefaultShell at the current PowerShell 7 install.' -Force | Out-Null
Write-Host "Registered task '$syncTaskName'."

$python = Get-Command python.exe -ErrorAction Stop
$runtimePath = & $python.Source -c 'import sys; print(sys.executable)'
if ($LASTEXITCODE -ne 0 -or -not $runtimePath) {
	throw 'Could not resolve the installed Python executable.'
}
$pythonwPath = Join-Path (Split-Path -Parent $runtimePath.Trim()) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonwPath)) {
	throw "pythonw.exe was not found next to the installed Python: $pythonwPath"
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

function Register-ElevatedPythonTask {
	param(
		[string]$TaskName,
		[string]$Source,
		[string]$InstallName,
		[string]$Description
	)

	if (-not (Test-Path -LiteralPath $Source)) {
		throw "Script for '$TaskName' not found: $Source"
	}
	$installDirectory = Join-Path $env:LOCALAPPDATA "ryha-config\$InstallName"
	$installedScript = Join-Path $installDirectory (Split-Path -Leaf $Source)
	$null = New-Item -ItemType Directory -Path $installDirectory -Force

	# Stop the old instance first so the script copy is not in use and the new copy runs.
	if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
		Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
	}
	Copy-Item -LiteralPath $Source -Destination $installedScript -Force

	$action = New-ScheduledTaskAction -Execute $pythonwPath `
		-Argument ('"{0}"' -f $installedScript) `
		-WorkingDirectory $installDirectory
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
	$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
	$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
		-ExecutionTimeLimit ([TimeSpan]::Zero) `
		-RestartCount 3 `
		-RestartInterval (New-TimeSpan -Minutes 1)

	Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
		-Principal $principal -Settings $settings `
		-Description $Description -Force | Out-Null
	Start-ScheduledTask -TaskName $TaskName

	$deadline = (Get-Date).AddSeconds(10)
	do {
		Start-Sleep -Milliseconds 250
		$task = Get-ScheduledTask -TaskName $TaskName
	} while ($task.State -ne 'Running' -and (Get-Date) -lt $deadline)
	if ($task.State -ne 'Running') {
		$info = Get-ScheduledTaskInfo -TaskName $TaskName
		throw "Scheduled task '$TaskName' did not start (state: $($task.State), result: $($info.LastTaskResult))."
	}
	Write-Host "Registered and started elevated task '$TaskName'."
}

Register-ElevatedPythonTask -TaskName 'Ryha SSHD Window Hider' `
	-Source (Join-Path $PSScriptRoot '.glzr\glazewm\sshd_window_hider.py') `
	-InstallName 'sshd-window-hider' `
	-Description 'Hides windows owned by sshd.exe and its child processes.'

Register-ElevatedPythonTask -TaskName 'Ryha Ctrl Caps Lock' `
	-Source (Join-Path $PSScriptRoot 'PowerToys\Keyboard Manager\ctrl_caps_lock.py') `
	-InstallName 'ctrl-caps-lock' `
	-Description 'Makes physical Ctrl+Caps Lock toggle Caps Lock while Keyboard Manager maps Caps Lock to Ctrl.'

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

& (Join-Path $PSScriptRoot 'install-virtual-display.ps1')
