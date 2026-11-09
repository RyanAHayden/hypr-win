# Installs a virtual display (VirtualDrivers Virtual-Display-Driver) so Sunshine/Moonlight still
# has a screen to capture when the laptop lid is closed. Windows clones it with the built-in
# panel, so with the lid open nothing changes. Must run elevated.
$ErrorActionPreference = 'Stop'

$existing = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
	Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
if ($existing) {
	if ($existing.Status -ne 'OK') { $existing | Enable-PnpDevice -Confirm:$false }
	Write-Host 'Virtual display already installed.'
	return
}

$vddVersion = '25.7.23'
$nefconVersion = 'v1.21.0'
$work = Join-Path $env:TEMP 'ryha-vdd'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path $work -Force

$downloads = @{
	'vdd.zip'    = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/$vddVersion/VirtualDisplayDriver-x86.Driver.Only.zip"
	'nefcon.zip' = "https://github.com/nefarius/nefcon/releases/download/$nefconVersion/nefcon_$nefconVersion.zip"
}
foreach ($name in $downloads.Keys) {
	$zip = Join-Path $work $name
	Invoke-WebRequest -Uri $downloads[$name] -OutFile $zip -UseBasicParsing
	Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work ($name -replace '\.zip$')) -Force
}

$driver = Join-Path $work 'vdd\VirtualDisplayDriver'
$nefcon = Join-Path $work 'nefcon\x64\nefconc.exe'

# The driver reads its monitor/resolution list from here.
$null = New-Item -ItemType Directory -Path 'C:\VirtualDisplayDriver' -Force
Copy-Item -LiteralPath (Join-Path $driver 'vdd_settings.xml') -Destination 'C:\VirtualDisplayDriver\' -Force

& $nefcon --create-device-node --hardware-id 'Root\MttVDD' --class-name Display `
	--class-guid 4d36e968-e325-11ce-bfc1-08002be10318
if ($LASTEXITCODE -ne 0) { throw "nefcon could not create the virtual display device ($LASTEXITCODE)." }
& $nefcon --install-driver --inf-path (Join-Path $driver 'MttVDD.inf')
if ($LASTEXITCODE -ne 0) { throw "nefcon could not install the virtual display driver ($LASTEXITCODE)." }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Installed virtual display.'
