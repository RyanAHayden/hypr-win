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

# Hibernate on, and in Start's power menu (like hypr-mac's system menu, SUPER+Escape has Hibernate too).
& "$env:SystemRoot\System32\powercfg.exe" /hibernate on
if ($LASTEXITCODE) { throw "powercfg /hibernate on failed with exit code $LASTEXITCODE." }
$flyout = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
$null = New-Item -Path $flyout -Force
New-ItemProperty -LiteralPath $flyout -Name ShowHibernateOption -PropertyType DWord -Value 1 -Force | Out-Null
Write-Host 'Enabled Hibernate and its power-menu entry.'

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

Write-Host 'SSH remains managed by the sshd-user scheduled task; the sshd service is not enabled.'

# Keep the window manager, bar, launcher and helpers responsive under load, however they're started.
# CpuPriorityClass: 3 = high, 6 = above normal.
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in @{ 'glazewm.exe' = 3; 'AltSnap.exe' = 3; 'hyprwin.exe' = 3; 'PowerToys.KeyboardManagerEngine.exe' = 3; 'zebar.exe' = 6; 'Flow.Launcher.exe' = 6 }.GetEnumerator()) {
	$key = "$ifeo\$($exe.Key)\PerfOptions"
	if (-not (Test-Path $key)) { $null = New-Item $key -Force }
	Set-ItemProperty $key CpuPriorityClass $exe.Value -Type DWord
}
Write-Host 'Raised the CPU priority of GlazeWM, AltSnap, hyprwin, Keyboard Manager, Zebar and Flow Launcher.'

# A normal process's keyboard hook and keys don't reach elevated windows, so SUPER opened Start over them.
# `hyprwin.exe switcher` (started by GlazeWM) hands over to this elevated copy. It's built into Program Files, which only
# administrators can write to: an elevated task any process can start must not run a file any process can replace.
# Re-run this script after editing hyprwin.cs to update the elevated copy.
$elevatedDir = Join-Path $env:ProgramFiles 'hypr-win'
$elevatedHyprwin = Join-Path $elevatedDir 'hyprwin.exe'
$null = New-Item -ItemType Directory -Path $elevatedDir -Force
Remove-Item "$elevatedHyprwin.*old" -ErrorAction SilentlyContinue
if (Test-Path $elevatedHyprwin) { Move-Item $elevatedHyprwin "$elevatedHyprwin.$(Get-Random).old" -Force }
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize /target:winexe /r:System.Web.Extensions.dll `
	"/out:$elevatedHyprwin" (Join-Path $PSScriptRoot '.glzr\glazewm\hyprwin.cs')
if ($LASTEXITCODE) { throw 'Building the elevated hyprwin.exe failed.' }
$switcherSettings = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 1 `
	-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Ryha hyprwin switcher' `
	-Action (New-ScheduledTaskAction -Execute $elevatedHyprwin -Argument 'switcher') `
	-Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) `
	-Settings $switcherSettings -Description 'Runs the hyprwin switcher elevated so its keys also work over elevated windows.' -Force | Out-Null
Start-ScheduledTask -TaskName 'Ryha hyprwin switcher'
Write-Host "Registered and started task 'Ryha hyprwin switcher'."

# AltSnap runs elevated so it can drag admin windows. Like hyprwin, the elevated copy lives in Program Files, which only
# administrators can write to. AltSnap.ini next to AltSnap.exe puts it in portable mode, so it reads the repo's config.
# Re-run this script after editing AltSnap.ini or updating AltSnap.
$altSnapSource = "$env:APPDATA\AltSnap"
$altSnapDir = Join-Path $elevatedDir 'AltSnap'
if (Test-Path "$altSnapSource\AltSnap.exe") {
	Stop-ScheduledTask -TaskName 'Ryha AltSnap' -ErrorAction SilentlyContinue
	Get-Process AltSnap -ErrorAction SilentlyContinue | Stop-Process -Force
	Start-Sleep -Milliseconds 500
	robocopy $altSnapSource $altSnapDir /E /XF AltSnap.ini /NFL /NDL /NJH /NJS | Out-Null
	if ($LASTEXITCODE -ge 8) { throw 'Copying AltSnap to Program Files failed.' }
	Copy-Item (Join-Path $PSScriptRoot 'AltSnap.ini') "$altSnapDir\AltSnap.ini" -Force
}

# Run-key apps wait for Explorer's startup delay and start in no set order; logon tasks start right away.
# GlazeWM has uiAccess, so Task Scheduler can't start it directly; the task starts it through hyprwin.exe launch.
foreach ($app in @(
	@{ Name = 'GlazeWM'; Path = "$env:ProgramFiles\glzr.io\GlazeWM\glazewm.exe"; Launcher = $elevatedHyprwin },
	@{ Name = 'AltSnap'; Path = "$altSnapDir\AltSnap.exe"; Elevated = $true },
	@{ Name = 'PowerToys'; Path = "$env:LOCALAPPDATA\PowerToys\PowerToys.exe"; Elevated = $true }
)) {
	if (-not (Test-Path $app.Path)) { continue }
	$action = if ($app.Launcher) { New-ScheduledTaskAction -Execute $app.Launcher -Argument "launch `"$($app.Path)`"" }
	else { New-ScheduledTaskAction -Execute $app.Path }
	# Task priority 1 starts GlazeWM and AltSnap at high priority; PowerToys keeps normal priority.
	$priority = if ($app.Name -eq 'PowerToys') { 7 } else { 1 }
	$runLevel = if ($app.Elevated) { 'Highest' } else { 'Limited' }
	$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority $priority `
		-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
	$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
	if ($app.Name -eq 'GlazeWM') {
		$trigger.Delay = 'PT10S'
		$settings.RestartCount = 3
		$settings.RestartInterval = 'PT1M'
	}
	Register-ScheduledTask -TaskName "Ryha $($app.Name)" -Action $action `
		-Trigger $trigger `
		-Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel) `
		-Settings $settings -Description "Starts $($app.Name) at logon." -Force | Out-Null
	Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $app.Name -ErrorAction SilentlyContinue
	Write-Host "Registered logon task 'Ryha $($app.Name)'."
}

& (Join-Path $PSScriptRoot 'install-virtual-display.ps1')
