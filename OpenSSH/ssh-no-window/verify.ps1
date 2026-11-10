param(
    [ValidatePattern('^[^\s"]+$')]
    [string]$UserName = $env:USERNAME
)

$ErrorActionPreference = 'Stop'

function Invoke-SshCheck {
    param([string]$Command, [switch]$Pty, [string]$InputText)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = "$env:WINDIR\System32\OpenSSH\ssh.exe"
    $mode = if ($Pty) { '-tt' } else { '-T' }
    $start.Arguments = "$mode -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -l $UserName localhost"
    if ($Command) {
        $start.Arguments += ' "' + $Command + '"'
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputText) {
        $process.StandardInput.Write($InputText)
    }
    if (-not $Pty) {
        $process.StandardInput.Close()
    }
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force
        throw 'Public-key SSH check timed out.'
    }
    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout.Result
        Stderr = $stderr.Result
    }
    if ($Pty) {
        $process.StandardInput.Close()
    }
    $process.Dispose()
    return $result
}

$command = '$p = Get-CimInstance Win32_Process -Filter (''ProcessId='' + $PID); (Get-Process -Id $p.ParentProcessId).ProcessName; [Console]::Out.WriteLine(''QUOTED:space & dollar $ backslash \''); [Console]::Error.WriteLine(''SSH_STDERR_OK''); exit 7'
$result = Invoke-SshCheck -Command $command
if ($result.ExitCode -ne 7 -or
    $result.Stdout -notmatch 'powershell-ssh' -or
    -not $result.Stdout.Contains('QUOTED:space & dollar $ backslash \') -or
    -not $result.Stderr.Contains('SSH_STDERR_OK')) {
    throw "SSH command/launcher/stdout/stderr/exit check failed: $($result | Out-String)"
}
Write-Output 'PASS: public-key command SSH, launcher ancestry, quoting, stderr, exit status.'

$result = Invoke-SshCheck -Command '[Console]::WriteLine(''INPUT:'' + [Console]::ReadLine()); exit 0' -InputText "piped input with spaces`n"
if ($result.ExitCode -ne 0 -or -not $result.Stdout.Contains('INPUT:piped input with spaces')) {
    throw "SSH stdin check failed: $($result | Out-String)"
}
Write-Output 'PASS: SSH stdin forwarding.'

$result = Invoke-SshCheck -Pty -Command 'Write-Output ''SSH_PTY_OK''; exit 0'
if ($result.ExitCode -ne 0 -or -not $result.Stdout.Contains('SSH_PTY_OK')) {
    throw "SSH PTY command check failed: $($result | Out-String)"
}
Write-Output 'PASS: public-key PTY SSH.'

$result = Invoke-SshCheck -Pty -InputText "Write-Output ('SSH_' + 'INTERACTIVE_OK')`r`nexit 0`r`n"
if ($result.ExitCode -ne 0 -or -not $result.Stdout.Contains('SSH_INTERACTIVE_OK')) {
    throw "Interactive SSH check failed: $($result | Out-String)"
}
Write-Output 'PASS: public-key interactive SSH shell.'

$service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if ($service.State -ne 'Stopped' -or $service.StartMode -ne 'Disabled') {
    throw 'The sshd service must remain stopped and disabled.'
}
[xml]$task = (& schtasks.exe /Query /TN '\sshd-user' /XML) -join "`n"
if ($LASTEXITCODE -ne 0 -or $task.Task.Settings.Enabled -eq 'false') {
    throw 'The sshd-user task must remain enabled.'
}
Write-Output 'PASS: sshd-user remains enabled; sshd service remains stopped and disabled.'
