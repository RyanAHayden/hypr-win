# Toggles the lid-close action between Sleep and Do nothing (plugged in and on battery).
$query = powercfg /qh SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)'
$current = [Convert]::ToInt32($query.Matches[0].Groups[1].Value, 16)

# 0 = Do nothing, 1 = Sleep
$next = if ($current -eq 0) { 1 } else { 0 }
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setactive SCHEME_CURRENT

$message = if ($next -eq 0) { 'Closing the lid keeps the PC awake' } else { 'Closing the lid sleeps the PC' }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Visible = $true
$notify.ShowBalloonTip(3000, 'Lid sleep', $message, [System.Windows.Forms.ToolTipIcon]::Info)
Start-Sleep -Seconds 4
$notify.Dispose()
