# Windows settings for this config. Run after installs.bat; safe to re-run.

function Set-Reg($Path, $Name, $Value, $Type = 'DWord') {
	if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
	Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
}

$explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

Write-Host 'Disabling Narrator and its shortcut...'
Set-Reg 'HKCU:\Software\Microsoft\Narrator\NoRoam' WinEnterLaunchEnabled 0
Set-Reg 'HKCU:\Software\Microsoft\Narrator\NoRoam' RunningState 0
Set-Reg 'HKCU:\Software\Microsoft\Narrator' NarratorCursorHighlight 0

Write-Host 'Disabling Sticky/Filter/Toggle Keys shortcuts...'
Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' Flags '506' String
Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' Flags '122' String
Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' Flags '58' String

Write-Host 'Freeing SUPER+S from Windows Search (GlazeWM scratchpad)...'
Set-Reg "$explorer\Advanced" DisabledHotkeys 'S' String

Write-Host 'Turning off Snap, window arrangement and animations (GlazeWM tiles instead)...'
Set-Reg "$explorer\Advanced" SnapAssist 0
Set-Reg "$explorer\Advanced" EnableSnapAssistFlyout 0
Set-Reg 'HKCU:\Control Panel\Desktop' WindowArrangementActive '0' String
Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate '0' String
Set-Reg "$explorer\Advanced" TaskbarAnimations 0
Set-Reg "$explorer\VisualEffects" VisualFXSetting 3

Write-Host 'Setting taskbar auto-hide, dark mode and no transparency...'
$stuckRects = "$explorer\StuckRects3"
if (Test-Path $stuckRects) {
	$settings = (Get-ItemProperty $stuckRects).Settings
	$settings[8] = 3
	Set-ItemProperty $stuckRects Settings $settings
}
Set-Reg "$explorer\Advanced" TaskbarAl 0
Set-Reg "$explorer\Advanced" ShowTaskViewButton 0
Set-Reg "$explorer\Advanced" MMTaskbarMode 2
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' SearchboxTaskbarMode 0
Set-Reg $personalize AppsUseLightTheme 0
Set-Reg $personalize SystemUsesLightTheme 0
Set-Reg $personalize EnableTransparency 0

Write-Host 'Showing file extensions and hidden files...'
Set-Reg "$explorer\Advanced" HideFileExt 0
Set-Reg "$explorer\Advanced" Hidden 1

Write-Host 'Starting Flow Launcher right at logon, at raised priority...'
# GlazeWM's and AltSnap's logon tasks need admin rights, so setup-elevated-windows.ps1 registers them. its own logon task (it rewrites it on updates); drop its delay and raise its priority.
$flowTask = Get-ScheduledTask 'Flow.Launcher Startup' -ErrorAction SilentlyContinue
if ($flowTask) {
	$flowTask.Triggers[0].Delay = 'PT0S'
	$flowTask.Settings.Priority = 2
	Set-ScheduledTask -InputObject $flowTask | Out-Null
}

