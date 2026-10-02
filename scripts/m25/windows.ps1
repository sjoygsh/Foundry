# Developer qualification for M25 Step 6, not a build prerequisite or release tool.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateSet('build','desktop')][string]$Mode = 'build',
    [string]$Evidence,
    [switch]$ValidatedOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# -j2 bounds build jobs, not a compiler's internal threads. Children inherit this
# two-logical-processor affinity, keeping the owner's wider PC available.
$current = [Diagnostics.Process]::GetCurrentProcess()
$current.PriorityClass = 'BelowNormal'
$current.ProcessorAffinity = [IntPtr]3
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory($Output) | Out-Null

function Assert-Idle {
    # Win32_Processor.LoadPercentage gave 93 while the actual total CPU counter
    # measured 33–34 on the qualified PC. Use measured utilization, not that label.
    $load = ((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples |
        Measure-Object CookedValue -Maximum).Maximum
    if ($load -gt 50) { throw "PC CPU $load percent exceeds the 50 percent cutoff" }
}
function Run-Child([string]$Name, [string]$Exe, [string]$Arguments, [string]$Directory) {
    Assert-Idle
    $stdout = Join-Path $Output "$Name.out.log"
    $stderr = Join-Path $Output "$Name.err.log"
    if ((Test-Path $stdout) -or (Test-Path $stderr)) { throw "Stale output: $Name" }
    $start = @{ FilePath=$Exe; WorkingDirectory=$Directory; PassThru=$true; RedirectStandardOutput=$stdout; RedirectStandardError=$stderr }
    if ($Arguments) { $start.ArgumentList = $Arguments }
    $process = Start-Process @start
    try {
        # Acquire the handle before exit; Windows PowerShell otherwise can lose
        # the exit status of a short-lived redirected child.
        $null = $process.Handle
        $process.PriorityClass = 'BelowNormal'
        $deadline = [DateTime]::UtcNow.AddMinutes(20)
        while (-not $process.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Deadline: $Name" }
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "$Name exited $($process.ExitCode); see $stderr" }
    } finally {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
    Write-Output "$Name passed"
}

if ($Mode -eq 'build') {
    $env:PATH = "C:\VulkanSDK\1.4.357.0\Bin;$env:PATH"
    $env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
    # SSH may be elevated: the installed implicit layers' own refusal variables.
    $env:DISABLE_RTSS_LAYER = '1'
    $env:DISABLE_VK_LAYER_VALVE_steam_overlay_1 = '1'
    $env:DISABLE_VK_LAYER_VALVE_steam_fossilize_1 = '1'
    $env:VK_LOADER_DEBUG = 'layer'
    Run-Child 'null-debug' $Zig 'build abi-test abi-public3d-test sandbox3d-test -Dplatform=null -Drhi=null -j2 --summary all' $Repo
    Run-Child 'null-release' $Zig 'build abi-test abi-public3d-test sandbox3d-test -Dplatform=null -Drhi=null -Doptimize=ReleaseSafe -j2 --summary all' $Repo
    Run-Child 'vulkan-release' $Zig 'build sandbox3d-test -Drhi=vulkan -Doptimize=ReleaseSafe -j2 --summary all' $Repo
    $stage = Join-Path $Output 'stage'
    $relocated = Join-Path $Output 'relocated'
    if ((Test-Path $stage) -or (Test-Path $relocated)) { throw 'Stale install' }
    Run-Child 'install' $Zig "build install -Drhi=vulkan -Doptimize=ReleaseSafe -j2 --summary all --prefix `"$stage`"" $Repo
    Move-Item $stage $relocated
    if (-not (Test-Path "$relocated\content\orbiter\orbiter.dll")) { throw 'Package-local orbiter.dll absent' }
    # Deny write/delete even through inherited group grants; keep read/execute.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # Deny specific mutation rights. Generic W also denies shared control rights
    # needed by CreateProcess, so it is not a usable read-only runtime policy.
    & icacls $relocated /deny "${identity}:(OI)(CI)(WD,AD,WA,WEA,DC,DE)" /T /Q
    if ($LASTEXITCODE -ne 0) { throw 'Read-only ACL failed' }
    Write-Output 'Build qualification complete; desktop runs still require owner permission.'
    exit 0
}

$relocated = Join-Path $Output 'relocated'
$executable = Join-Path $relocated 'bin\sandbox3d.exe'
if (-not (Test-Path $executable)) { throw 'Relocated install absent' }
if ($Evidence) {
    $Output = [IO.Path]::GetFullPath($Evidence)
    [IO.Directory]::CreateDirectory($Output) | Out-Null
}
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:FOUNDRY_SANDBOX3D_PACKAGES = 'plinth:content,orbiter:content'
$env:FOUNDRY_SANDBOX3D_NATIVE = 'orbiter:content'
$env:FOUNDRY_SANDBOX3D_OVERLAY = '0'
$env:FOUNDRY_SANDBOX3D_WORKERS = '0'
$env:FOUNDRY_SANDBOX3D_WALK = 'tour'
$env:VK_LOADER_DEBUG = 'layer'
$tourCount = if ($ValidatedOnly) { 2 } else { 3 }
for ($index = 0; $index -lt $tourCount; $index++) {
    $homePath = Join-Path $Output "user-$index"
    [IO.Directory]::CreateDirectory($homePath) | Out-Null
    $env:APPDATA = $homePath
    $env:HOME = $homePath
    $trace = Join-Path $Output "poses-$index.bin"
    if (Test-Path $trace) { throw "Stale trace: $trace" }
    $env:FOUNDRY_SANDBOX3D_NATIVE_TRACE = $trace
    if ($index -lt 2) {
        @('khronos_validation.validate_sync = true',
          'khronos_validation.report_flags = error,warn,info',
          "khronos_validation.log_filename = $(Join-Path $Output "validation-$index.log")") |
            Set-Content (Join-Path $Output 'vk_layer_settings.txt') -Encoding ASCII
        $env:VK_LOADER_LAYERS_DISABLE = '~implicit~'
        $env:VK_INSTANCE_LAYERS = 'VK_LAYER_KHRONOS_validation'
        $env:VK_LAYER_SETTINGS_PATH = $Output
    } else {
        $env:VK_LOADER_LAYERS_DISABLE = '~all~'
        Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
        Remove-Item Env:VK_LAYER_SETTINGS_PATH -ErrorAction SilentlyContinue
    }
    Run-Child "tour-$index" $executable '' $relocated
    $text = (Get-Content (Join-Path $Output "tour-$index.err.log") -Raw) + (Get-Content (Join-Path $Output "tour-$index.out.log") -Raw)
    foreach ($marker in @('tour: plinth pass','tour: orbiter pass','tour: replay pass','tour: walker pass','cb99ccfcf2b6d6c3')) {
        if (-not $text.Contains($marker)) { throw "Tour $index missing $marker" }
    }
    if ($text -notmatch 'stopped after \d+ frames \(0 skipped\)') { throw "Tour $index skipped frames" }
    if ((Get-Item $trace).Length -ne 69120) { throw "Incomplete trace $index" }
}
$first = [IO.File]::ReadAllBytes((Join-Path $Output 'poses-0.bin'))
foreach ($index in (1..($tourCount - 1))) {
    $other = [IO.File]::ReadAllBytes((Join-Path $Output "poses-$index.bin"))
    for ($byte = 0; $byte -lt $first.Length; $byte++) {
        if ($first[$byte] -ne $other[$byte]) { throw "Replay $index differs at byte $byte" }
    }
}
Write-Output "Fresh-process native replay: 69120 bytes identical ($tourCount processes)."
if ($ValidatedOnly) { exit 0 }
Remove-Item Env:FOUNDRY_SANDBOX3D_NATIVE_TRACE
Remove-Item Env:FOUNDRY_SANDBOX3D_WALK
$env:FOUNDRY_SANDBOX3D_INSTANCES = '1024'
$env:FOUNDRY_SANDBOX3D_FRAMES = '300'
$costHome = Join-Path $Output 'user-cost'
[IO.Directory]::CreateDirectory($costHome) | Out-Null
$env:APPDATA = $costHome
$env:HOME = $costHome
Run-Child 'cost-1024' $executable '' $relocated
Write-Output 'Desktop qualification finished; inspect validation logs and timings, then remove task/worktree artifacts.'
