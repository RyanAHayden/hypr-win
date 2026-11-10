# Sunshine prep-cmd for the Desktop app: blank Windows cursors while Moonlight streams, so only the Mac's own
# cursor shows (Moonlight's local cursor, which has no network lag) instead of Sunshine also drawing ours a
# round trip behind it. Usage: stream-cursor.ps1 hide|show. hide saves the current scheme; show puts it back.
param([Parameter(Mandatory)][ValidateSet('hide', 'show')][string]$Mode)

$key = 'HKCU:\Control Panel\Cursors'
$dir = Join-Path $env:LOCALAPPDATA 'stream-cursor'
$blank = Join-Path $dir 'blank.cur'
$saved = Join-Path $dir 'saved.json'
$names = 'Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No', 'SizeNS', 'SizeWE',
  'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person'

Add-Type -Namespace StreamCursor -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
'@
function Reload { [StreamCursor.Native]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 3) | Out-Null } # SPI_SETCURSORS

if ($Mode -eq 'hide') {
  New-Item -ItemType Directory -Force $dir | Out-Null
  if (-not (Test-Path $blank)) {
    # 32x32 cursor, 32-bit with zero alpha and an all-transparent AND mask
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
    $w.Write([uint16]0); $w.Write([uint16]2); $w.Write([uint16]1)
    $w.Write([byte]32); $w.Write([byte]32); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint32](40 + 4096 + 128)); $w.Write([uint32]22)
    $w.Write([uint32]40); $w.Write([int32]32); $w.Write([int32]64); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32](4096 + 128)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Write((New-Object byte[] 4096)); $w.Write([byte[]](,0xFF * 128))
    [IO.File]::WriteAllBytes($blank, $ms.ToArray())
  }
  # don't save over the real scheme if a session died without show
  if (-not (Test-Path $saved)) {
    $cur = Get-ItemProperty $key
    $o = [ordered]@{ '(default)' = $cur.'(default)' }
    foreach ($n in $names) { $o[$n] = $cur.$n }
    $o | ConvertTo-Json | Set-Content $saved
  }
  foreach ($n in $names) { Set-ItemProperty $key $n $blank }
  Reload
}
else {
  if (Test-Path $saved) {
    $o = Get-Content $saved -Raw | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) { Set-ItemProperty $key $p.Name ([string]$p.Value) }
    Remove-Item $saved
  }
  Reload
}
