# Clones Foundry into its own `src\Foundry-m45` (once), fetches every branch of the bundle the Mac
# copied to `%USERPROFILE%\m45\m45.bundle`, and checks out $Commit detached. $Commit is the full
# hash: an abbreviated one is refused by the checkout, and HEAD is compared with it whole.
param([Parameter(Mandatory=$true)][string]$Commit)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
function Invoke-Git { $ErrorActionPreference = 'Continue'; & git.exe @args 2>&1 | Out-String | Write-Verbose; if ($LASTEXITCODE -ne 0) { throw "git $args exited $LASTEXITCODE" } }
$repo = Join-Path $env:USERPROFILE 'src\Foundry-m45'
$bundle = Join-Path $env:USERPROFILE 'm45\m45.bundle'
if (-not (Test-Path $repo)) {
    Invoke-Git -c core.autocrlf=false clone --quiet https://github.com/sjoygsh/Foundry.git $repo
}
Set-Location $repo
Invoke-Git config core.autocrlf false
Invoke-Git bundle verify $bundle 2>&1 | Out-Null
# Main and the agent's branch alike, since the commit under test may be on either.
Invoke-Git fetch --quiet $bundle "+refs/heads/*:refs/remotes/bundle-m45/*"
Invoke-Git -c advice.detachedHead=false checkout --quiet --detach $Commit
$head = (& git.exe rev-parse HEAD).Trim()
if ($head -ne $Commit) { throw "HEAD is $head" }
"checked out $head"
(& git.exe status --short | Measure-Object).Count
