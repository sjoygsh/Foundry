# M26 Step 6 developer qualification. Desktop mode needs the owner's permission.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    [switch]$IgnoreCpuLimit
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
$current = [Diagnostics.Process]::GetCurrentProcess()
$current.PriorityClass = 'BelowNormal'
if (-not $IgnoreCpuLimit) { $current.ProcessorAffinity = [IntPtr]3 }
function Assert-Idle {
    if ($IgnoreCpuLimit) { return }
    $cpu = ((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples |
        Measure-Object CookedValue -Maximum).Maximum
    if ($cpu -gt 50) { throw 'PC exceeds the 50 percent cutoff' }
}
function Run-Child([string]$Name, [string]$Exe, [string]$Arguments, [string]$Directory) {
    Assert-Idle
    $stdout = Join-Path $Output "$Name.out.log"
    $stderr = Join-Path $Output "$Name.err.log"
    if ((Test-Path $stdout) -or (Test-Path $stderr)) { throw "Stale evidence: $Name" }
    $start = @{ FilePath=$Exe; WorkingDirectory=$Directory; PassThru=$true;
        RedirectStandardOutput=$stdout; RedirectStandardError=$stderr }
    if ($Arguments) { $start.ArgumentList = $Arguments }
    $child = Start-Process @start
    try {
        $null = $child.Handle
        $child.PriorityClass = 'BelowNormal'
        $deadline = [DateTime]::UtcNow.AddMinutes(30)
        while (-not $child.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Deadline: $Name" }
            Assert-Idle
        }
        $child.WaitForExit()
        if ($child.ExitCode -ne 0) { throw "$Name exited $($child.ExitCode); see $stderr" }
    } finally {
        if (-not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
        $child.Dispose()
    }
    Write-Output "$Name passed"
}
Assert-Idle
[IO.Directory]::CreateDirectory($Output) | Out-Null
$env:PATH = "C:\VulkanSDK\1.4.357.0\Bin;$env:PATH"
$env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
# Elevated SSH ignores the loader filter; disable the installed implicit layers themselves.
$env:DISABLE_RTSS_LAYER = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_overlay_1 = '1'
$env:DISABLE_VK_LAYER_VALVE_steam_fossilize_1 = '1'
$env:VK_LOADER_DEBUG = 'layer'
if ($Mode -eq 'build') {
    Run-Child 'null-debug' $Zig 'build test -Dplatform=null -Drhi=null -j2 --summary all' $Repo
    Run-Child 'null-release' $Zig 'build court-test -Dplatform=null -Drhi=null -Doptimize=ReleaseSafe -j2 --summary all' $Repo
    Run-Child 'vulkan-debug' $Zig 'build test vulkan-test -Drhi=vulkan -j2 --summary all' $Repo
    Run-Child 'vulkan-release' $Zig 'build court-test render3d-test -Drhi=vulkan -Doptimize=ReleaseSafe -j2 --summary all' $Repo
    Run-Child 'install' $Zig "build install -Drhi=vulkan -Doptimize=ReleaseSafe -j2 --summary all --prefix `"$(Join-Path $Output 'stage')`"" $Repo
    $relocated = Join-Path $Output 'relocated'
    if (Test-Path $relocated) { throw 'Stale relocated install' }
    Move-Item (Join-Path $Output 'stage') $relocated
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Get-ChildItem $relocated -File -Recurse | ForEach-Object {
        "$($_.FullName.Substring($relocated.Length)) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
    } | Sort-Object | Set-Content (Join-Path $Output 'installed.sha256')
    Write-Output 'Native build qualification finished. Desktop launches require owner permission.'
    exit 0
}

Run-Child 'native-window' $Zig 'build native-window-test -Drhi=vulkan -j2 --summary all' $Repo
Run-Child 'vulkan-window' $Zig 'build vulkan-window-test -Drhi=vulkan -j2 --summary all' $Repo
$relocated = Join-Path $Output 'relocated'
$exe = Join-Path $relocated 'bin\court.exe'
if (-not (Test-Path $exe)) { throw 'Relocated court missing' }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:FOUNDRY_COURT_WORKERS = '0'
$env:FOUNDRY_COURT_PACKAGES = ''
Remove-Item Env:FOUNDRY_COURT_FRAMES -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_OVERLAY -ErrorAction SilentlyContinue
# Private scratch user-data roots, not the player's ambient mods or preferences.
$env:APPDATA = Join-Path $Output 'user'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
[IO.Directory]::CreateDirectory($env:APPDATA) | Out-Null
[IO.Directory]::CreateDirectory($env:FOUNDRY_COURT_SAVE_DIR) | Out-Null
foreach ($layers in @('validation','off')) {
    if ($layers -eq 'validation') {
        $env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
        $env:VK_INSTANCE_LAYERS = 'VK_LAYER_KHRONOS_validation'
        $env:VK_LAYER_SETTINGS_PATH = $Output
    } else {
        $env:VK_LOADER_LAYERS_DISABLE = '~all~'
        Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
        Remove-Item Env:VK_LAYER_SETTINGS_PATH -ErrorAction SilentlyContinue
    }
    foreach ($play in @('win','caught','fell')) {
        $name = "$layers-$play"
        @('khronos_validation.validate_sync = true',
          'khronos_validation.report_flags = error,warn,info',
          "khronos_validation.log_filename = $(Join-Path $Output "$name.validation.log")") |
            Set-Content (Join-Path $Output 'vk_layer_settings.txt') -Encoding ASCII
        $env:FOUNDRY_COURT_PLAY = $play
        Run-Child $name $exe '' $relocated
        $text = Get-Content (Join-Path $Output "$name.err.log") -Raw
        if ($text -notmatch 'replay: \d+ tick hashes matched a fresh simulation' -or
            $text -notmatch 'stopped after \d+ frames \(0 skipped\)' -or
            $text -notmatch '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped') {
            throw "Incomplete play evidence: $name"
        }
        $validation = Join-Path $Output "$name.validation.log"
        if ($layers -eq 'validation') {
            if (-not (Test-Path $validation)) { throw "Validation log absent: $name" }
            if (Select-String -Path $validation -Pattern 'Validation Error|Validation Warning|VUID-|SYNC-HAZARD' -Quiet) {
                throw "Validation not clean: $name"
            }
        }
    }
}
Remove-Item Env:FOUNDRY_COURT_PLAY
$after = Get-ChildItem $relocated -File -Recurse | ForEach-Object {
    "$($_.FullName.Substring($relocated.Length)) $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)"
} | Sort-Object
if (Compare-Object (Get-Content (Join-Path $Output 'installed.sha256')) $after) { throw 'Install changed' }
if (Get-ChildItem $env:FOUNDRY_COURT_SAVE_DIR) { throw 'Scripted run wrote preferences' }
Write-Output 'Play-throughs passed. Pointer capture/focus-loss proof and pack-up remain explicit.'
