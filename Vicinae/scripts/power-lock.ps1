# Also in the SUPER+Escape system menu (hyprwin powermenu, .glzr/glazewm/hyprwin.cs)

# @raycast.schemaVersion 1
# @raycast.title Power: Lock
# @raycast.mode silent
# @raycast.icon 🔒
# @raycast.packageName Omarchy

# hyprwin's switcher disables Win+L (DisableLockWorkstation) and lifts that only for locks asked through its event.
try { [System.Threading.EventWaitHandle]::OpenExisting('Local\hyprwin-lock').Set() | Out-Null }
catch { rundll32.exe user32.dll,LockWorkStation }

