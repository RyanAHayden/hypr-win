# Toggles the lid-close action between Sleep and Do nothing (plugged in and on battery).
$query = powercfg /qh SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)'
$current = [Convert]::ToInt32($query.Matches[0].Groups[1].Value, 16)

# 0 = Do nothing, 1 = Sleep
$next = if ($current -eq 0) { 1 } else { 0 }
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setactive SCHEME_CURRENT

# With "Do nothing", the virtual display (install-virtual-display.ps1) keeps Sunshine streaming
# after the built-in screen turns off.
$message = if ($next -eq 0) { 'Closing the lid keeps the PC awake (screen off, still streamable)' } else { 'Closing the lid sleeps the PC' }

# A tray balloon from a hidden script often never shows on Windows 11; a toast under PowerShell's app ID does.
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$toast = New-Object Windows.Data.Xml.Dom.XmlDocument
$toast.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Lid sleep</text><text>$([Security.SecurityElement]::Escape($message))</text></binding></visual></toast>")
$powershellAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($powershellAppId).Show([Windows.UI.Notifications.ToastNotification]::new($toast))
