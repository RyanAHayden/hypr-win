# Also in the SUPER+Escape system menu (hyprwin powermenu, .glzr/glazewm/hyprwin.cs)

# @raycast.schemaVersion 1
# @raycast.title Power: Keep Awake With Lid Closed
# @raycast.mode compact
# @raycast.icon ☕
# @raycast.packageName Omarchy

# Toggles the lid-close action between Sleep and Do nothing (plugged in and on battery). With Do nothing, the virtual
# display (install-virtual-display.ps1) keeps Sunshine streaming after the built-in screen turns off.
$query = powercfg /qh SCHEME_CURRENT SUB_BUTTONS LIDACTION | Select-String 'Current AC Power Setting Index: (0x[0-9a-f]+)'
$next = if ([Convert]::ToInt32($query.Matches[0].Groups[1].Value, 16) -eq 0) { 1 } else { 0 }
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $next
powercfg /setactive SCHEME_CURRENT
if ($next -eq 0) { 'Staying awake: lid close only turns the screen off' } else { 'Sleep back on' }

