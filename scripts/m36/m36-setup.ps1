param([Parameter(Mandatory=$true)][string]$Commit)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
function Invoke-Git { $ErrorActionPreference = 'Continue'; & git.exe @args 2>&1 | Out-String | Write-Verbose; if ($LASTEXITCODE -ne 0) { throw "git $args exited $LASTEXITCODE" } }
$repo = Join-Path $env:USERPROFILE 'src\Foundry-m36'
$bundle = Join-Path $env:USERPROFILE 'm36\m36.bundle'
if (-not (Test-Path $repo)) {
    Invoke-Git -c core.autocrlf=false clone --quiet https://github.com/sjoygsh/Foundry.git $repo
}
Set-Location $repo
Invoke-Git config core.autocrlf false
Invoke-Git bundle verify $bundle 2>&1 | Out-Null
Invoke-Git fetch --quiet $bundle "HEAD:refs/remotes/bundle/m36"
Invoke-Git -c advice.detachedHead=false checkout --quiet --detach $Commit
$head = (& git.exe rev-parse HEAD).Trim()
if ($head -ne $Commit) { throw "HEAD is $head" }
"checked out $head"
(& git.exe status --short | Measure-Object).Count
