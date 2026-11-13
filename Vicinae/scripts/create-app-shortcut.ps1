# Makes a Start menu shortcut (Start Menu\Programs\App Shortcuts\<Name>.lnk), so the launcher can open it.
# Target is a file/folder/app/URL to open, or else a PowerShell command (run hidden, in the background).

# @raycast.schemaVersion 1
# @raycast.title Create App Shortcut
# @raycast.mode compact
# @raycast.icon 🚀
# @raycast.packageName Omarchy
# @raycast.argument1 { "type": "text", "placeholder": "Name" }
# @raycast.argument2 { "type": "text", "placeholder": "File or command" }

param([string]$Name, [string]$Target)

$Name = ($Name -replace '[\\/:*?"<>|]', '-').Trim()
if (-not $Name -or -not $Target) { 'Need a name and a file or command'; exit 1 }
$dir = Join-Path ([Environment]::GetFolderPath('Programs')) 'App Shortcuts'
New-Item -ItemType Directory -Force $dir | Out-Null
$lnk = Join-Path $dir "$Name.lnk"

$path = [Environment]::ExpandEnvironmentVariables($Target -replace '^~', $HOME)
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
if (Test-Path -LiteralPath $path) {
	$shortcut.TargetPath = (Resolve-Path -LiteralPath $path).Path
	$what = "Opens $($shortcut.TargetPath)"
} elseif ($Target -match '^[a-z][a-z0-9+.-]*://') {
	$shortcut.TargetPath = 'explorer.exe'
	$shortcut.Arguments = "`"$Target`""
	$what = "Opens $Target"
} else {
	$shortcut.TargetPath = (Get-Command pwsh, powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
	$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Target))
	$shortcut.Arguments = "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
	$what = "Runs $Target"
}
$shortcut.Save()
"${Name}: $what"
