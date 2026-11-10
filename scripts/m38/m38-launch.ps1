# Runs windows.ps1 -Mode desktop in the owner's desktop session from a scheduled task, waits for it,
# and prints its transcript. The task is unregistered after.
param([string]$Evidence = '', [string[]]$Only = @(), [int]$Minutes = 120)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:USERPROFILE 'm38'
$script = Join-Path $root 'windows.ps1'
$done = Join-Path $root 'desktop.done'
$log = Join-Path $root 'desktop.transcript.txt'
Remove-Item $done, $log -ErrorAction SilentlyContinue
$zig = Join-Path $env:USERPROFILE '.local\zig\zig-x86_64-windows-0.16.0\zig.exe'
$repo = Join-Path $env:USERPROFILE 'src\Foundry-m38'
$out = Join-Path $root 'out'
$extra = ''
if ($Evidence) { $extra += " -Evidence '$Evidence'" }
# Through `-File`, a list arrives as one comma-joined string, which would match no run at all.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only) { $extra += " -Only " + (($Only | ForEach-Object { "'$_'" }) -join ',') }
$body = "Start-Transcript -Path '$log' -Force | Out-Null; try { & '$script' -Repo '$repo' -Zig '$zig' -Output '$out' -Mode desktop$extra } catch { Write-Output `"DESKTOP FAILED: `$_`" } finally { Stop-Transcript | Out-Null; Set-Content '$done' 'done' }"
$wrapper = Join-Path $root 'desktop-task.ps1'
Set-Content $wrapper $body -Encoding UTF8
$user = (Get-CimInstance Win32_ComputerSystem).UserName
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$wrapper`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$name = 'FoundryM38Desktop'
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $name
$deadline = (Get-Date).AddMinutes($Minutes)
while (-not (Test-Path $done)) {
    if ((Get-Date) -gt $deadline) { Write-Output 'launcher deadline'; break }
    Start-Sleep -Seconds 10
}
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path $log) { Get-Content $log | Select-String -NotMatch '^\*{5,}|^(Start|End) time|^Username|^RunAs|^Configuration|^Machine|^Host Application|^Process ID|^PSVersion|^PSEdition|^PSCompatible|^BuildVersion|^CLRVersion|^WSManStack|^PSRemoting|^SerializationVersion|^Windows PowerShell transcript' }
