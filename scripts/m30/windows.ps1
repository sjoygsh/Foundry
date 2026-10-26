# M30 Step 8: the court's soundtrack on Windows/Vulkan (music.md §1, §11, §12).
# `build` runs the native suites over SSH and stages a relocated, read-only ReleaseSafe install;
# `desktop` runs in the desktop session, from a scheduled task, where the audio device is the
# player's, and measures that install.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    # Where a desktop run writes its logs, if not beside the install in $Output: so a second
    # attempt keeps the first's evidence and reuses its install.
    [string]$Evidence = '',
    # Only these court runs (by name), for a second attempt at one that was interrupted.
    [string[]]$Only = @(),
    # Use only when the owner explicitly suspends the standing CPU cutoff.
    [switch]$IgnoreCpuLimit
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
$Install = $Output
if ($Evidence) { $Output = [IO.Path]::GetFullPath($Evidence) }
$current = [Diagnostics.Process]::GetCurrentProcess()
$current.PriorityClass = 'BelowNormal'
function Assert-Idle {
    if ($IgnoreCpuLimit) { return }
    $cpu = ((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples |
        Measure-Object CookedValue -Maximum).Maximum
    if ($cpu -gt 50) { throw 'PC exceeds the 50 percent cutoff' }
}
function Run-Child([string]$Name, [string]$Exe, [string[]]$Arguments, [string]$Directory, [int]$Minutes = 40, [switch]$AllowFail) {
    $stdout = Join-Path $Output "$Name.out.log"
    $stderr = Join-Path $Output "$Name.err.log"
    # A rerun after a later failure keeps what already passed, and its evidence.
    $passed = Join-Path $Output "$Name.passed"
    if (Test-Path $passed) { Write-Output "$Name passed earlier"; return }
    if ((Test-Path $stdout) -or (Test-Path $stderr)) { throw "Stale evidence: $Name" }
    $start = @{ FilePath=$Exe; WorkingDirectory=$Directory; PassThru=$true;
        RedirectStandardOutput=$stdout; RedirectStandardError=$stderr }
    if ($Arguments) { $start.ArgumentList = $Arguments }
    $began = [DateTime]::UtcNow
    $child = Start-Process @start
    try {
        $null = $child.Handle
        $child.PriorityClass = 'BelowNormal'
        $deadline = $began.AddMinutes($Minutes)
        while (-not $child.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Deadline: $Name" }
        }
        $child.WaitForExit()
        if ($child.ExitCode -ne 0) {
            if (-not $AllowFail) { throw "$Name exited $($child.ExitCode); see $stderr" }
            Write-Output "$Name exited $($child.ExitCode); its failures are read from $stderr"
            return
        }
    } finally {
        if (-not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
        $child.Dispose()
    }
    $line = "{0} passed in {1:n0} s" -f $Name, ([DateTime]::UtcNow - $began).TotalSeconds
    Set-Content $passed $line
    Write-Output $line
}
function Set-Layers([string]$Layers, [string]$Name) {
    if ($Layers -eq 'validation') {
        $env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
        $env:VK_INSTANCE_LAYERS = 'VK_LAYER_KHRONOS_validation'
        $env:VK_LAYER_SETTINGS_PATH = $Output
        @('khronos_validation.validate_sync = true',
          'khronos_validation.report_flags = error,warn,info',
          "khronos_validation.log_filename = $(Join-Path $Output "$Name.validation.log")") |
            Set-Content (Join-Path $Output 'vk_layer_settings.txt') -Encoding ASCII
    } else {
        $env:VK_LOADER_LAYERS_DISABLE = '~all~'
        Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
        Remove-Item Env:VK_LAYER_SETTINGS_PATH -ErrorAction SilentlyContinue
    }
}
function Assert-Clean([string]$Layers, [string]$Name) {
    if ($Layers -ne 'validation') { return }
    $validation = Join-Path $Output "$Name.validation.log"
    if (-not (Test-Path $validation)) { throw "Validation log absent: $Name" }
    if (Select-String -Path $validation -Pattern 'Validation Error|Validation Warning|VUID-|SYNC-HAZARD' -Quiet) {
        throw "Validation not clean: $Name"
    }
}
function Expect-Lines([string]$Name, [string[]]$Patterns) {
    $text = Get-Content (Join-Path $Output "$Name.err.log") -Raw
    foreach ($pattern in $Patterns) {
        if ($text -notmatch $pattern) { throw "Incomplete evidence: $Name lacks '$pattern'" }
    }
}
function Hash-Tree([string]$Root) {
    Get-ChildItem $Root -File -Recurse | ForEach-Object {
        "$($_.FullName.Substring($Root.Length)) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object
}
Assert-Idle
[IO.Directory]::CreateDirectory($Output) | Out-Null
$env:PATH = "C:\VulkanSDK\1.4.357.0\Bin;$env:PATH"
$env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
# Elevated SSH ignores the loader filter; disable the installed implicit layers themselves.
$env:DISABLE_RTSS_LAYER = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_overlay_1 = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_fossilize_1 = '1'
if ($Mode -eq 'build') {
    # The Vulkan test binaries require validation, synchronization included, themselves (AGENTS.md).
    Run-Child 'null-debug' $Zig @('build','test','-Dplatform=null','-Drhi=null','-j2','--summary','line') $Repo
    Run-Child 'vulkan-debug' $Zig @('build','test','vulkan-test','-Drhi=vulkan','-j2','--summary','line') $Repo
    # Criterion 1's speed and the full 2,000-flip sweep, and the court's tests, optimized as a
    # release is.
    Run-Child 'release' $Zig @('build','asset-test','court-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo
    # The stream margin (§6.2). The integration binary also holds the ui_theme test that fails
    # in ReleaseSafe alone (Step 5's Resolution), so its failures are read from the log rather
    # than taken from the exit code.
    Run-Child 'release-integration' $Zig @('build','integration-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo -AllowFail
    Run-Child 'install' $Zig @('build','install','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line','--prefix',(Join-Path $Output 'stage')) $Repo
    $relocated = Join-Path $Output 'relocated'
    if (Test-Path $relocated) { throw 'Stale relocated install' }
    Move-Item (Join-Path $Output 'stage') $relocated
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Hash-Tree $relocated | Set-Content (Join-Path $Output 'installed.sha256')
    Write-Output 'Native suites and relocated install finished.'
    exit 0
}

# §8.4's command delivery on the player's own device: the release integration test again, in
# the desktop session, where WASAPI's endpoint is the one a player hears.
$failed = @()
if (-not $Only) {
    Run-Child 'delivery' $Zig @('build','integration-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo -AllowFail
    try { Expect-Lines 'delivery' @('command delivery \(ReleaseSafe\)') } catch { Write-Output "FAILED delivery : $_"; $failed += 'delivery' }
}
$relocated = Join-Path $Install 'relocated'
$bin = Join-Path $relocated 'bin'
$court = Join-Path $bin 'court.exe'
if (-not (Test-Path $court)) { throw 'Relocated court.exe missing' }
if (-not (Test-Path (Join-Path $relocated 'content\nocturne.fpk'))) { throw 'Relocated nocturne missing' }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Private scratch user-data roots, not the player's ambient mods or preferences.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
foreach ($dir in @($env:APPDATA, $env:FOUNDRY_COURT_SAVE_DIR)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
}
$env:FOUNDRY_COURT_MUSIC_LOG = 'on'
Remove-Item Env:FOUNDRY_COURT_WORKERS -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_FRAMES -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_OVERLAY -ErrorAction SilentlyContinue
# Criteria 2 and 3 are the run's own exit: a scripted run fails unless every start landed and
# nothing underran, started late, dropped or was refused. These lines are what it measured.
$clean = '0 underrun\(s\), 0 late start\(s\), 0 command\(s\) dropped, 0 refused'
$ending = @('replay: \d+ tick hashes matched a fresh simulation', 'stopped after \d+ frames \(0 skipped\)',
    '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped', "music at exit: \d+ start\(s\) asked, \d+ on their frame, 0 missed, \d+ retired before they began, 0 unread, \d+ pending; $clean")
$soundtrack = $ending + @("play 'soundtrack': (\d+) of \1 step\(s\)", 'cost audio \(Mixer\.update and Music\.update')
# name, script, packages, layers. Three ten-minute runs off validation and one under it
# (criteria 2-4), nocturne's (criterion 6), then the endings (criterion 7).
$runs = @(
    @('soundtrack1','soundtrack','','off'),
    @('soundtrack2','soundtrack','','off'),
    @('soundtrack3','soundtrack','','off'),
    @('soundtrack-validation','soundtrack','','validation'),
    @('nocturne','soundtrack','nocturne:content','off'),
    @('nocturne-win','win','nocturne:content','validation'),
    @('validation-win','win','','validation'),
    @('validation-caught','caught','','validation'),
    @('validation-fell','fell','','validation'),
    @('off-win','win','','off'),
    @('off-caught','caught','','off'),
    @('off-fell','fell','','off')
)
foreach ($run in $runs) {
    $name, $play, $packages, $layers = $run
    if ($Only -and ($Only -notcontains $name)) { continue }
    try {
        Assert-Idle
        Set-Layers $layers $name
        $env:FOUNDRY_COURT_PLAY = $play
        $env:FOUNDRY_COURT_PACKAGES = $packages
        Run-Child $name $court $null $relocated 20
        if ($play -eq 'soundtrack') { Expect-Lines $name $soundtrack } else { Expect-Lines $name $ending }
        if ($packages) { Expect-Lines $name @('found nocturne:content version 1', 'resolved 3 packages', '1 selected package\(s\)') }
        Assert-Clean $layers $name
    } catch {
        Write-Output "FAILED $name : $_"
        $failed += $name
    }
}
Remove-Item Env:FOUNDRY_COURT_PLAY -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_PACKAGES -ErrorAction SilentlyContinue
if (Compare-Object (Get-Content (Join-Path $Install 'installed.sha256')) (Hash-Tree $relocated)) { throw 'Install changed' }
if (Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR) { throw 'Scripted run wrote preferences' }
if ($failed) { throw "Court runs failed: $($failed -join ', ')" }
Write-Output 'Desktop proofs passed.'
