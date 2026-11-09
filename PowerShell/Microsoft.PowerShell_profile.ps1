# PowerShell 7 profile, ported from hypr-mac's .zshrc (github.com/RyanAHayden/hypr-mac)

$profileStartupTimer = [Diagnostics.Stopwatch]::StartNew()
$profileStartupMarks = [ordered]@{}
$profileStartupReadLineLoaded = [bool](Get-Module PSReadLine)

function Test-Command($Name) { [bool](Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }

# Read a symlink's target instead of following it: Windows OpenSSH sessions refuse to traverse
# user-created symlinks (winget Links, Dotter-deployed files).
function Get-LinkTargetItem([IO.FileSystemInfo]$Item) {
	if ($Item.LinkTarget) { Get-Item -LiteralPath ([IO.Path]::GetFullPath($Item.LinkTarget, $Item.DirectoryName)) -ErrorAction Stop } else { $Item }
}

if ($env:SSH_CONNECTION) {
	$wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
	$wingetTargets = Get-ChildItem -LiteralPath $wingetLinks -File -ErrorAction SilentlyContinue |
		Where-Object LinkTarget | ForEach-Object { Split-Path -Parent $_.LinkTarget } | Select-Object -Unique
	if ($wingetTargets) { $env:PATH = (@($wingetTargets) + $env:PATH) -join ';' }
	$starshipConfig = Get-Item -LiteralPath (Join-Path $HOME '.config\starship.toml') -ErrorAction SilentlyContinue
	if (-not $env:STARSHIP_CONFIG -and $starshipConfig.LinkTarget) { $env:STARSHIP_CONFIG = (Get-LinkTargetItem $starshipConfig).FullName }
}

function Get-ShellInit($Name, [string[]]$Arguments) {
	$command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
	$binary = Get-LinkTargetItem (Get-Item -LiteralPath $command.Source -ErrorAction Stop)
	$settings = if ($Name -eq 'zoxide') {
		Get-ChildItem Env:_ZO_* | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
	} elseif ($Name -eq 'starship') {
		$configPath = if ($env:STARSHIP_CONFIG) { $env:STARSHIP_CONFIG } else { Join-Path $HOME '.config\starship.toml' }
		$configPath = [IO.Path]::GetFullPath($configPath, $PWD.Path)
		$configPath
		if (Test-Path -LiteralPath $configPath) {
			$config = Get-LinkTargetItem (Get-Item -LiteralPath $configPath -ErrorAction Stop)
			$config.FullName
			$config.LastWriteTimeUtc.Ticks
			$config.Length
		}
	}
	$key = @(3, $command.Source, $binary.FullName, $binary.LastWriteTimeUtc.Ticks, $binary.Length,
		$PSVersionTable.PSVersion.ToString(), $Arguments, $settings) | ConvertTo-Json -Compress
	$cacheDirectory = Join-Path $env:LOCALAPPDATA 'ryha-config\PowerShell'
	$cachePath = Join-Path $cacheDirectory "$Name-init.json"
	if (Test-Path -LiteralPath $cachePath) {
		$cache = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
		if ($cache.Key -eq $key -and -not [string]::IsNullOrWhiteSpace($cache.Init)) { return $cache.Init }
	}
	$init = & $command.Source @Arguments | Out-String
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($init)) {
		throw "$Name shell initialization failed (exit code $LASTEXITCODE)."
	}
	if ($Name -eq 'starship') {
		$tokens = $null; $parseErrors = $null
		$ast = [System.Management.Automation.Language.Parser]::ParseInput($init, [ref]$tokens, [ref]$parseErrors)
		if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
		$continuationCommands = @($ast.FindAll({
			param($node)
			$node -is [System.Management.Automation.Language.CommandAst] -and
				$node.GetCommandName() -eq 'Set-PSReadLineOption' -and $node.CommandElements.Count -eq 3 -and
				$node.CommandElements[1] -is [System.Management.Automation.Language.CommandParameterAst] -and
				$node.CommandElements[1].ParameterName -eq 'ContinuationPrompt'
		}, $true))
		if ($continuationCommands.Count -eq 1) {
			$startInfo = [Diagnostics.ProcessStartInfo]::new($command.Source)
			$startInfo.UseShellExecute = $false
			$startInfo.CreateNoWindow = $true
			$startInfo.RedirectStandardOutput = $true
			$startInfo.RedirectStandardError = $true
			$startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
			$startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
			$startInfo.ArgumentList.Add('prompt')
			$startInfo.ArgumentList.Add('--continuation')
			$process = [Diagnostics.Process]::Start($startInfo)
			try {
				$stdout = $process.StandardOutput.ReadToEndAsync()
				$stderr = $process.StandardError.ReadToEndAsync()
				$continuation = $stdout.GetAwaiter().GetResult()
				$errorText = $stderr.GetAwaiter().GetResult()
				$process.WaitForExit()
				if ($errorText) { $Host.UI.WriteErrorLine($errorText) }
				if ($process.ExitCode -ne 0) { throw "Starship continuation prompt failed (exit code $($process.ExitCode))." }
			} finally {
				$process.Dispose()
			}
			$literal = "'" + $continuation.Replace("'", "''") + "'"
			$extent = $continuationCommands[0].CommandElements[2].Extent
			# Cache this config-dependent value without changing Starship's prompt/session logic.
			$init = $init.Remove($extent.StartOffset, $extent.EndOffset - $extent.StartOffset).Insert($extent.StartOffset, $literal)
		} else {
			Write-Warning 'Starship initializer changed; continuation-prompt caching was skipped.'
		}
	}
	$null = [IO.Directory]::CreateDirectory($cacheDirectory)
	$tempPath = Join-Path $cacheDirectory "$Name-$([guid]::NewGuid()).tmp"
	try {
		$content = @{ Key = $key; Init = $init } | ConvertTo-Json -Compress
		[IO.File]::WriteAllText($tempPath, $content)
		# Publish atomically so simultaneous shells never read a partly written cache.
		[IO.File]::Move($tempPath, $cachePath, $true)
	} finally {
		if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
	}
	return $init
}

