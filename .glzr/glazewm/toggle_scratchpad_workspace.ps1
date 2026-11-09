$ErrorActionPreference = 'Stop'

$glazewm = Join-Path $env:ProgramFiles 'glzr.io\GlazeWM\cli\glazewm.exe'
if (-not (Test-Path -LiteralPath $glazewm)) {
	throw "GlazeWM CLI not found: $glazewm"
}

$workspaceOutput = & $glazewm query workspaces
if ($LASTEXITCODE -ne 0) {
	throw 'GlazeWM failed to query workspaces.'
}

$workspaceResponse = $workspaceOutput | ConvertFrom-Json
if (-not $workspaceResponse.success) {
	throw 'GlazeWM returned an unsuccessful workspace query.'
}

$scratchpad = $workspaceResponse.data.workspaces | Where-Object name -CEQ 'S'
if (-not $scratchpad) {
	throw 'Scratchpad workspace S was not found.'
}

if ($scratchpad.hasFocus) {
	$focusArgs = @('command', 'focus', '--recent-workspace')
} else {
	$focusArgs = @('command', 'focus', '--workspace', 'S')
}

$focusOutput = & $glazewm @focusArgs
if ($LASTEXITCODE -ne 0) {
	throw "GlazeWM failed to focus the scratchpad workspace: $focusOutput"
}

$focusResponse = $focusOutput | ConvertFrom-Json
if (-not $focusResponse.success) {
	throw 'GlazeWM returned an unsuccessful focus command.'
}
