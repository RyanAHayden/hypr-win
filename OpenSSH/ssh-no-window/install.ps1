param(
    [ValidatePattern('^[^\s"]+$')]
    [string]$UserName = $env:USERNAME
)

$ErrorActionPreference = 'Stop'
$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) { throw 'Run this installer from an elevated PowerShell window.' }
$build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -lt 26100) { throw 'Detached console allocation requires Windows build 26100 or later.' }
$service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if ($service.State -ne 'Stopped' -or $service.StartMode -ne 'Disabled') {
    throw 'Keep sshd stopped and disabled; SSH must already work through sshd-user.'
}
[xml]$task = (& schtasks.exe /Query /TN '\sshd-user' /XML) -join "`n"
if ($LASTEXITCODE -ne 0 -or $task.Task.Settings.Enabled -eq 'false') {
    throw 'An enabled sshd-user scheduled task is required.'
}

& (Join-Path $PSScriptRoot 'build.ps1')
$installDirectory = Join-Path $env:ProgramFiles 'hypr-win\ssh-no-window'
$null = New-Item -ItemType Directory -Path $installDirectory -Force
$backupDirectory = Join-Path $installDirectory ('backup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $backupDirectory
$launcher = Join-Path $installDirectory 'powershell-ssh.exe'
$ini = Join-Path $installDirectory 'launcher.ini'
$syncDirectory = Join-Path $env:ProgramData 'ryha-config'
$syncScript = Join-Path $syncDirectory 'sync-openssh-shell.ps1'
$syncSource = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'sync-openssh-shell.ps1'
$originalShell = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH').DefaultShell
$hadLauncher = Test-Path -LiteralPath $launcher
$hadIni = Test-Path -LiteralPath $ini
$hadSync = Test-Path -LiteralPath $syncScript
$changed = $false

function Restart-TaskListener {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 |
        Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($listenerId in $listeners) {
        $listener = Get-CimInstance Win32_Process -Filter "ProcessId=$listenerId"
        if ($listener.Name -ne 'sshd.exe' -or $listener.SessionId -eq 0) {
            throw 'Port 22 is not owned by the desktop sshd-user listener.'
        }
        # Stop only the listener; leave established SSH session processes alone.
        Stop-Process -Id $listenerId -Force
    }
    Start-Sleep -Seconds 3
    & schtasks.exe /Run /TN '\sshd-user'
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart sshd-user.' }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue)
    } while (-not $listeners.Count -and (Get-Date) -lt $deadline)
    if (-not $listeners.Count) { throw 'sshd-user did not resume listening on port 22.' }
}

Start-Transcript -Path (Join-Path $installDirectory 'install.log') -Force
try {
    $originalShell | Set-Content -LiteralPath (Join-Path $backupDirectory 'original-shell.txt') -Encoding Unicode
    if ($hadIni) { Copy-Item -LiteralPath $ini -Destination $backupDirectory }
    if ($hadSync) { Copy-Item -LiteralPath $syncScript -Destination $backupDirectory }
    if ($hadLauncher) {
        Move-Item -LiteralPath $launcher -Destination (Join-Path $backupDirectory 'powershell-ssh.exe')
    }
    $changed = $true
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build\powershell-ssh.exe') -Destination $launcher
    $null = New-Item -ItemType Directory -Path $syncDirectory -Force
    Copy-Item -LiteralPath $syncSource -Destination $syncScript -Force
    & $syncScript
    Restart-TaskListener
    & (Join-Path $PSScriptRoot 'verify.ps1') -UserName $UserName
    Write-Output "SUCCESS: installed $launcher; passwordless SSH still runs through sshd-user."
} catch {
    Write-Output "FAILED: $($_.Exception.Message)"
    if ($changed) {
        try {
            New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $originalShell -PropertyType String -Force | Out-Null
            if (Test-Path -LiteralPath $launcher) {
                Move-Item -LiteralPath $launcher -Destination (Join-Path $backupDirectory 'failed-powershell-ssh.exe')
            }
            if ($hadLauncher) {
                Move-Item -LiteralPath (Join-Path $backupDirectory 'powershell-ssh.exe') -Destination $launcher
            }
            if ($hadIni) {
                Copy-Item -LiteralPath (Join-Path $backupDirectory 'launcher.ini') -Destination $ini -Force
            } elseif (Test-Path -LiteralPath $ini) {
                Remove-Item -LiteralPath $ini
            }
            if ($hadSync) {
                Copy-Item -LiteralPath (Join-Path $backupDirectory 'sync-openssh-shell.ps1') -Destination $syncScript -Force
            } elseif (Test-Path -LiteralPath $syncScript) {
                Remove-Item -LiteralPath $syncScript
            }
            Restart-TaskListener
            Write-Output 'ROLLED BACK: restored the previous shell, launcher and sync script.'
        } catch {
            Write-Output "ROLLBACK FAILED: $($_.Exception.Message)"
        }
    }
    throw
} finally {
    Stop-Transcript
}
