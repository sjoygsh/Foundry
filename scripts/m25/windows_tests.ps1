# Focused harness refusals; point at an already-qualified install/output. No child
# should launch: injected load and existing evidence must refuse before Start-Process.
param(
    [Parameter(Mandatory=$true)][string]$Harness,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Zig,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference = 'Stop'
$global:M25TestLoad = 51
function global:Get-Counter {
    [pscustomobject]@{CounterSamples=@([pscustomobject]@{CookedValue=$global:M25TestLoad})}
}
function Expect-Refusal([string]$Mode, [string]$Pattern) {
    try {
        & $Harness -Repo $Repo -Zig $Zig -Output $Output -Mode $Mode
        throw 'Harness unexpectedly accepted the refusal fixture'
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected $Pattern, got $($_.Exception.Message)"
        }
    }
}
try {
    Expect-Refusal 'build' 'exceeds the 50 percent cutoff'
    $global:M25TestLoad = 0
    Expect-Refusal 'build' 'Stale output: null-debug'
    Expect-Refusal 'desktop' 'Stale trace:'
    Write-Output 'Harness refusal tests: 3/3 passed; no child launched'
} finally {
    Remove-Item Function:Get-Counter
    Remove-Variable M25TestLoad -Scope Global
}
