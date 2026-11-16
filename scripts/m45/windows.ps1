# M45 Step 9: input on Windows/Vulkan (input.md §13, Step 9), from M41's and M40's.
# `build` runs the native suites, the null one and the Vulkan one, the pins on x86_64 at ReleaseSafe
# (the court's four M40 digests in `court-test`, the input sequence's 0x003888cb676c2786 in
# `input-test`, the bindings file in `app-test`, v8's calls in `abi-test`), and stages a relocated,
# read-only ReleaseSafe install whose content hashes the Mac compares.
# `desktop` runs unattended in the desktop session, from a scheduled task, with no physical pad
# plugged in: `gamepad-test`, `audio-output-test` and `native-window-test` from the clone, then the
# court from the install, its three endings with a virtual pad and without, the catch's rumble, the
# title for the `input` span, and `southpaw` selected.
# `person` needs a person at the PC, with a pad plugged in and a second audio output (headphones):
# §3's motion, three sweeps in a window (`native-window-test` under FOUNDRY_MOTION_MINUTES), then the
# court played, rebound, an output chosen and unplugged mid-music, quit, and played again to see the
# rebinding kept. Its logs are read into a checklist; what the person did not do is said, not failed.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop','person')][string]$Mode = 'build',
    # Where a desktop or person run writes its logs, if not beside the install in $Output: so a
    # second attempt keeps the first's evidence and reuses its install.
    [string]$Evidence = '',
    # Only these runs (by name), for a second attempt at one that was interrupted.
    [string[]]$Only = @(),
    # Use only when the owner explicitly suspends the standing CPU cutoff.
    [switch]$IgnoreCpuLimit,
    # Normal only when the owner explicitly asks for it; the PC is theirs to play on.
    [ValidateSet('BelowNormal','Normal')][string]$Priority = 'BelowNormal'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
