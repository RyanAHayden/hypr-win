# SUPER+I: searchable key hints, read from the keybindings in config.yaml (like hypr-mac's SUPER+I).
# Each bind is described by the comment above it, or above its group.

# Launched from GlazeWM, which may predate tools installed since; pick up the current PATH.
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')

$config = Join-Path $PSScriptRoot 'config.yaml'
$keyNames = @{ win = 'SUPER'; left = '←'; right = '→'; up = '↑'; down = '↓'; enter = 'ENTER'; oem_pipe = '\'; space = 'SPACE'; escape = 'ESC'; oem_question = '/'; oem_minus = '-'; oem_plus = '='; f13 = 'ALT + TAB'; f14 = 'ALT + SHIFT + TAB' }

function Format-Keys($binding) {
	($binding -split '\+' | ForEach-Object { if ($keyNames[$_]) { $keyNames[$_] } else { $_.ToUpper() } }) -join ' + '
}

function Format-Command($command) {
	$command = $command -replace '^shell-exec (--hide-window )?(cmd /c )?(start "?"? ?)?', 'run '
	$command = $command -replace 'powershell\.exe .*-File "[^"]*\\([^"\\]+)"', '$1'
	$command = $command -replace 'pwsh .*-File "[^"]*\\([^"\\]+)"', '$1'
	$command = $command -replace 'python "[^"]*\\([^"\\]+)"', '$1'
	$command = $command -replace '%USERPROFILE%\\\S*\\(\S+\.exe)', '$1'
	$command -replace '"%USERPROFILE%\\([^"]+)"', '$1'
}

$rows = @()
$comment = ''
$inKeybindings = $false
$commands = $null
foreach ($line in Get-Content $config) {
	if ($line -match '^keybindings:') { $inKeybindings = $true; continue }
	if (-not $inKeybindings) { continue }
	if ($line -match '^\s*$' -or $line -match '^\s*#\s*(-\s*commands|bindings):') { $comment = ''; $previousWasComment = $false; continue }
	if ($line -match '^\s*#\s*(.+)$') {
		$comment = if ($previousWasComment) { "$comment $($Matches[1])" } else { $Matches[1] }
		$previousWasComment = $true
		continue
	}
	$previousWasComment = $false
	if ($line -match '^\s*-\s*commands:\s*\[(.+)\]') {
		$commands = ([regex]::Matches($Matches[1], "'((?:[^']|'')*)'") | ForEach-Object { $_.Groups[1].Value }) -join '; '
	} elseif ($commands -and $line -match '^\s*bindings:\s*\[(.+)\]') {
		$keys = ([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { Format-Keys $_.Groups[1].Value }) -join '  /  '
		$rows += [pscustomobject]@{ Keys = $keys; Description = $comment.TrimEnd('.'); Command = Format-Command $commands }
		$commands = $null
	}
}

# Binds the hyprwin switcher handles itself (no GlazeWM bind, see config.yaml), in the same Keys/Description/Command shape.
$hyprwin = @(
	,@('SUPER + TAB', 'Window switcher, all windows: hold SUPER; Tab / Shift back / H J K L move / Q close', 'switcher')
	,@('SUPER + SPACE', 'Vicinae launcher (again closes it)', 'vicinae://toggle')
	,@('SUPER + CTRL + V', 'Vicinae clipboard history', 'vicinae://launch/clipboard/history')
	,@('SUPER + CTRL + E', 'Vicinae emoji picker', 'vicinae://launch/core/search-emojis')
	,@('SUPER + ESC', 'System menu: lock, sleep, hibernate, keep awake, relaunch, log out, restart, shut down', 'powermenu')
	,@('SUPER + SHIFT + H/J/K/L  /  SUPER + SHIFT + arrows', 'Move window: it splits the next window over (Hyprland-style)', 'move')
	,@('SUPER + \', 'Flip the split between the focused window and its sibling', 'togglesplit')
	,@('SUPER + /  /  SUPER + ALT + /', "Display scaling of the focused window's monitor: bigger / more space", 'scale up / scale down')
	,@('SUPER + SHIFT + SPACE', "Toggle Zebar's bar windows", 'togglezebar')
	,@('SUPER + SHIFT + O', 'Toggle focus lock (stops focus following the cursor)', 'focuslock')
	,@('SUPER + F', 'Maximize the focused window (the bar stays visible)', 'fullscreen max')
	,@('SUPER + ALT + F', 'Make the focused window fullscreen (covers the bar)', 'fullscreen')
	,@('ALT + TAB  /  ALT + SHIFT + TAB', 'Next / previous window on this workspace (PowerToys sends F13 / F14)', 'cycle next / cycle prev')
	,@('SUPER + ALT + M', "Bring back a minimized window, preferring this workspace's", 'unminimize')
	,@('SUPER + SHIFT + W', "Force kill the focused window's app", 'kill')
	,@('SUPER + Q', "Quit the focused window's app (closes all its windows; it can still ask to save)", 'quit')
	,@('SUPER + S', 'Toggle the scratchpad workspace without toggling regular workspaces', 'togglescratchpad')
	,@('SUPER + ALT + S', 'Send the focused window to the scratchpad; on it, send the window back', 'scratchpad')
)
foreach ($bind in $hyprwin) {
	$rows += [pscustomobject]@{ Keys = $bind[0]; Description = $bind[1]; Command = "hyprwin.exe $($bind[2])" }
}

$width = ($rows.Keys | Measure-Object -Maximum Length).Maximum + 3
$lines = $rows | ForEach-Object { $_.Keys.PadRight($width) + $_.Description + "  `e[90m" + $_.Command + "`e[0m" }

$header = 'SUPER is the Win key (on the remapped laptop layout: left Alt is SUPER, Win is Alt). Type to filter, Esc to close.'
if (Get-Command fzf -ErrorAction SilentlyContinue) {
	$lines | fzf --ansi --reverse --no-sort --exact --prompt 'Keybinds> ' --header $header --bind 'enter:ignore' | Out-Null
} else {
	Write-Host $header
	$lines | Out-Host -Paging
}
