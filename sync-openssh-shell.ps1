# Point Windows OpenSSH at the no-window launcher, when installed, or PowerShell 7.
# The Microsoft Store package folder contains its version, so this re-runs from a
# scheduled task to follow updates. sshd rejects logins (falling back to a password
# prompt) when DefaultShell does not exist, hence the Windows PowerShell fallback.
$ErrorActionPreference = 'Stop'

$candidates = @('C:\Program Files\PowerShell\7\pwsh.exe')
$candidates += Get-AppxPackage -AllUsers -Name Microsoft.PowerShell |
	Sort-Object { [version]$_.Version } -Descending |
	ForEach-Object { Join-Path $_.InstallLocation 'pwsh.exe' }
$candidates += Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$shell = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $shell) { throw 'No usable PowerShell executable was found for OpenSSH.' }

$launcherDirectory = Join-Path $env:ProgramFiles 'hypr-win\ssh-no-window'
$launcher = Join-Path $launcherDirectory 'powershell-ssh.exe'
$defaultShell = $shell
if (Test-Path -LiteralPath $launcher -PathType Leaf) {
	# This directory is administrator-owned because the sync task runs as SYSTEM.
	$ini = Join-Path $launcherDirectory 'launcher.ini'
	$temporaryIni = Join-Path $launcherDirectory ('launcher-' + [guid]::NewGuid().ToString('N') + '.tmp')
	try {
		@('[shell]', "path=$shell") | Set-Content -LiteralPath $temporaryIni -Encoding Unicode
		if (Test-Path -LiteralPath $ini) {
			[IO.File]::Replace($temporaryIni, $ini, [NullString]::Value)
		} else {
			[IO.File]::Move($temporaryIni, $ini)
		}
	} finally {
		if (Test-Path -LiteralPath $temporaryIni) { Remove-Item -LiteralPath $temporaryIni }
	}
	$defaultShell = $launcher
}

if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\OpenSSH')) {
	$null = New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force
}
$current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).DefaultShell
if ($current -ne $defaultShell) {
	New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $defaultShell -PropertyType String -Force | Out-Null
}
Write-Host "OpenSSH DefaultShell: $defaultShell (PowerShell: $shell)"
