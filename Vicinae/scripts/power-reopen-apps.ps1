# Also in the SUPER+Escape system menu (hyprwin powermenu, .glzr/glazewm/hyprwin.cs)

# @raycast.schemaVersion 1
# @raycast.title Power: Reopen Apps at Login
# @raycast.mode compact
# @raycast.icon 🔁
# @raycast.packageName Omarchy

# Toggles Windows' "Automatically save my restartable apps and restart them when I sign back in".
$key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
$on = (Get-ItemProperty $key -Name RestartApps -ErrorAction SilentlyContinue).RestartApps -ne 1
Set-ItemProperty $key -Name RestartApps -Value ([int]$on) -Type DWord
if ($on) { 'Running apps reopen after restart / log out' } else { "Apps won't reopen after restart / log out" }

