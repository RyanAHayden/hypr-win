$ErrorActionPreference = 'Stop'
$outputDirectory = Join-Path $PSScriptRoot 'build'
$null = New-Item -ItemType Directory -Path $outputDirectory -Force
$manifestObject = Join-Path $outputDirectory 'powershell-ssh-manifest.o'
$executable = Join-Path $outputDirectory 'powershell-ssh.exe'

Push-Location -LiteralPath $PSScriptRoot
try {
    & windres -i powershell-ssh.rc -o $manifestObject --output-format=coff
    if ($LASTEXITCODE -ne 0) { throw 'Manifest compilation failed.' }
    # Replace MinGW's default manifest with the detached-console manifest.
    & gcc -std=c11 -O2 -Wall -Wextra -Werror -municode -mconsole -static-libgcc '-Wl,--fatal-warnings,--no-insert-timestamp' '-specs=launcher.specs' -o $executable powershell-ssh.c $manifestObject
    if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
} finally {
    Pop-Location
}
