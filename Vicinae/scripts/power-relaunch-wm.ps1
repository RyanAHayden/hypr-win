# Also in the SUPER+Escape system menu (hyprwin powermenu, .glzr/glazewm/hyprwin.cs)

# @raycast.schemaVersion 1
# @raycast.title Power: Relaunch Window Manager
# @raycast.mode silent
# @raycast.icon 🔄
# @raycast.packageName Omarchy

# GlazeWM runs elevated from the "Ryha GlazeWM" logon task (setup-elevated-windows.ps1); its startup commands
# bring back Zebar, hyprwin and the PowerToys layout.
glazewm command wm-exit 2>$null | Out-Null
for ($i = 0; $i -lt 50 -and (Get-Process glazewm -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
schtasks.exe /run /tn 'Ryha GlazeWM' | Out-Null