# Emacs keys like bash/readline (Ctrl+A/E/W/U/K/Y, Alt+B/F, Ctrl+D exits on an empty line)
$profileStartupMarks['Helpers'] = $profileStartupTimer.ElapsedMilliseconds
Set-PSReadLineOption -EditMode Emacs -BellStyle None -HistoryNoDuplicates -MaximumHistoryCount 32768 -HistorySearchCursorMovesToEnd
# Up/Down match what you've typed so far against history (ssh<Up> -> ssh rycs)
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
# Case-insensitive completion menu, Ctrl+arrows word jump
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord
Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord
# Ctrl+X Ctrl+E = edit the command line in $env:EDITOR
Set-PSReadLineKeyHandler -Chord Ctrl+x, Ctrl+e -Function ViEditVisually
$profileStartupMarks['PSReadLine'] = $profileStartupTimer.ElapsedMilliseconds

$env:EDITOR = 'nvim'
$env:BAT_THEME = 'ansi'

# Prompt: starship with the same starship.toml as hypr-mac
if (Test-Command starship) { Invoke-Expression (Get-ShellInit starship @('init', 'powershell', '--print-full-init')) }
$profileStartupMarks['Starship'] = $profileStartupTimer.ElapsedMilliseconds

# fzf: Ctrl+R history, Ctrl+T insert file, Alt+C cd into dir
if ((Test-Command fzf) -and (Get-Module -ListAvailable PSFzf)) {
	if (Test-Command fd) {
		$env:FZF_DEFAULT_COMMAND = 'fd --type f --hidden --exclude .git'
		$env:FZF_CTRL_T_COMMAND = $env:FZF_DEFAULT_COMMAND
		$env:FZF_ALT_C_COMMAND = 'fd --type d --hidden --exclude .git'
	}
	# Defer module initialization until a shortcut is used, then replace these handlers.
	function Initialize-PsFzf {
		Import-Module PSFzf -Global -ArgumentList 'Ctrl+t', 'Ctrl+r', 'Alt+c', 'Alt+a' -ErrorAction Stop
	}
	Set-PSReadLineKeyHandler -Key Ctrl+t -BriefDescription 'Fzf Provider Select' -ScriptBlock {
		Initialize-PsFzf
		Invoke-FzfPsReadlineHandlerProvider
	}
	Set-PSReadLineKeyHandler -Key Ctrl+r -BriefDescription 'Fzf Reverse History Select' -ScriptBlock {
		Initialize-PsFzf
		Invoke-FzfPsReadlineHandlerHistory
	}
	Set-PSReadLineKeyHandler -Key Alt+c -BriefDescription 'Fzf Set Location' -ScriptBlock {
		Initialize-PsFzf
		Invoke-FzfPsReadlineHandlerSetLocation
	}
	Set-PSReadLineKeyHandler -Key Alt+a -BriefDescription 'Fzf Reverse History Arg Select' -ScriptBlock {
		Initialize-PsFzf
		Invoke-FzfPsReadlineHandlerHistoryArgs
	}
}

# File system
$profileStartupMarks['Fzf'] = $profileStartupTimer.ElapsedMilliseconds
if (Test-Command eza) {
	Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
	function ls { eza -lh --group-directories-first --icons=auto @args }
	function lsa { ls -a @args }
	function lt { eza --tree --level=2 --long --icons --git @args }
	function lta { lt -a @args }
}
function ff { fzf --preview 'bat --style=numbers --color=always {}' @args }
function eff { $file = ff; if ($file) { & $env:EDITOR $file } }
# sff host:/dest = pick a file (newest first) and scp it there
function sff {
	if (-not $args) { Write-Host 'Usage: sff <destination> (e.g. sff host:/tmp/)'; return }
	$file = Get-ChildItem -File -Recurse | Sort-Object LastWriteTime -Descending | ForEach-Object { [IO.Path]::GetRelativePath($PWD, $_.FullName) } | ff
	if ($file) { scp $file $args[0] }
}

