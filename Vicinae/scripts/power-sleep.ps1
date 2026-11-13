# Also in the SUPER+Escape system menu (hyprwin powermenu, .glzr/glazewm/hyprwin.cs)

# @raycast.schemaVersion 1
# @raycast.title Power: Sleep
# @raycast.mode silent
# @raycast.icon 💤
# @raycast.packageName Omarchy

# rundll32 powrprof.dll,SetSuspendState hibernates whenever hibernation is on, so call it with real arguments.
Add-Type -Namespace Ryha -Name Power -MemberDefinition '[DllImport("powrprof.dll")] public static extern bool SetSuspendState(bool hibernate, bool force, bool disableWake);'
[void][Ryha.Power]::SetSuspendState($false, $false, $false)

