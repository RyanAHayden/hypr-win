# ryha-config
This is My Windows Config For Tiling. <br>
Mostly for personal reasons but feel free to mess around with the configs.

!! GlazeWM Zebar themes are not changed by `CHANGE_COLORS.md` yet.

Install what you want manually or use the included `installs.bat`

# Linking configs with Dotter (Stow-style)
[Dotter](https://github.com/SuperCuber/dotter) symlinks repo files into place, so edits in either location are the same file. The copy scripts still work as a fallback.

1. Enable Developer Mode (Settings > System > For developers), otherwise Dotter copies instead of linking.
2. `winget install SuperCuber.Dotter`
3. Run `copy_from_user_folder.bat` once and commit anything you want to keep, since the first deploy replaces the live files.
4. Create `.dotter/local.toml` (not tracked) choosing packages from `.dotter/global.toml`:
   ```toml
   packages = ["glazewm", "flowlauncher", "powertoys", "altsnap"]
   ```
   Zebar stays on `copy_to_user_folder.bat` because it won't load symlinked widget files.
5. From the repo root: `dotter deploy --dry-run`, then `dotter deploy --force` the first time and `dotter deploy` after.

`dotter undeploy` removes the links. Some apps rewrite settings by replacing the file, which breaks the link; `dotter deploy` reports those.

# Install

## < [Nerd Font](https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip) > (Required for icons)
```
winget install --id DEVCOM.JetBrainsMonoNerdFont
```
## < [GlazeWM](https://github.com/glzr-io/glazewm) >
```
winget install -e --id glzr-io.glazewm
```

## < [AltSnap](https://github.com/RamonUnch/AltSnap) >
```
winget install AltSnap.AltSnap
```

### Config:
Use included AltSnap.ini (Copied in `copy_to_user_folder.bat`)

## < [WindHawk](https://windhawk.net/) >
```
winget install windhawk
```

### Mods
listed in /Windhawk/userprofile.json
- `windows-11-start-menu-styler` (SideBySideMinimal)
- `taskbar-icon-size` - Height: `28` - Icon: `20` - Width: `28`
- `windows-11-taskbar-styler` - SimplyTransparent
  
<img src="README_Assets/sidebyside.png" alt="windows start menu" width="200" />

## < [Flow Launcher](https://github.com/Flow-Launcher/Flow.Launcher) >
```
winget install "Flow Launcher"
```
### Settings & Theme
Copy `/FlowLauncher` to
`C:\Users\{user}\AppData\Roaming`
Apply `ryha` using `fltheme ryha`

### Plugins
- Steam Search `by Garulf`
- Visual Studio Code Workspaces `by ricardosantos9521, MaskedRPGFan`
- FlowYoutube `by Garulf`

### Plugin Settings
Set explorer shortcuts like these:

<img src="README_Assets/example_quicklaunch.png" alt="example" width="400" />

# Recommended
## < [Zen Browser](https://zen-browser.app/) >
### Settings
- Compact Hides Sidebar and Top Toolbar

## < [TwinkleTray](https://twinkletray.com/) >
```
winget install xanderfrangos.twinkletray
```

---