Write-Host 'Enabling Developer Mode (needed for Dotter symlinks)...'
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
if ((Get-ItemProperty $devKey -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -ne 1) {
	Start-Process reg.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList 'add', 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock', '/v', 'AllowDevelopmentWithoutDevLicense', '/t', 'REG_DWORD', '/d', '1', '/f'
}

Write-Host 'Configuring the OpenSSH shell (preserving sshd-user, not enabling the service) and registering elevated SSHD window hider and Ctrl+Caps Lock tasks...'
$elevatedSetup = Join-Path $PSScriptRoot 'setup-elevated-windows.ps1'
$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdministrator) {
	& $elevatedSetup
} else {
	$elevated = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
		-ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedSetup`""
	if ($elevated.ExitCode -ne 0) {
		throw "Elevated setup failed with exit code $($elevated.ExitCode)."
	}
}

Write-Host 'Building hyprwin.exe (GlazeWM window switcher/cycle/quit/kill/scratchpad/unminimize helper)...'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$glazewmDir = "$env:USERPROFILE\.glzr\glazewm"
$hyprwin = "$glazewmDir\hyprwin.exe"
New-Item -ItemType Directory -Force $glazewmDir | Out-Null
# A running hyprwin.exe (the switcher, dwindle) can't be overwritten, but it can be renamed out of the way.
Remove-Item "$hyprwin.*old" -ErrorAction SilentlyContinue
if (Test-Path $hyprwin) { Move-Item $hyprwin "$hyprwin.$(Get-Random).old" -Force -ErrorAction SilentlyContinue }
& $csc /nologo /optimize /target:winexe /r:System.Web.Extensions.dll "/out:$hyprwin" "$PSScriptRoot\.glzr\glazewm\hyprwin.cs"
if ($LASTEXITCODE) {
	Write-Host '  Build failed; the SUPER+Tab switcher, Alt+Tab cycle, SUPER+Q and scratchpad binds need it.'
} elseif (Get-Command glazewm -ErrorAction SilentlyContinue) {
	# Restart the switcher and dwindle through GlazeWM so they run elevated like GlazeWM (the new ones replace the old).
	glazewm command shell-exec --hide-window '%USERPROFILE%\.glzr\glazewm\hyprwin.exe' switcher 2>$null | Out-Null
	glazewm command shell-exec --hide-window '%USERPROFILE%\.glzr\glazewm\hyprwin.exe' dwindle 2>$null | Out-Null
}

Write-Host 'Setting up Greenshot for SUPER+Shift+S (hyprwin sends F22; Windows reserves Win+Shift+S, F23/F24 are often taken)...'
$greenshot = "$env:ProgramFiles\Greenshot\Greenshot.exe"
if (Test-Path $greenshot) {
	# Greenshot rewrites Greenshot.ini when it exits normally, so kill it before editing.
	Stop-Process -Name Greenshot -Force -ErrorAction SilentlyContinue
	$greenshotDir = "$env:APPDATA\Greenshot"
	New-Item -ItemType Directory -Force $greenshotDir | Out-Null
	Set-Content "$greenshotDir\Greenshot-defaults.ini" "[Core]`r`nLanguage=en-US`r`nIsFirstLaunch=false`r`nRegionHotkey=F22`r`nDestinations=Clipboard"
	$greenshotIni = "$greenshotDir\Greenshot.ini"
	if (Test-Path $greenshotIni) {
		(Get-Content $greenshotIni) -replace '^RegionHotkey=.*', 'RegionHotkey=F22' -replace '^Destinations=.*', 'Destinations=Clipboard' | Set-Content $greenshotIni
	}
	Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' Greenshot "`"$greenshot`"" String
	Start-Process $greenshot
} else {
	Write-Host '  Greenshot not installed (installs.bat); SUPER+Shift+S does nothing until it is.'
}

Write-Host 'Installing websockets for the GlazeWM focus lock (Python 3.12)...'
if (Get-Command py -ErrorAction SilentlyContinue) {
	py -3.12 -m pip install --user --quiet websockets
} else {
	Write-Host '  Python launcher not found; run installs.bat, open a new terminal and re-run setup.'
}

Write-Host 'Installing PSFzf for PowerShell 7...'
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) {
	& $pwsh.Source -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSFzf)) { Install-Module PSFzf -Scope CurrentUser -Force }'
} else {
	Write-Host '  PowerShell 7 not found; re-run setup after installing it.'
}

Write-Host 'Setting Windows Terminal as the default terminal app...'
Set-Reg 'HKCU:\Console\%%Startup' DelegationConsole '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' String
Set-Reg 'HKCU:\Console\%%Startup' DelegationTerminal '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' String

Write-Host 'Setting PowerShell 7 as the Windows Terminal default...'
$wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $wtSettings) {
	$text = Get-Content $wtSettings -Raw
	$guid = ([regex]::Match($text, '"guid":\s*"(\{[^"]+\})"[^{}]*"source":\s*"Windows\.Terminal\.PowershellCore"')).Groups[1].Value
	if (-not $guid) { $guid = ([regex]::Match($text, '"source":\s*"Windows\.Terminal\.PowershellCore"[^{}]*"guid":\s*"(\{[^"]+\})"')).Groups[1].Value }
	if ($guid) {
		[IO.File]::WriteAllText($wtSettings, ($text -replace '("defaultProfile":\s*")\{[^"]+\}"', "`${1}$guid`""))
	} else {
		Write-Host '  PowerShell 7 profile not in Windows Terminal yet; open Terminal once and re-run setup.'
	}
} else {
	Write-Host '  Windows Terminal settings not found; open Terminal once and re-run setup.'
}

Write-Host 'Done. Sign out and back in for taskbar, animation and accessibility changes to take full effect.'
