# Run only in the logged-in desktop after permission. This is an OS-level capture
# proof, not a person's play/feel report and not a private engine test interface.
param(
    [Parameter(Mandatory=$true)][string]$Install,
    [Parameter(Mandatory=$true)][string]$Output,
    [switch]$IgnoreCpuLimit
)
$ErrorActionPreference = 'Stop'
$current = [Diagnostics.Process]::GetCurrentProcess()
$current.PriorityClass = 'BelowNormal'
if (-not $IgnoreCpuLimit) { $current.ProcessorAffinity = [IntPtr]3 }
function Assert-Idle {
    if ($IgnoreCpuLimit) { return }
    $cpu = ((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples |
        Measure-Object CookedValue -Maximum).Maximum
    if ($cpu -gt 50) { throw 'PC exceeds the 50 percent cutoff' }
}
Assert-Idle
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CourtWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct Cursor { public int size, flags; public IntPtr handle; public Point position; }
    [DllImport("user32.dll")] public static extern bool GetClipCursor(out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref Cursor cursor);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}
'@
$Install = (Resolve-Path $Install).Path
$Output = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory($Output) | Out-Null
$stdout = Join-Path $Output 'capture.out.log'
$stderr = Join-Path $Output 'capture.err.log'
if ((Test-Path $stdout) -or (Test-Path $stderr)) { throw 'Stale capture evidence' }
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
$env:VK_LOADER_LAYERS_DISABLE = '~all~'
Remove-Item Env:VK_INSTANCE_LAYERS -ErrorAction SilentlyContinue
Remove-Item Env:FOUNDRY_COURT_PLAY -ErrorAction SilentlyContinue
$env:FOUNDRY_COURT_WORKERS = '0'
$env:FOUNDRY_COURT_PACKAGES = ''
Remove-Item Env:FOUNDRY_COURT_OVERLAY -ErrorAction SilentlyContinue
$env:FOUNDRY_COURT_FRAMES = '3600'
$env:FOUNDRY_COURT_SAVE_DIR = Join-Path $Output 'preferences'
$env:APPDATA = Join-Path $Output 'user'
$child = Start-Process -FilePath (Join-Path $Install 'bin\court.exe') -WorkingDirectory $Install -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$other = $null
function Captured {
    $clip = New-Object CourtWindow+Rect
    $rect = New-Object CourtWindow+Rect
    $cursor = New-Object CourtWindow+Cursor
    $cursor.size = [Runtime.InteropServices.Marshal]::SizeOf($cursor)
    if (-not [CourtWindow]::GetClipCursor([ref]$clip) -or
        -not [CourtWindow]::GetWindowRect($script:window, [ref]$rect) -or
        -not [CourtWindow]::GetCursorInfo([ref]$cursor)) { throw 'Capture readback failed' }
    return (($cursor.flags -band 1) -eq 0 -and
        $clip.left -ge $rect.left -and $clip.right -le $rect.right -and
        $clip.top -ge $rect.top -and $clip.bottom -le $rect.bottom)
}
function Expect-Capture([bool]$Want, [string]$Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Assert-Idle
        [Windows.Forms.Application]::DoEvents()
        if ((Captured) -eq $Want) { Write-Output "$Name passed"; return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$Name did not reach capture=$Want"
}
function Focus-Court {
    $null = [CourtWindow]::SetForegroundWindow($script:window)
    Start-Sleep -Milliseconds 200
    if ([CourtWindow]::GetForegroundWindow() -ne $script:window) { throw 'Court did not get focus' }
}
try {
    $null = $child.Handle
    $child.PriorityClass = 'BelowNormal'
    $other = New-Object System.Windows.Forms.Form
    $other.Text = 'Foundry capture focus-loss proof'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $child.Refresh()
        $script:window = $child.MainWindowHandle
        if ($script:window -ne [IntPtr]::Zero -and $child.MainWindowTitle -eq 'Foundry Court') { break }
        if ($child.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Court window absent' }
        Start-Sleep -Milliseconds 100
    } while ($true)
    Focus-Court
    Expect-Capture $false 'Title releases pointer'
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Expect-Capture $true 'Playing hides and confines pointer'
    [Windows.Forms.SendKeys]::SendWait('{ESC}')
    Expect-Capture $false 'Pause releases pointer'
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Expect-Capture $true 'Resume captures pointer'
    $other.Show()
    $other.Activate()
    $null = [CourtWindow]::SetForegroundWindow($other.Handle)
    Start-Sleep -Milliseconds 200
    if ([CourtWindow]::GetForegroundWindow() -ne $other.Handle) { throw 'Focus-loss fixture did not get focus' }
    Expect-Capture $false 'Focus loss releases pointer'
    Focus-Court
    Expect-Capture $false 'Regaining focus does not capture'
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Expect-Capture $true 'Explicit resume after focus loss captures'
    $null = [CourtWindow]::PostMessage($script:window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $child.WaitForExit(10000)) { throw 'Court did not close' }
    $child.WaitForExit()
    if ($child.ExitCode -ne 0) { throw "Court exited $($child.ExitCode)" }
    Write-Output 'Seven OS-level capture checks passed. No human play report claimed.'
} finally {
    if ($other) { $other.Dispose() }
    if (-not $child.HasExited) { $child.Kill() }
    $child.Dispose()
}
