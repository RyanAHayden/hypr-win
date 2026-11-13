@REM Installs for this config. Apply the Windows settings afterwards with setup-windows.ps1, then deploy the configs with Dotter or copy_to_user_folder.bat.

@REM CONFIG
winget install DEVCOM.JetBrainsMonoNerdFont
winget install RamenSoftware.Windhawk
winget install AltSnap.AltSnap
winget install xanderfrangos.twinkletray
winget install Microsoft.PowerToys
winget install Flow-Launcher.Flow-Launcher
@REM Vicinae: Raycast-style launcher configured from files (Vicinae/); runs the "Power: ..." Script Commands in Vicinae/scripts
winget install Vicinae.Vicinae
winget install glzr-io.glazewm
winget install glzr-io.zebar
winget install SuperCuber.Dotter
winget install Greenshot.Greenshot

@REM GlazeWM focus lock (Python; setup-windows.ps1 adds websockets) and Zebar widget build (Node)
winget install Python.Python.3.12
winget install OpenJS.NodeJS.LTS

@REM Shell (PowerShell 7 profile: fzf Ctrl+T/Ctrl+R/Alt+C, zoxide cd, eza ls, bat, starship)
@REM Microsoft Store build: downloads from Microsoft's CDN (GitHub release downloads are blocked here)
@REM and installs per user. The machine-scope installer is denied by policy and removed the Store copy.
winget install --id 9MZ1SNWT0N5D --source msstore --accept-package-agreements --accept-source-agreements
winget install Git.Git
winget install Neovim.Neovim
winget install junegunn.fzf
winget install ajeetdsouza.zoxide
winget install eza-community.eza
winget install sharkdp.bat
winget install sharkdp.fd
winget install BurntSushi.ripgrep.MSVC
winget install Starship.Starship

@REM Browser
winget install Zen-Team.Zen-Browser 
winget install Mozilla.Firefox

@REM Misc
winget install AntibodySoftware.WizTree
winget install KeePassXCTeam.KeePassXC
winget install Spotify.Spotify

@REM DEV
winget install Microsoft.VisualStudioCode

ECHO done. Now run: powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"
pause
