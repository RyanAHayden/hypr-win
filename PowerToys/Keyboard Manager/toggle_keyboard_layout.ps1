param(
    [string]$Action
)

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
# Laptop layout remaps Alt to Win and Caps Lock/Win to Ctrl.
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
        $fallback = '{"remapKeys":{"inProcess":[]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
            $fallback = '{"remapKeys":{"inProcess":[]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"91;32","exactMatch":true,"operationType":0,"newRemapKeys":"164;32"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
        Set-Content -Path $defaultFile -Value $fallback -Encoding utf8
    }
    $targetName = "External Keyboard (Win=SUPER)"
} else {
    if (Test-Path $layoutRemapped) {
        Copy-Item $layoutRemapped $defaultFile -Force
    } else {
        # Fallback if layout_remapped.json doesn't exist
        $fallback = '{"remapKeys":{"inProcess":[{"originalKeys":"164","newRemapKeys":"91"},{"originalKeys":"20","newRemapKeys":"162"},{"originalKeys":"91","newRemapKeys":"162"}]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"162;72","exactMatch":false,"newRemapKeys":"37"},{"originalKeys":"162;74","exactMatch":false,"newRemapKeys":"40"},{"originalKeys":"162;75","exactMatch":false,"newRemapKeys":"38"},{"originalKeys":"162;76","exactMatch":false,"newRemapKeys":"39"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
            $fallback = '{"remapKeys":{"inProcess":[{"originalKeys":"164","newRemapKeys":"91"},{"originalKeys":"20","newRemapKeys":"162"},{"originalKeys":"91","newRemapKeys":"162"}]},"remapKeysToText":{"inProcess":[]},"remapShortcuts":{"global":[{"originalKeys":"162;72","exactMatch":false,"newRemapKeys":"37"},{"originalKeys":"162;74","exactMatch":false,"newRemapKeys":"40"},{"originalKeys":"162;75","exactMatch":false,"newRemapKeys":"38"},{"originalKeys":"162;76","exactMatch":false,"newRemapKeys":"39"}],"appSpecific":[]},"remapShortcutsToText":{"global":[],"appSpecific":[]}}'
        Set-Content -Path $defaultFile -Value $fallback -Encoding utf8
    }
    $targetName = "Laptop (Alt=SUPER, Caps/Win=Ctrl, Ctrl+HJKL=Arrows)"
}

# Restart PowerToys KeyboardManagerEngine to reload configuration immediately
$kbmProc = Get-Process -Name "PowerToys.KeyboardManagerEngine" -ErrorAction SilentlyContinue
$kbmPath = ""
if ($kbmProc) {
    $kbmPath = $kbmProc.Path
    Stop-Process -Id $kbmProc.Id -Force
}

if (-not $kbmPath -or -not (Test-Path $kbmPath)) {
    $candidates = @(
        "$env:LOCALAPPDATA\PowerToys\KeyboardManagerEngine\PowerToys.KeyboardManagerEngine.exe",
        "$env:ProgramFiles\PowerToys\PowerToys.KeyboardManagerEngine.exe",
        "$env:ProgramFiles\PowerToys\KeyboardManagerEngine\PowerToys.KeyboardManagerEngine.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $kbmPath = $c
            break
        }
    }
}

if ($kbmPath -and (Test-Path $kbmPath)) {
    Start-Process -FilePath $kbmPath
}

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
