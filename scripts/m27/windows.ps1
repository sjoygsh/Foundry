# M27 Step 10: background loading and building on Windows/Vulkan (background.md §12, §13).
# `build` runs the native suites over SSH; `desktop` runs in the desktop session, from a
# scheduled task, and measures the relocated install. Desktop mode needs the owner's permission.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    # Use only when the owner explicitly suspends the standing CPU cutoff.
    [switch]$IgnoreCpuLimit
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
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
    Run-Child 'vulkan-debug' $Zig @('build','test','vulkan-test','editor-workflow','-Drhi=vulkan','-j2','--summary','line') $Repo
    Run-Child 'vulkan-release' $Zig @('build','court-test','render3d-test','model-content-test','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line') $Repo
    Run-Child 'install' $Zig @('build','install','-Drhi=vulkan','-Doptimize=ReleaseSafe','-j2','--summary','line','--prefix',(Join-Path $Output 'stage')) $Repo
    $relocated = Join-Path $Output 'relocated'
    if (Test-Path $relocated) { throw 'Stale relocated install' }
    Move-Item (Join-Path $Output 'stage') $relocated
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Hash-Tree $relocated | Set-Content (Join-Path $Output 'installed.sha256')
    Write-Output 'Native suites and relocated install finished. Desktop launches require owner permission.'
    exit 0
}

Run-Child 'native-window' $Zig @('build','native-window-test','-Drhi=vulkan','-j2','--summary','line') $Repo
Run-Child 'vulkan-window' $Zig @('build','vulkan-window-test','-Drhi=vulkan','-j2','--summary','line') $Repo
$relocated = Join-Path $Output 'relocated'
$bin = Join-Path $relocated 'bin'
foreach ($exe in @('sandbox3d.exe','court.exe','foundry-editor.exe')) {
    if (-not (Test-Path (Join-Path $bin $exe))) { throw "Relocated $exe missing" }
}
$source = Join-Path $Repo 'samples\sandbox3d\content'
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Private scratch user-data roots, not the player's ambient mods or preferences.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_SANDBOX3D_SAVE_DIR = Join-Path $Output 'sandbox3d-saves'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
foreach ($dir in @($env:APPDATA, $env:FOUNDRY_SANDBOX3D_SAVE_DIR, $env:FOUNDRY_COURT_SAVE_DIR)) {
    [IO.Directory]::CreateDirectory($dir) | Out-Null
}

# §12: the gallery, ReleaseSafe, API validation off, the same binary, alternated three times.
$env:FOUNDRY_SANDBOX3D_FRAMES = '300'
foreach ($run in 1..3) {
    foreach ($load in @('sync','background')) {
        $name = "gallery-$load$run"
        Set-Layers 'off' $name
        $env:FOUNDRY_SANDBOX3D_LOAD = $load
        Run-Child $name (Join-Path $bin 'sandbox3d.exe') $null $relocated 5
        Expect-Lines $name @('gallery: request to ready', 'gallery: frame work', 'stopped after 300 frames \(0 skipped\)')
    }
}
# And once each way under synchronization validation: the claim is validation-clean.
foreach ($load in @('sync','background')) {
    $name = "gallery-$load-validation"
    Set-Layers 'validation' $name
    $env:FOUNDRY_SANDBOX3D_LOAD = $load
    Run-Child $name (Join-Path $bin 'sandbox3d.exe') $null $relocated 5
    Expect-Lines $name @('gallery: frame work', 'stopped after 300 frames \(0 skipped\)')
    Assert-Clean 'validation' $name
}
Remove-Item Env:FOUNDRY_SANDBOX3D_LOAD

# The editor proof: a build of sandbox3d's package, inline against background, alternated.
$editor = Join-Path $bin 'foundry-editor.exe'
$core = Join-Path $relocated 'content\core.fpk'
$plans = Join-Path $Output 'plans'
[IO.Directory]::CreateDirectory($plans) | Out-Null
@('idle','idle','idle','idle','click build','wait','idle','idle','idle','idle','idle') |
    Set-Content (Join-Path $plans 'build.txt') -Encoding ASCII
@('idle','idle','idle','idle','click first_document','click first_record','click build','click field',
  'write 1','click field_apply','wait','idle','idle') | Set-Content (Join-Path $plans 'edit.txt') -Encoding ASCII
function Run-Editor([string]$Name, [string]$Plan, [string]$Tasks, [string]$Layers) {
    $work = Join-Path $Output "editor\$Name"
    Copy-Item $source (Join-Path $work 'src') -Recurse
    Set-Layers $Layers $Name
    if ($Tasks) { $env:FOUNDRY_EDITOR_TASKS = $Tasks } else { Remove-Item Env:FOUNDRY_EDITOR_TASKS -ErrorAction SilentlyContinue }
    Run-Child $Name $editor @('--source',(Join-Path $work 'src'),'--output',(Join-Path $work 'out'),
        '--dependency',$core,'--plan',(Join-Path $plans $Plan)) $relocated 5
    Assert-Clean $Layers $Name
}
foreach ($run in 1..3) {
    Run-Editor "editor-inline$run" 'build.txt' 'inline' 'off'
    Run-Editor "editor-background$run" 'build.txt' '' 'off'
}
Run-Editor 'editor-edit' 'edit.txt' '' 'off'
Run-Editor 'editor-background-validation' 'build.txt' '' 'validation'
Remove-Item Env:FOUNDRY_EDITOR_TASKS -ErrorAction SilentlyContinue

# The plays, unchanged: sandbox3d's tour and the court's three endings, validation then off.
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
    Expect-Lines $name @('tour: pass', 'tour: walker pass')
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
if (Compare-Object (Get-Content (Join-Path $Output 'installed.sha256')) (Hash-Tree $relocated)) { throw 'Install changed' }
if (Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR) { throw 'Scripted run wrote preferences' }
Write-Output 'Desktop proofs passed.'
