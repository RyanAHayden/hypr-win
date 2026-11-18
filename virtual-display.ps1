# Turns the virtual display (install-virtual-display.ps1) on or off. Sunshine runs it elevated when a stream
# starts and ends, so the extra screen only exists while streaming and doesn't break Windows' display modes.
param([Parameter(Mandatory)][ValidateSet('On', 'Off')][string]$State)
$ErrorActionPreference = 'Stop'

$device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
	Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
if (-not $device) { throw 'Virtual display is not installed.' }
if ($State -eq 'On') { $device | Enable-PnpDevice -Confirm:$false }
else { $device | Disable-PnpDevice -Confirm:$false }
