@REM Installs and Windows settings for this config. Deploy the configs afterwards with Dotter or copy_to_user_folder.bat.

@REM CONFIG
winget install DEVCOM.JetBrainsMonoNerdFont
winget install RamenSoftware.Windhawk
winget install AltSnap.AltSnap
winget install xanderfrangos.twinkletray
winget install Microsoft.PowerToys
winget install Flow-Launcher.Flow-Launcher
winget install glzr-io.glazewm
winget install glzr-io.zebar
winget install SuperCuber.Dotter

@REM GlazeWM focus lock (Python + websockets) and Zebar widget build (Node)
winget install Python.Python.3.12
py -3.12 -m pip install --user websockets
winget install OpenJS.NodeJS.LTS

@REM Shell (PowerShell 7 profile: fzf Ctrl+T/Ctrl+R/Alt+C, zoxide cd, eza ls, bat, starship)
winget install Microsoft.PowerShell --scope machine
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

@REM Windows settings (Narrator off, accessibility shortcuts off, no Snap/animations, taskbar, Explorer, Developer Mode, PSFzf, Terminal default)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1"

ECHO done.
pause
