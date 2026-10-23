# M28 Step 7: runtime geometry on Windows/Vulkan (runtime-geometry.md §1, §10).
# `build` runs the native suites over SSH and stages a relocated, read-only ReleaseSafe install;
# `desktop` runs in the desktop session, from a scheduled task, and measures that install.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    # Where a desktop run writes its logs, if not beside the install in $Output: so a second
    # attempt keeps the first's evidence and reuses its install.
    [string]$Evidence = '',
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
function Run-Child([string]$Name, [string]$Exe, [string[]]$Arguments, [string]$Directory, [int]$Minutes = 40) {
    $stdout = Join-Path $Output "$Name.out.log"
    $stderr = Join-Path $Output "$Name.err.log"
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
        if ($child.ExitCode -ne 0) { throw "$Name exited $($child.ExitCode); see $stderr" }
    } finally {
        if (-not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
        $child.Dispose()
    }
    Write-Output ("{0} passed in {1:n0} s" -f $Name, ([DateTime]::UtcNow - $began).TotalSeconds)
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
    Run-Child 'vulkan-release' $Zig @('build','render3d-test','sandbox3d-test','model-content-test','court-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo
    Run-Child 'install' $Zig @('build','install','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line','--prefix',(Join-Path $Output 'stage')) $Repo
    $relocated = Join-Path $Output 'relocated'
    if (Test-Path $relocated) { throw 'Stale relocated install' }
    Move-Item (Join-Path $Output 'stage') $relocated
    # A writable copy for the one run that edits a texture under it (criterion 5).
    Copy-Item $relocated (Join-Path $Output 'reloadable') -Recurse
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Hash-Tree $relocated | Set-Content (Join-Path $Output 'installed.sha256')
    Write-Output 'Native suites and relocated install finished.'
    exit 0
}

Run-Child 'native-window' $Zig @('build','native-window-test','-Drhi=vulkan','-j2','--summary','line') $Repo
Run-Child 'vulkan-window' $Zig @('build','vulkan-window-test','-Drhi=vulkan','-j2','--summary','line') $Repo
$relocated = Join-Path $Install 'relocated'
$bin = Join-Path $relocated 'bin'
foreach ($exe in @('sandbox3d.exe','court.exe')) {
    if (-not (Test-Path (Join-Path $bin $exe))) { throw "Relocated $exe missing" }
}
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Private scratch user-data roots, not the player's ambient mods or preferences.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_SANDBOX3D_SAVE_DIR = Join-Path $Output 'sandbox3d-saves'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
foreach ($dir in @($env:APPDATA, $env:FOUNDRY_SANDBOX3D_SAVE_DIR, $env:FOUNDRY_COURT_SAVE_DIR)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
}

# §1 criteria 1-3: the corner, ReleaseSafe, validation off, the same binary, alternated three
# times, the gallery off so its load is not in the window.
$env:FOUNDRY_SANDBOX3D_FRAMES = '600'
$env:FOUNDRY_SANDBOX3D_LOAD = 'off'
$env:FOUNDRY_SANDBOX3D_PAINT = 'auto'
$corner = @('landmark: request to ready', 'landmark: frame work', 'water: \d+ updates', 'canvas: \d+ stamps', 'stopped after 600 frames \(0 skipped\)')
foreach ($run in 1..3) {
    foreach ($generate in @('background','inline')) {
        $name = "corner-$generate$run"
        Set-Layers 'off' $name
        $env:FOUNDRY_SANDBOX3D_GENERATE = $generate
        Run-Child $name (Join-Path $bin 'sandbox3d.exe') $null $relocated 5
        Expect-Lines $name $corner
    }
}
# The water's inline baseline, once.
$env:FOUNDRY_SANDBOX3D_GENERATE = 'background'
$env:FOUNDRY_SANDBOX3D_WATER = 'inline'
Set-Layers 'off' 'water-inline'
Run-Child 'water-inline' (Join-Path $bin 'sandbox3d.exe') $null $relocated 5
# The log is UTF-8 and this reads it as the system code page, so "129²" is matched loosely.
Expect-Lines 'water-inline' @('water: \d+ updates of 129.+ vertices \(inline\)')
Remove-Item Env:FOUNDRY_SANDBOX3D_WATER
# Criterion 7: each landmark path, and the pooled water, under synchronization validation.
foreach ($generate in @('background','inline')) {
    $name = "corner-$generate-validation"
    Set-Layers 'validation' $name
    $env:FOUNDRY_SANDBOX3D_GENERATE = $generate
    Run-Child $name (Join-Path $bin 'sandbox3d.exe') $null $relocated 5
    Expect-Lines $name $corner
    Assert-Clean 'validation' $name
}
# Criterion 5: the recoloured crate's texture replaced under a writable copy, then R.
$reloadable = Join-Path $Install 'reloadable'
$crate = Join-Path $reloadable 'content\sandbox3d\models\crate.png'
$brick = Join-Path $reloadable 'content\sandbox3d\models\brick.png'
$env:FOUNDRY_SANDBOX3D_GENERATE = 'background'
$env:FOUNDRY_SANDBOX3D_FRAMES = '420'
$env:FOUNDRY_SANDBOX3D_KEYS = 'r@300'
Remove-Item Env:FOUNDRY_SANDBOX3D_PAINT
Set-Layers 'validation' 'recolour'
$replace = Start-Job -ScriptBlock { param($from, $to) Start-Sleep -Seconds 3; Copy-Item $from $to -Force } -ArgumentList $brick, $crate
Run-Child 'recolour' (Join-Path $reloadable 'bin\sandbox3d.exe') $null $reloadable 5
Receive-Job $replace -Wait | Out-Null
Expect-Lines 'recolour' @('r: reloading every package', 'recolour: material \d+\.\d+ kept, binding texture')
Assert-Clean 'validation' 'recolour'
Remove-Item Env:FOUNDRY_SANDBOX3D_KEYS
Remove-Item Env:FOUNDRY_SANDBOX3D_GENERATE
Remove-Item Env:FOUNDRY_SANDBOX3D_LOAD

# Criterion 6: sandbox3d's tour and the court's three endings, validation then off.
Remove-Item Env:FOUNDRY_SANDBOX3D_FRAMES
$env:FOUNDRY_COURT_WORKERS = '0'
$env:FOUNDRY_COURT_PACKAGES = ''
Remove-Item Env:FOUNDRY_COURT_FRAMES -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_OVERLAY -ErrorAction SilentlyContinue
foreach ($layers in @('validation','off')) {
    $name = "$layers-tour"
    Set-Layers $layers $name
    $env:FOUNDRY_SANDBOX3D_WALK = 'tour'
    Run-Child $name (Join-Path $bin 'sandbox3d.exe') $null $relocated 10
    Expect-Lines $name @('tour: pass', 'tour: walker pass', 'player hash cb99ccfcf2b6d6c3')
    Assert-Clean $layers $name
    Remove-Item Env:FOUNDRY_SANDBOX3D_WALK
    foreach ($play in @('win','caught','fell')) {
        $name = "$layers-$play"
        Set-Layers $layers $name
        $env:FOUNDRY_COURT_PLAY = $play
        Run-Child $name (Join-Path $bin 'court.exe') $null $relocated 10
        Expect-Lines $name @('replay: \d+ tick hashes matched a fresh simulation', 'stopped after \d+ frames \(0 skipped\)',
            '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped')
        Assert-Clean $layers $name
    }
}
Remove-Item Env:FOUNDRY_COURT_PLAY
if (Compare-Object (Get-Content (Join-Path $Install 'installed.sha256')) (Hash-Tree $relocated)) { throw 'Install changed' }
if (Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR) { throw 'Scripted run wrote preferences' }
Write-Output 'Desktop proofs passed.'
