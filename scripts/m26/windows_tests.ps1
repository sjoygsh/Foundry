# Focused harness refusals, against an output whose null-debug evidence already exists.
param(
    [Parameter(Mandatory=$true)][string]$Harness,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference = 'Stop'
function global:Get-Counter {
    [pscustomobject]@{CounterSamples=@([pscustomobject]@{CookedValue=51})}
}
# A broken refusal must still never start an actual build during this test.
function global:Start-Process { throw 'Unexpected child launch' }
function Expect-Refusal([scriptblock]$Code, [string]$Pattern) {
    try { & $Code; throw 'Unexpected acceptance' } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
}
try {
    $source = [IO.File]::ReadAllText((Resolve-Path $Harness).Path)
    $normal = [scriptblock]::Create($source)
    Expect-Refusal { & $normal -Repo $Repo -Zig $Zig -Output $Output } '50 percent cutoff'
    Expect-Refusal { & $normal -Repo $Repo -Zig $Zig -Output $Output -IgnoreCpuLimit } 'Stale evidence: null-debug'
    $cpu_broken = [scriptblock]::Create($source.Replace("if (`$cpu -gt 50)", 'if ($false)'))
    Expect-Refusal {
        Expect-Refusal { & $cpu_broken -Repo $Repo -Zig $Zig -Output $Output } '50 percent cutoff'
    } 'Stale evidence: null-debug'
    $stale_broken = [scriptblock]::Create($source.Replace('if ((Test-Path $stdout) -or (Test-Path $stderr))', 'if ($false)'))
    Expect-Refusal {
        Expect-Refusal { & $stale_broken -Repo $Repo -Zig $Zig -Output $Output -IgnoreCpuLimit } 'Stale evidence: null-debug'
    } 'Unexpected child launch'
    Write-Output 'Harness refusals: 2/2 passed; both guard mutations failed as intended; no child launched.'
} finally {
    Remove-Item Function:Get-Counter
    Remove-Item Function:Start-Process
}
