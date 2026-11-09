@echo off
REM Copy .config folder and FlowLauncher to user directory

set SOURCE_DIR=%~dp0
set DEST_DIR=C:\Users\%USERNAME%
set ZEBAR_DIR=%SOURCE_DIR%.glzr\zebar\ryha

REM Build Zebar before copying any user settings
if not exist "%ZEBAR_DIR%\package.json" (
    echo Zebar widget source not found: "%ZEBAR_DIR%"
    exit /b 1
)
if not exist "%ZEBAR_DIR%\node_modules\.bin\vite.cmd" (
    echo Zebar dependencies are missing. Run npm install in "%ZEBAR_DIR%" first.
    exit /b 1
)
call npm --prefix "%ZEBAR_DIR%" run build
if errorlevel 1 (
    echo Zebar build failed. No user settings were copied.
    exit /b 1
)

REM Copy .config folder
if exist "%SOURCE_DIR%.config" (
    xcopy "%SOURCE_DIR%.config" "%DEST_DIR%\.config" /E /I /Y
    echo .config folder copied successfully
) else (
    echo .config folder not found
)


REM Copy FlowLauncher settings file and Themes folder
if exist "%SOURCE_DIR%FlowLauncher" (
    if not exist "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings" mkdir "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings"
    if not exist "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings\Plugins" mkdir "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings\Plugins"
    if not exist "%DEST_DIR%\AppData\Roaming\FlowLauncher\Themes" mkdir "%DEST_DIR%\AppData\Roaming\FlowLauncher\Themes"
    if not exist "%DEST_DIR%\AppData\Roaming\FlowLauncher\Plugins" mkdir "%DEST_DIR%\AppData\Roaming\FlowLauncher\Plugins"

    if exist "%SOURCE_DIR%FlowLauncher\Settings\Settings.json" (
        copy "%SOURCE_DIR%FlowLauncher\Settings\Settings.json" "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings\Settings.json" /Y
        echo FlowLauncher Settings.json copied successfully
    ) else (
        echo FlowLauncher Settings.json not found
    )

    if exist "%SOURCE_DIR%FlowLauncher\Themes" (
        xcopy "%SOURCE_DIR%FlowLauncher\Themes" "%DEST_DIR%\AppData\Roaming\FlowLauncher\Themes" /E /I /Y
        echo FlowLauncher Themes copied successfully
    ) else (
        echo FlowLauncher Themes folder not found
    )

    if exist "%SOURCE_DIR%FlowLauncher\Plugins" (
        xcopy "%SOURCE_DIR%FlowLauncher\Plugins" "%DEST_DIR%\AppData\Roaming\FlowLauncher\Plugins" /E /I /Y
        echo FlowLauncher Plugins copied successfully
    ) else (
        echo FlowLauncher Plugins folder not found
    )

    if exist "%SOURCE_DIR%FlowLauncher\Settings\Plugins" (
        xcopy "%SOURCE_DIR%FlowLauncher\Settings\Plugins" "%DEST_DIR%\AppData\Roaming\FlowLauncher\Settings\Plugins" /E /I /Y
        echo FlowLauncher plugin settings copied successfully
    ) else (
        echo FlowLauncher plugin settings folder not found
    )

    if exist "%SOURCE_DIR%FlowLauncher\Scripts" (
        xcopy "%SOURCE_DIR%FlowLauncher\Scripts" "%DEST_DIR%\AppData\Roaming\FlowLauncher\Scripts" /E /I /Y
        REM Start Menu shortcut so Flow Launcher can find "Toggle Lid Sleep"
        powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%APPDATA%\Microsoft\Windows\Start Menu\Programs\Toggle Lid Sleep.lnk'); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%DEST_DIR%\AppData\Roaming\FlowLauncher\Scripts\toggle_lid_sleep.ps1\"'; $s.WindowStyle = 7; $s.IconLocation = '%SystemRoot%\System32\powercpl.dll,0'; $s.Description = 'Toggle whether closing the lid sleeps the PC'; $s.Save()"
        echo FlowLauncher scripts and Toggle Lid Sleep shortcut copied
    )
) else (
    echo FlowLauncher folder not found
)

