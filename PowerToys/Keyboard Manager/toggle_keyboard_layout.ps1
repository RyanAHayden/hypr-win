param(
    [ValidateSet('reload')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

# Remapping into admin windows requires an elevated engine, including after a reload.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    if ($Action) {
        $arguments += " -Action `"$Action`""
    }
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    } catch [System.ComponentModel.Win32Exception] {
        Write-Error "Keyboard Manager needs administrator permission to work in admin windows. Elevation failed: $($_.Exception.Message)"
        exit 1
    }
    exit $process.ExitCode
}

function Restart-KeyboardManager {
    # At logon this can run before PowerToys starts its own engine; restarting first would leave two engines running.
    if ($Action -eq 'reload' -and (Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue)) {
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Get-Process -Name 'PowerToys.KeyboardManagerEngine' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
    }
    $engines = @(Get-Process -Name 'PowerToys.KeyboardManagerEngine' -ErrorAction SilentlyContinue)
    $enginePath = $engines | ForEach-Object { $_.Path } | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $enginePath) {
        $enginePath = @(
            "$env:LOCALAPPDATA\PowerToys\KeyboardManagerEngine\PowerToys.KeyboardManagerEngine.exe",
            "$env:ProgramFiles\PowerToys\PowerToys.KeyboardManagerEngine.exe",
            "$env:ProgramFiles\PowerToys\KeyboardManagerEngine\PowerToys.KeyboardManagerEngine.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $enginePath) {
        throw 'PowerToys Keyboard Manager engine was not found. Install PowerToys before reloading the keyboard layout.'
    }
    foreach ($engine in $engines) {
        Stop-Process -Id $engine.Id -Force -ErrorAction SilentlyContinue
        $engine.WaitForExit(2000) | Out-Null
    }
    $process = Start-Process -FilePath $enginePath -PassThru
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        throw "PowerToys Keyboard Manager engine exited during startup (exit code $($process.ExitCode))."
    }
    # Every remapped key passes through the engine's hook; keep it ahead of busy apps.
    try { $process.PriorityClass = 'High' } catch {}
}

if ($Action -eq 'reload') {
    # Keyboard Manager must hook after GlazeWM, or GlazeWM sees keys before they are remapped.
    Restart-KeyboardManager
    exit 0
}

$kbmDir = "$env:LOCALAPPDATA\Microsoft\PowerToys\Keyboard Manager"
$defaultFile = Join-Path $kbmDir "default.json"
$layoutRemapped = Join-Path $kbmDir "layout_remapped.json"
$layoutDefault = Join-Path $kbmDir "layout_default.json"

if (-not (Test-Path $defaultFile)) {
    Write-Host "Keyboard Manager default.json not found at $defaultFile" -ForegroundColor Red
    exit 1
}

# Read current active default.json
$currentContent = Get-Content $defaultFile -Raw

# Determine whether current layout is remapped or default
# Laptop layout remaps Alt to Win, Win to Alt and Caps Lock to Ctrl.
$isRemapped = $false
try {
    $jsonObj = $currentContent | ConvertFrom-Json
    if ($jsonObj.remapKeys.inProcess -and $jsonObj.remapKeys.inProcess.Count -gt 0) {
        $isRemapped = $true
    }
} catch {
    if ($currentContent -match '"20"') {
        $isRemapped = $true
    }
}

$targetName = ""
if ($isRemapped) {
    if (Test-Path $layoutDefault) {
        Copy-Item $layoutDefault $defaultFile -Force
    } else {
        # Fallback if layout_default.json doesn't exist
        $fallback = '{"remapKeys":{"inProcess":[]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"18;9","exactMatch":true,"operationType":0,"newRemapKeys":"124"},{"originalKeys":"18;16;9","exactMatch":true,"operationType":0,"newRemapKeys":"125"},{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
            $fallback = '{"remapKeys":{"inProcess":[]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"18;9","exactMatch":true,"operationType":0,"newRemapKeys":"124"},{"originalKeys":"18;16;9","exactMatch":true,"operationType":0,"newRemapKeys":"125"},{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
        Set-Content -Path $defaultFile -Value $fallback -Encoding utf8
    }
    $targetName = "External Keyboard (Win=SUPER)"
} else {
    if (Test-Path $layoutRemapped) {
        Copy-Item $layoutRemapped $defaultFile -Force
    } else {
        # Fallback if layout_remapped.json doesn't exist
        $fallback = '{"remapKeys":{"inProcess":[{"originalKeys":"164","newRemapKeys":"91"},{"originalKeys":"20","newRemapKeys":"162"},{"originalKeys":"91","newRemapKeys":"164"}]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"18;9","exactMatch":true,"operationType":0,"newRemapKeys":"124"},{"originalKeys":"18;16;9","exactMatch":true,"operationType":0,"newRemapKeys":"125"},{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"},{"originalKeys":"162;72","exactMatch":false,"newRemapKeys":"37"},{"originalKeys":"162;74","exactMatch":false,"newRemapKeys":"40"},{"originalKeys":"162;75","exactMatch":false,"newRemapKeys":"38"},{"originalKeys":"162;76","exactMatch":false,"newRemapKeys":"39"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
            $fallback = '{"remapKeys":{"inProcess":[{"originalKeys":"164","newRemapKeys":"91"},{"originalKeys":"20","newRemapKeys":"162"},{"originalKeys":"91","newRemapKeys":"164"}]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"18;9","exactMatch":true,"operationType":0,"newRemapKeys":"124"},{"originalKeys":"18;16;9","exactMatch":true,"operationType":0,"newRemapKeys":"125"},{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"},{"originalKeys":"162;72","exactMatch":false,"newRemapKeys":"37"},{"originalKeys":"162;74","exactMatch":false,"newRemapKeys":"40"},{"originalKeys":"162;75","exactMatch":false,"newRemapKeys":"38"},{"originalKeys":"162;76","exactMatch":false,"newRemapKeys":"39"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
        Set-Content -Path $defaultFile -Value $fallback -Encoding utf8
    }
    $targetName = "Laptop (Alt=SUPER, Win=Alt, Caps=Ctrl, Ctrl+HJKL=Arrows)"
}

# Restart PowerToys KeyboardManagerEngine to reload configuration immediately
Restart-KeyboardManager

# Show notification / toast
try {
    Add-Type -AssemblyName System.Windows.Forms
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "PowerToys Keyboard Manager"
    $notify.BalloonTipText = "Switched to: $targetName"
    $notify.Visible = $true
    $notify.ShowBalloonTip(2000)
    Start-Sleep -Milliseconds 800
    $notify.Dispose()
} catch {}

Write-Host "Keyboard Manager switched to: $targetName" -ForegroundColor Green