# cd falls back to zoxide (cd proj jumps to the most used dir matching "proj"); z, zi work too
$profileStartupMarks['FileSystem'] = $profileStartupTimer.ElapsedMilliseconds
if (Test-Command zoxide) {
	Invoke-Expression (Get-ShellInit zoxide @('init', 'powershell'))
	Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue
	function cd {
		if (-not $args) { Set-Location ~ }
		elseif ($args.Count -eq 1 -and ($args[0] -eq '-' -or $args[0] -eq '+' -or (Test-Path -LiteralPath $args[0] -PathType Container))) { Set-Location $args[0] }
		else {
			z @args
			if ($?) { Write-Host "$([char]::ConvertFromUtf32(0xF17A9)) $PWD" } else { Write-Host 'Error: Directory not found' }
		}
	}
	$profileStartupMarks['Zoxide'] = $profileStartupTimer.ElapsedMilliseconds
}

function .. { Set-Location .. }
function ... { Set-Location ../.. }
function .... { Set-Location ../../.. }

# Tools
function n { if ($args) { nvim @args } else { nvim . } }
# stay cmd... = run detached from the terminal
function stay {
	$rest = @($args | Select-Object -Skip 1)
	if ($rest) { Start-Process -FilePath $args[0] -ArgumentList $rest -WindowStyle Hidden }
	else { Start-Process -FilePath $args[0] -WindowStyle Hidden }
}

# Git
Set-Alias g git
Remove-Item Alias:gcm -Force -ErrorAction SilentlyContinue
function gcm { git commit -m @args }
function gcam { git commit -a -m @args }
function gcad { git commit -a --amend @args }
# ga branch = new branch in worktree ../<repo>--<branch>; gd (inside it) = remove worktree and branch
function ga {
	if (-not $args) { Write-Host 'Usage: ga [branch name]'; return }
	$wtPath = "../$(Split-Path -Leaf $PWD)--$($args[0])"
	git worktree add -b $args[0] $wtPath
	if ($?) { Set-Location $wtPath }
}
function gd {
	if ((Read-Host 'Remove worktree and branch? [y/N]') -notmatch '^[yY]') { return }
	$cwd = $PWD.Path
	$worktree = Split-Path -Leaf $cwd
	$root, $branch = $worktree -split '--', 2
	# Protect against accidentally nuking a non-worktree directory
	if ($branch) {
		Set-Location "../$root"
		git worktree remove $cwd --force
		if ($?) { git branch -D $branch }
	}
}

# Compression
function compress { $dir = $args[0].TrimEnd('/', '\'); tar -czf "$dir.tar.gz" $dir }
function decompress { tar -xzf @args }

# Machine-local overrides, not in the repo
$localProfile = Join-Path (Split-Path $PROFILE) 'profile.local.ps1'
$profileStartupMarks['Shortcuts'] = $profileStartupTimer.ElapsedMilliseconds
if (Test-Path $localProfile) { . $localProfile }
$profileStartupMarks['LocalOverrides'] = $profileStartupTimer.ElapsedMilliseconds

# Record the actual terminal's timings, not just non-interactive benchmark results.
$profileStartupDirectory = Join-Path $env:LOCALAPPDATA 'ryha-config\PowerShell'
$null = [IO.Directory]::CreateDirectory($profileStartupDirectory)
$profileStartupTemp = Join-Path $profileStartupDirectory "startup-$([guid]::NewGuid()).tmp"
try {
	$profileStartupPrevious = 0
	$profileStartupStages = [ordered]@{}
	foreach ($profileStartupEntry in $profileStartupMarks.GetEnumerator()) {
		$profileStartupStages[$profileStartupEntry.Key] = $profileStartupEntry.Value - $profileStartupPrevious
		$profileStartupPrevious = $profileStartupEntry.Value
	}
	$profileStartupReport = @{
		TimeUtc = [DateTime]::UtcNow.ToString('o')
		ProcessId = $PID
		HostName = $Host.Name
		PowerShellVersion = $PSVersionTable.PSVersion.ToString()
		PSReadLineAlreadyLoaded = $profileStartupReadLineLoaded
		TotalMs = $profileStartupTimer.ElapsedMilliseconds
		StagesMs = $profileStartupStages
	} | ConvertTo-Json
	[IO.File]::WriteAllText($profileStartupTemp, $profileStartupReport)
	[IO.File]::Move($profileStartupTemp, (Join-Path $profileStartupDirectory 'last-startup.json'), $true)
} finally {
	if ([IO.File]::Exists($profileStartupTemp)) { [IO.File]::Delete($profileStartupTemp) }
}
Remove-Variable profileStartupTimer, profileStartupMarks, profileStartupReadLineLoaded, profileStartupDirectory, profileStartupTemp, profileStartupPrevious, profileStartupStages, profileStartupEntry, profileStartupReport
