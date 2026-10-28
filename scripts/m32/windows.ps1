# M32 Step 8: navigation on Windows/Vulkan (navigation.md §1's criteria 4-6, §11, §12).
# `build` runs the native suites over SSH and stages a relocated, read-only ReleaseSafe install;
# `desktop` runs in the desktop session, from a scheduled task, and runs both samples from that
# install with the mesh shown.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    # Where a desktop run writes its logs, if not beside the install in $Output: so a second
    # attempt keeps the first's evidence and reuses its install.
    [string]$Evidence = '',
    # Only these sample runs (by name), for a second attempt at one that was interrupted.
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
    # Criterion 4's course pin, which `nav-test` asserts, and criterion 5's two real levels,
    # optimized as a release is and printed.
    Run-Child 'release' $Zig @('build','nav-test','sandbox3d-test','court-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo
    Expect-Lines 'release' @('court navigation build \(ReleaseSafe\): [\d.]+ ms', 'sandbox3d navigation build \(ReleaseSafe\): [\d.]+ ms',
        'nav build time \(ReleaseSafe\): course')
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

$relocated = Join-Path $Install 'relocated'
$bin = Join-Path $relocated 'bin'
foreach ($exe in @('sandbox3d.exe','court.exe')) {
    if (-not (Test-Path (Join-Path $bin $exe))) { throw "Relocated $exe missing" }
}
foreach ($package in @('plinth.fpk','stout.fpk')) {
    if (-not (Test-Path (Join-Path $relocated "content\$package"))) { throw "Relocated $package missing" }
}
$sandbox3d = Join-Path $bin 'sandbox3d.exe'
$court = Join-Path $bin 'court.exe'
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Private scratch user-data roots, not the player's ambient mods or preferences.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_SANDBOX3D_SAVE_DIR = Join-Path $Output 'sandbox3d-saves'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
foreach ($dir in @($env:APPDATA, $env:FOUNDRY_SANDBOX3D_SAVE_DIR, $env:FOUNDRY_COURT_SAVE_DIR)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
}
foreach ($name in @('FOUNDRY_SANDBOX3D_WORKERS','FOUNDRY_SANDBOX3D_LOAD','FOUNDRY_SANDBOX3D_WALK','FOUNDRY_SANDBOX3D_GENERATE',
    'FOUNDRY_SANDBOX3D_OVERLAY','FOUNDRY_COURT_WORKERS','FOUNDRY_COURT_FRAMES','FOUNDRY_COURT_OVERLAY','FOUNDRY_COURT_PLAY')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
# A failed request, build or view is said, never silent; none may appear.
function Expect-Quiet([string]$Name) {
    $log = Join-Path $Output "$Name.err.log"
    if (Select-String -Path $log -Pattern 'navigation: no build|did not start|the build failed|navigation view|navigation source .* omitted' -Quiet) {
        throw "Navigation warned: $Name"
    }
}
$failed = @()
# §9.1: the walker's mesh, built at load and again at a reload at frame 300, drawn throughout.
# Three runs shown and three off, the baseline for criterion 5's load frame; then plinth's cut
# and stout's agent; then plinth again under synchronization validation (criterion 6).
$env:FOUNDRY_SANDBOX3D_FRAMES = '600'
$env:FOUNDRY_SANDBOX3D_KEYS = 'r@300'
$built = @('navigation: \d+ polygons, \d+ regions, \d+ detail triangles, 0 skipped; request to arrival [\d.]+ms',
    'r: reloading every package', 'navigation: frame work .* over \d+ frames from the request', 'stopped after 600 frames \(0 skipped\)')
$sandboxRuns = @(
    @('sandbox-show1','show','','off'), @('sandbox-off1','off','','off'),
    @('sandbox-show2','show','','off'), @('sandbox-off2','off','','off'),
    @('sandbox-show3','show','','off'), @('sandbox-off3','off','','off'),
    @('sandbox-plinth','show','plinth:content','off'),
    @('sandbox-stout','show','stout:content','off'),
    @('sandbox-validation','show','plinth:content','validation')
)
foreach ($run in $sandboxRuns) {
    $name, $nav, $packages, $layers = $run
    if ($Only -and ($Only -notcontains $name)) { continue }
    try {
        Assert-Idle
        Set-Layers $layers $name
        $env:FOUNDRY_SANDBOX3D_NAV = $nav
        if ($packages) { $env:FOUNDRY_SANDBOX3D_PACKAGES = $packages } else { Remove-Item Env:FOUNDRY_SANDBOX3D_PACKAGES -ErrorAction SilentlyContinue }
        Run-Child $name $sandbox3d $null $relocated 5
        if ($nav -eq 'off') {
            Expect-Lines $name @('navigation: off; measuring the same frames with no build', 'stopped after 600 frames \(0 skipped\)')
        } else { Expect-Lines $name $built }
        if ($packages) { Expect-Lines $name @("enabling '$packages'") }
        Expect-Quiet $name
        Assert-Clean $layers $name
    } catch {
        Write-Output "FAILED $name : $_"
        $failed += $name
    }
}
Remove-Item Env:FOUNDRY_SANDBOX3D_FRAMES, Env:FOUNDRY_SANDBOX3D_KEYS, Env:FOUNDRY_SANDBOX3D_NAV -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_SANDBOX3D_PACKAGES -ErrorAction SilentlyContinue

# §9.2: the warden's mesh, built once at load. The three endings with the mesh shown, under
# validation and off; then three 300-frame runs of each mode at the title, criterion 5's load.
$env:FOUNDRY_COURT_PACKAGES = ''
$warden = 'navigation: \d+ polygons, \d+ detail triangles, 0 skipped; request to arrival [\d.]+ms'
$ending = @($warden, 'replay: \d+ tick hashes matched a fresh simulation', 'stopped after \d+ frames \(0 skipped\)',
    '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped')
$courtRuns = @(
    @('court-validation-win','win','show','validation'), @('court-validation-caught','caught','show','validation'),
    @('court-validation-fell','fell','show','validation'),
    @('court-win','win','show','off'), @('court-caught','caught','show','off'), @('court-fell','fell','show','off'),
    @('court-show1','','show','off'), @('court-off1','','off','off'),
    @('court-show2','','show','off'), @('court-off2','','off','off'),
    @('court-show3','','show','off'), @('court-off3','','off','off')
)
foreach ($run in $courtRuns) {
    $name, $play, $nav, $layers = $run
    if ($Only -and ($Only -notcontains $name)) { continue }
    try {
        Assert-Idle
        Set-Layers $layers $name
        $env:FOUNDRY_COURT_NAV = $nav
        if ($play) {
            $env:FOUNDRY_COURT_PLAY = $play
            Remove-Item Env:FOUNDRY_COURT_FRAMES -ErrorAction SilentlyContinue
        } else {
            Remove-Item Env:FOUNDRY_COURT_PLAY -ErrorAction SilentlyContinue
            $env:FOUNDRY_COURT_FRAMES = '300'
        }
        Run-Child $name $court $null $relocated 10
        if ($play) { Expect-Lines $name $ending }
        elseif ($nav -eq 'off') { Expect-Lines $name @('navigation: off; measuring the same frames with no build', 'navigation: frame work over \d+ frames from the request', 'stopped after 300 frames \(0 skipped\)') }
        else { Expect-Lines $name @($warden, 'navigation: frame work over \d+ frames from the request', 'stopped after 300 frames \(0 skipped\)') }
        Expect-Quiet $name
        Assert-Clean $layers $name
    } catch {
        Write-Output "FAILED $name : $_"
        $failed += $name
    }
}
Remove-Item Env:FOUNDRY_COURT_PLAY, Env:FOUNDRY_COURT_FRAMES, Env:FOUNDRY_COURT_NAV, Env:FOUNDRY_COURT_PACKAGES -ErrorAction SilentlyContinue
if (Compare-Object (Get-Content (Join-Path $Install 'installed.sha256')) (Hash-Tree $relocated)) { throw 'Install changed' }
if (Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR) { throw 'Scripted run wrote preferences' }
if ($failed) { throw "Sample runs failed: $($failed -join ', ')" }
Write-Output 'Desktop proofs passed.'