$Install = $Output
if ($Evidence) { $Output = [IO.Path]::GetFullPath($Evidence) }
$current = [Diagnostics.Process]::GetCurrentProcess()
$current.PriorityClass = $Priority
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
        $child.PriorityClass = $Priority
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
function Log-Text([string]$Name) { Get-Content (Join-Path $Output "$Name.err.log") -Raw }
function Expect-Lines([string]$Name, [string[]]$Patterns) {
    $text = Log-Text $Name
    foreach ($pattern in $Patterns) {
        if ($text -notmatch $pattern) { throw "Incomplete evidence: $Name lacks '$pattern'" }
    }
}
function Expect-Absent([string]$Name, [string[]]$Patterns) {
    $text = Log-Text $Name
    foreach ($pattern in $Patterns) {
        if ($text -match $pattern) { throw "Unwanted evidence: $Name has '$pattern'" }
    }
}
function Hash-Tree([string]$Root) {
    Get-ChildItem $Root -File -Recurse | ForEach-Object {
        "$($_.FullName.Substring($Root.Length)) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object
}
function Selected([string]$Name) { return (-not $Only) -or ($Only -contains $Name) }
Assert-Idle
[IO.Directory]::CreateDirectory($Output) | Out-Null
$env:PATH = "C:\VulkanSDK\1.4.357.0\Bin;$env:PATH"
$env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
# Elevated SSH ignores the loader filter; disable the installed implicit layers themselves.
$env:DISABLE_RTSS_LAYER = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_overlay_1 = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_fossilize_1 = '1'
Remove-Item Env:FOUNDRY_MOTION_MINUTES, Env:SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS -ErrorAction SilentlyContinue
if ($Mode -eq 'build') {
    # The Vulkan test binaries require validation, synchronization included, themselves (AGENTS.md).
    Run-Child 'null-debug' $Zig @('build','test','-Dplatform=null','-Drhi=null','-j2','--summary','line') $Repo 120
    Run-Child 'vulkan-debug' $Zig @('build','test','vulkan-test','-Drhi=vulkan','-j2','--summary','line') $Repo 120
    # The pins on x86_64, optimized as a release is (§13): the court's four digests, the input
    # sequence's digest, the bindings file and the table's input calls.
    Run-Child 'release' $Zig @('build','court-test','input-test','app-test','abi-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo 120
    Run-Child 'install' $Zig @('build','install','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line','--prefix',(Join-Path $Output 'stage')) $Repo 120
    $relocated = Join-Path $Output 'relocated'
    if (Test-Path $relocated) { throw 'Stale relocated install' }
    Move-Item (Join-Path $Output 'stage') $relocated
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Hash-Tree $relocated | Set-Content (Join-Path $Output 'installed.sha256')
    Write-Output 'Native suites and relocated install finished.'
    return
}

$relocated = Join-Path $Install 'relocated'
$court = Join-Path $relocated 'bin\court.exe'
if (-not (Test-Path $court)) { throw 'Relocated court.exe missing' }
$failed = @()
$notes = @()

# The clone's own SDL3 desktop tests, before the samples' PATH is narrowed, since Zig builds them.
$tests = @()
if ($Mode -eq 'desktop') {
    $tests = @(
        # Skips, and so fails here, while a physical pad is plugged in: it would take slot 0.
        @('gamepad-test', @('Build Summary: \d+/\d+ steps succeeded; 3/3 tests passed'), @('a physical pad is connected')),
        # Prints counts, never names; a second output (headphones) makes the moves real ones.
        @('audio-output-test', @('Build Summary: \d+/\d+ steps succeeded; 1/1 tests passed', 'audio-output-test: \d+ output\(s\), [01] marked default', 'audio-output-test: moved to \d+ of \d+, \d+ frames pulled'), @()),
        # The motion test skips unattended; the rest are M13's windows.
        @('native-window-test', @('Build Summary: \d+/\d+ steps succeeded; \d+/\d+ tests passed'), @('motion-test:'))
    )
} else {
    # §3's motion: a window waits up to twenty minutes for a person's three sweeps (raw, system, raw).
    $tests = @(, @('motion', @('motion-test: sweep 1 \(raw\): unit counts', 'motion-test: sweep 2 \(system\): unit points',
        'motion-test: sweep 3 \(raw\): unit counts', 'motion-test: system travel is [\d.]+ times', 'Build Summary: \d+/\d+ steps succeeded; \d+/\d+ tests passed'), @()))
}
foreach ($test in $tests) {
    $name, $want, $unwanted = $test
    if (-not (Selected $name)) { continue }
    try {
        Assert-Idle
        $step = if ($name -eq 'motion') { 'native-window-test' } else { $name }
        if ($name -eq 'motion') { $env:FOUNDRY_MOTION_MINUTES = '20' }
        Run-Child $name $Zig @('build',$step,'-Drhi=vulkan','-j2','--summary','line') $Repo 30
        Remove-Item Env:FOUNDRY_MOTION_MINUTES -ErrorAction SilentlyContinue
        Expect-Lines $name $want
        if ($unwanted) { Expect-Absent $name $unwanted }
        if ($name -eq 'motion') {
            $notes += (Select-String -Path (Join-Path $Output 'motion.err.log') -Pattern '^motion-test: ' | ForEach-Object { $_.Line })
        }
        if ($name -eq 'audio-output-test') {
            $notes += (Select-String -Path (Join-Path $Output 'audio-output-test.err.log') -Pattern '^audio-output-test: ' | ForEach-Object { $_.Line })
        }
    } catch {
        Remove-Item Env:FOUNDRY_MOTION_MINUTES -ErrorAction SilentlyContinue
        Write-Output "FAILED $name : $_"
        $failed += $name
    }
}

$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Private scratch user-data roots, not the player's ambient mods, settings or bindings: the
# bindings file is `%APPDATA%\foundry-court\bindings.fset`, the settings `settings.fset` in the save dir.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
foreach ($dir in @($env:APPDATA, $env:FOUNDRY_COURT_SAVE_DIR)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
foreach ($name in @('FOUNDRY_COURT_NAV','FOUNDRY_COURT_PACKAGES','FOUNDRY_COURT_WORKERS','FOUNDRY_COURT_FRAMES',
    'FOUNDRY_COURT_OVERLAY','FOUNDRY_COURT_PLAY','FOUNDRY_COURT_PAD','FOUNDRY_COURT_MUSIC_LOG')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$bindings = Join-Path $env:APPDATA 'foundry-court\bindings.fset'
# A failed request, build, view, pad or bindings file is said, never silent; none may appear.
$quiet = @('navigation: no build', 'did not start', 'the build failed', 'navigation view', 'navigation source .* omitted',
    'pad: no virtual pad', 'SDL could not start gamepads', 'bindings: ', 'controls: the new bindings were refused',
    'controls: the bindings were not saved')
# `§` may read back as two characters under Windows PowerShell's default encoding.
$inputCost = 'cost input \(events, the snapshot and the court''s actions; input\.md .{1,2}13\): \d+ frames, median [\d.]+ms p95 [\d.]+ms; budget 0\.05ms'
$frameCost = 'cost frame work \(no pacing sleep, image acquire or present; includes scripted replay\): \d+ frames, median [\d.]+ms p95 [\d.]+ms'

if ($Mode -eq 'desktop') {
    # The court's three endings, with a virtual pad seated and without (§11, Step 8), each with its
    # replay, its sky and the `input` span; the catch rumbles the PlayStation pad at 0.6 and 0.9.
    $warden = 'navigation: \d+ polygons, \d+ detail triangles, 2 links, 0 skipped; request to arrival [\d.]+ms'
    $ending = @($warden, 'replay: \d+ tick hashes matched a fresh simulation', 'stopped after \d+ frames \(0 skipped\)',
        '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped', $frameCost, $inputCost,
        'environment: [1-9]\d* of \d+ frames drew content\(0x[0-9a-f]+\)''s sky',
        'music at exit: \d+ start\(s\) asked, \d+ on their frame, 0 missed, \d+ retired before they began, 0 unread, \d+ pending; 0 underrun\(s\), 0 late start\(s\), 0 command\(s\) dropped, 0 refused')
    $rumble = 'pad: 1 rumble\(s\) reached the pad, the last at 39321 and 58982 of 65535'
    $courtRuns = @(
        # name, play, frames, pad, packages, layers
        @('court-win-xbox-validation','win','','xbox','','validation'),
        @('court-caught-playstation','caught','','playstation','','off'),
        @('court-fell-xbox','fell','','xbox','','off'),
        @('court-win','win','','','','off'),
        @('court-caught','caught','','','','off'),
        @('court-fell','fell','','','','off'),
        # The title, held for 900 frames with a pad seated: the `input` span without a script.
        @('court-title-xbox','','900','xbox','','off'),
        @('court-title-xbox-validation','','900','xbox','','validation'),
        # Southpaw selected over a pad: content that rebinds by override loads and runs clean.
        @('court-southpaw-xbox','','600','xbox','southpaw:content','off')
    )
    foreach ($run in $courtRuns) {
        $name, $play, $frames, $pad, $packages, $layers = $run
        if (-not (Selected $name)) { continue }
        try {
            Assert-Idle
            Set-Layers $layers $name
            foreach ($var in @('FOUNDRY_COURT_PLAY','FOUNDRY_COURT_FRAMES','FOUNDRY_COURT_PAD','SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS')) {
                Remove-Item "Env:$var" -ErrorAction SilentlyContinue
            }
            $env:FOUNDRY_COURT_NAV = 'show'
            $env:FOUNDRY_COURT_PACKAGES = $packages
            if ($play) { $env:FOUNDRY_COURT_PLAY = $play }
            if ($frames) { $env:FOUNDRY_COURT_FRAMES = $frames }
            if ($pad) {
                $env:FOUNDRY_COURT_PAD = $pad
                # SDL drops pad events while no window of the process is focused (Step 7).
                $env:SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS = '1'
            }
            Run-Child $name $court $null $relocated 10
            if ($play) {
                $word = if ($play -eq 'win') { 'won' } else { $play }
                Expect-Lines $name ($ending + "phase $word at tick \d+")
            } else {
                Expect-Lines $name @("stopped after $frames frames \(0 skipped\)", $frameCost, $inputCost)
            }
            if ($pad) { Expect-Lines $name @("pad: a virtual $pad pad is attached") }
            if ($name -eq 'court-caught-playstation') { Expect-Lines $name @($rumble) }
            if ($packages) { Expect-Lines $name @('1 selected package\(s\)') } else { Expect-Lines $name @('0 selected package\(s\)') }
            Expect-Absent $name $quiet
            Assert-Clean $layers $name
            $notes += (Select-String -Path (Join-Path $Output "$name.err.log") -Pattern 'cost (input|frame work)' | ForEach-Object { "${name}: $($_.Line)" })
        } catch {
            Write-Output "FAILED $name : $_"
            $failed += $name
        }
    }
    foreach ($var in @('FOUNDRY_COURT_PLAY','FOUNDRY_COURT_FRAMES','FOUNDRY_COURT_PAD','FOUNDRY_COURT_NAV','FOUNDRY_COURT_PACKAGES','SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS')) {
        Remove-Item "Env:$var" -ErrorAction SilentlyContinue
    }
    # A run nobody plays writes nothing: no settings, no bindings, no remembered panels.
    # (The court's own folder only: a driver may keep a cache of its own under APPDATA.)
    $courtData = Join-Path $env:APPDATA 'foundry-court'
    if ((Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR -File -Recurse) -or ((Test-Path $courtData) -and (Get-ChildItem $courtData -File -Recurse))) {
        throw 'Scripted run wrote user data'
    }
} else {
    # The court, played by a person with a real pad (no virtual one, no background events), twice
    # over the same private user data: the second launch shows whether the rebinding was kept.
    Set-Layers 'off' 'play'
    $env:FOUNDRY_COURT_PACKAGES = ''
    $checks = @(
        @('an ending reached', 'phase (won|caught|fell) at tick \d+'),
        @('an action rebound and saved', 'controls: \d+ action\(s\) rebound, bindings written'),
        @('an output chosen', 'audio: output [1-9]\d* of \d+ chosen'),
        @('the chosen output lost', 'audio: the chosen output went away; following the system default'),
        @('no music start late', 'music at exit: .* 0 missed, .* 0 underrun\(s\), 0 late start\(s\)'),
        @('the input span', $inputCost),
        @('frame work', $frameCost)
    )
    foreach ($name in @('play1','play2')) {
        if (-not (Selected $name)) { continue }
        try {
            Assert-Idle
            $before = if (Test-Path $bindings) { (Get-FileHash $bindings -Algorithm SHA256).Hash } else { 'absent' }
            Run-Child $name $court $null $relocated 120
            $after = if (Test-Path $bindings) { (Get-FileHash $bindings -Algorithm SHA256).Hash } else { 'absent' }
            $notes += "${name}: bindings.fset $before before, $after after"
            if ($name -eq 'play2' -and $before -eq 'absent') { $notes += 'play2: no rebinding was saved by play1, so a kept one cannot be seen' }
            $text = Log-Text $name
            foreach ($check in $checks) {
                $what, $pattern = $check
                $found = [regex]::Matches($text, $pattern) | ForEach-Object { $_.Value } | Select-Object -Last 1
                $notes += $(if ($found) { "${name}: yes, ${what}: $found" } else { "${name}: NOT SEEN, $what" })
            }
            $notes += (Select-String -Path (Join-Path $Output "$name.err.log") -Pattern 'stopped after \d+ frames|audio: |controls: |music at exit' | ForEach-Object { "${name}: $($_.Line)" })
            # Read after the checklist, so a warning still leaves what the person did on record.
            Expect-Absent $name $quiet
        } catch {
            Write-Output "FAILED $name : $_"
            $failed += $name
        }
    }
    if (Test-Path $bindings) { Copy-Item $bindings (Join-Path $Output 'bindings.fset') -Force }
    Remove-Item Env:FOUNDRY_COURT_PACKAGES -ErrorAction SilentlyContinue
}
if (Compare-Object (Get-Content (Join-Path $Install 'installed.sha256')) (Hash-Tree $relocated)) { throw 'Install changed' }
$notes | Set-Content (Join-Path $Output "$Mode.notes.txt")
$notes | ForEach-Object { Write-Output $_ }
if ($failed) { throw "Runs failed: $($failed -join ', ')" }
Write-Output "$Mode proofs passed."
