# Point the Windows OpenSSH DefaultShell at the installed PowerShell 7.
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

if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\OpenSSH')) {
	$null = New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force
}
$current = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).DefaultShell
if ($current -ne $shell) {
	New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
}
Write-Host "OpenSSH DefaultShell: $shell"
