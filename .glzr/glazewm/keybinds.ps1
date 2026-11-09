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

$rows += [pscustomobject]@{ Keys = 'SUPER + TAB'; Description = 'Window switcher, all windows: hold SUPER; Tab / Shift back / H J K L move / Q close'; Command = 'hyprwin.exe switcher' }

$width = ($rows.Keys | Measure-Object -Maximum Length).Maximum + 3
$lines = $rows | ForEach-Object { $_.Keys.PadRight($width) + $_.Description + "  `e[90m" + $_.Command + "`e[0m" }

$header = 'SUPER is the Win key (on the remapped laptop layout: left Alt is SUPER, Win is Alt). Type to filter, Esc to close.'
if (Get-Command fzf -ErrorAction SilentlyContinue) {
	$lines | fzf --ansi --reverse --no-sort --exact --prompt 'Keybinds> ' --header $header --bind 'enter:ignore' | Out-Null
} else {
	Write-Host $header
	$lines | Out-Host -Paging
}
