# Rebuilds hyprwin.exe after editing .glzr\glazewm\hyprwin.cs and restarts what runs it: the user copy (GlazeWM's
# binds, dwindle) and the elevated switcher copy in Program Files (one UAC prompt). Nothing is replaced if it doesn't
# compile. setup-windows.ps1 also builds both copies, along with everything else.
param([switch]$ElevatedPart)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '.glzr\glazewm\hyprwin.cs'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$elevatedHyprwin = Join-Path $env:ProgramFiles 'hypr-win\hyprwin.exe'
$switcherTask = 'Ryha hyprwin switcher'

function Build-Hyprwin([string]$Out) {
	# A running hyprwin.exe can't be overwritten, but it can be renamed out of the way.
	Remove-Item "$Out.*old" -ErrorAction SilentlyContinue
	if (Test-Path $Out) { Move-Item $Out "$Out.$(Get-Random).old" -Force }
	& $csc /nologo /optimize /target:winexe /r:System.Web.Extensions.dll "/out:$Out" $source
	if ($LASTEXITCODE) { throw "Building $Out failed." }
}

if ($ElevatedPart) {
	Build-Hyprwin $elevatedHyprwin
	# The new switcher replaces the running one.
	Start-ScheduledTask -TaskName $switcherTask
	return
}

$check = Join-Path $env:TEMP "hyprwin-check-$PID.exe"
& $csc /nologo /optimize /target:winexe /r:System.Web.Extensions.dll "/out:$check" $source
$failed = $LASTEXITCODE
Remove-Item $check -ErrorAction SilentlyContinue
if ($failed) { throw 'hyprwin.cs does not compile; nothing was replaced.' }

Build-Hyprwin "$env:USERPROFILE\.glzr\glazewm\hyprwin.exe"
Write-Host 'Built the user copy.'

$started = Get-Date
if ((Test-Path $elevatedHyprwin) -and (Get-ScheduledTask -TaskName $switcherTask -ErrorAction SilentlyContinue)) {
	$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if ($isAdministrator) { & $PSCommandPath -ElevatedPart }
	else {
		$elevated = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
			-ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ElevatedPart"
		if ($elevated.ExitCode -ne 0) { throw "Updating the elevated copy failed with exit code $($elevated.ExitCode)." }
	}
	Write-Host 'Built the elevated copy and restarted the switcher.'
} else {
	Write-Host 'No elevated switcher (run setup-elevated-windows.ps1 to add it): starting the user copy instead.'
	Start-Process "$env:USERPROFILE\.glzr\glazewm\hyprwin.exe" switcher
}
if (Get-Command glazewm -ErrorAction SilentlyContinue) {
	glazewm command shell-exec --hide-window '%USERPROFILE%\.glzr\glazewm\hyprwin.exe' dwindle 2>$null | Out-Null
}

# The switcher logs each start.
$log = Join-Path $env:LOCALAPPDATA 'hypr-win\hyprwin.log'
$deadline = (Get-Date).AddSeconds(10)
do {
	Start-Sleep -Milliseconds 250
	$up = (Test-Path $log) -and (Get-Content $log -Tail 20 | Where-Object {
		$_ -match '^(\S+ \S+) \[\d+\] switcher started' -and [datetime]$Matches[1] -ge $started.AddSeconds(-1)
	})
} while (-not $up -and (Get-Date) -lt $deadline)
if (-not $up) { throw "The switcher didn't start; see $log." }
Write-Host 'The switcher is running.'
