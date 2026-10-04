# Step 5 stages only. Native suites, desktop runs and validation belong to Step 6.
param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output,
    [Parameter(Mandatory=$true)][string]$Revision
)
$ErrorActionPreference = 'Stop'
$process = [Diagnostics.Process]::GetCurrentProcess()
$process.PriorityClass = 'BelowNormal'
$process.ProcessorAffinity = [IntPtr]3
$Repo = (Resolve-Path $Repo).Path
$Zig = (Resolve-Path $Zig).Path
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path $Output) { throw 'Output must be fresh' }

function Assert-Idle {
    $cpu = ((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples |
        Measure-Object CookedValue -Maximum).Maximum
    Write-Output "CPU maximum: $cpu percent"
    if ($cpu -gt 50) { throw 'PC exceeds the 50 percent cutoff' }
}
Assert-Idle
[IO.Directory]::CreateDirectory($Output) | Out-Null
$env:PATH = "C:\VulkanSDK\1.4.357.0\Bin;$env:PATH"
$stdout = Join-Path $Output 'stage.out.log'
$stderr = Join-Path $Output 'stage.err.log'
# Set the compiler's affinity at launch, before it can spawn its build/compiler children.
# This avoids relying on a late affinity assignment or Start-Process's inheritance.
$child = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -WorkingDirectory $Repo -PassThru `
    -ArgumentList "/d /c start `"`" /b /wait /belownormal /affinity 3 `"$Zig`" build dist -Dapp=court -Dplatform=sdl3 -Drhi=vulkan -Doptimize=ReleaseSafe -Drevision=$Revision -j2 --summary all" `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
try {
    $null = $child.Handle
    Write-Output "Build PID: $($child.Id)"
    $child.PriorityClass = 'BelowNormal'
    $child.ProcessorAffinity = [IntPtr]3
    $deadline = [DateTime]::UtcNow.AddMinutes(25)
    while (-not $child.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Stage deadline' }
        Assert-Idle
    }
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw "Stage exited $($child.ExitCode); see stage.err.log" }
} finally {
    if (-not $child.HasExited) {
        # Kill the task's compiler tree too, not merely the build runner.
        & taskkill.exe /PID $child.Id /T /F | Out-Null
    }
    $child.Dispose()
}
$artifact = Join-Path $Repo 'zig-out\dist\court\Foundry Court-windows-x64.zip'
Copy-Item $artifact (Join-Path $Output 'Foundry Court-windows-x64.zip')
Get-FileHash $artifact -Algorithm SHA256
Write-Output 'Unsigned Windows court release staged. No desktop process launched.'