REM Copy PowerToys plugin state and Keyboard Manager preferences
if exist "%SOURCE_DIR%PowerToys" (
    if not exist "%DEST_DIR%\AppData\Local\Microsoft\PowerToys" mkdir "%DEST_DIR%\AppData\Local\Microsoft\PowerToys"
    if not exist "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager" mkdir "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager"

    if exist "%SOURCE_DIR%PowerToys\settings.json" (
        copy "%SOURCE_DIR%PowerToys\settings.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\settings.json" /Y
        echo PowerToys settings.json copied successfully
    ) else (
        echo PowerToys settings.json not found
    )

    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\default.json" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\default.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\default.json" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\layout_remapped.json" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\layout_remapped.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\layout_remapped.json" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\layout_default.json" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\layout_default.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\layout_default.json" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\toggle_keyboard_layout.ps1" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\toggle_keyboard_layout.ps1" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\toggle_keyboard_layout.ps1" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\toggle_keyboard_layout.bat" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\toggle_keyboard_layout.bat" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\toggle_keyboard_layout.bat" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\editorSettings.json" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\editorSettings.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\editorSettings.json" /Y
    )
    if exist "%SOURCE_DIR%PowerToys\Keyboard Manager\settings.json" (
        copy "%SOURCE_DIR%PowerToys\Keyboard Manager\settings.json" "%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\settings.json" /Y
    )

    REM Create Start Menu shortcut for toggling keyboard layout
    powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('%APPDATA%\Microsoft\Windows\Start Menu\Programs\Toggle Keyboard Layout.lnk'); $s.TargetPath = '%DEST_DIR%\AppData\Local\Microsoft\PowerToys\Keyboard Manager\toggle_keyboard_layout.bat'; $s.Arguments = ''; $s.IconLocation = '%LOCALAPPDATA%\PowerToys\PowerToys.exe,0'; $s.Description = 'Toggle PowerToys Keyboard Manager Layout'; $s.Save()"
    echo PowerToys Keyboard Manager preferences and Toggle shortcut copied
) else (
    echo PowerToys folder not found
)

REM Copy GlazeWM configuration
if exist "%SOURCE_DIR%.glzr" (
    robocopy "%SOURCE_DIR%.glzr" "%DEST_DIR%\.glzr" /E /XD node_modules .git
    if errorlevel 8 (
        echo GlazeWM and Zebar configuration copy failed.
        exit /b 1
    )
    echo GlazeWM and Zebar configuration copied successfully
) else (
    echo GlazeWM folder not found
)

REM Copy AltSnap.ini file
if exist "%SOURCE_DIR%AltSnap.ini" (
    copy "%SOURCE_DIR%AltSnap.ini" "%DEST_DIR%\AltSnap.ini" /Y
    if not exist "%APPDATA%\AltSnap" mkdir "%APPDATA%\AltSnap"
    copy "%SOURCE_DIR%AltSnap.ini" "%APPDATA%\AltSnap\AltSnap.ini" /Y
    echo AltSnap.ini copied successfully to user folder and AppData
) else (
    echo AltSnap.ini not found
)

REM Copy PowerShell 7 profile and starship prompt config
if exist "%SOURCE_DIR%PowerShell" (
    if not exist "%DEST_DIR%\Documents\PowerShell" mkdir "%DEST_DIR%\Documents\PowerShell"
    copy "%SOURCE_DIR%PowerShell\Microsoft.PowerShell_profile.ps1" "%DEST_DIR%\Documents\PowerShell\Microsoft.PowerShell_profile.ps1" /Y
    if not exist "%DEST_DIR%\.config" mkdir "%DEST_DIR%\.config"
    copy "%SOURCE_DIR%PowerShell\starship.toml" "%DEST_DIR%\.config\starship.toml" /Y
    echo PowerShell profile and starship.toml copied successfully
) else (
    echo PowerShell folder not found
)

echo Done.