# Runs windows.ps1 -Mode desktop or -Mode person in the owner's desktop session from a scheduled
# task, waits for it, and prints its transcript. The task is unregistered after.
# `desktop` is unattended and wants no physical pad plugged in; `person` waits for a person at the
# PC (the motion window, then the court twice), with a pad and a second audio output.
# -IgnoreCpuLimit only when the owner explicitly suspends the standing CPU cutoff.
param([ValidateSet('desktop','person')][string]$Mode = 'desktop', [string]$Evidence = '', [string[]]$Only = @(),
    [int]$Minutes = 0, [switch]$IgnoreCpuLimit)
$ErrorActionPreference = 'Stop'
if ($Minutes -le 0) { $Minutes = if ($Mode -eq 'person') { 300 } else { 120 } }
$root = Join-Path $env:USERPROFILE 'm45'
$script = Join-Path $root 'windows.ps1'
$done = Join-Path $root "$Mode.done"
$log = Join-Path $root "$Mode.transcript.txt"
Remove-Item $done, $log -ErrorAction SilentlyContinue
$zig = Join-Path $env:USERPROFILE '.local\zig\zig-x86_64-windows-0.16.0\zig.exe'
$repo = Join-Path $env:USERPROFILE 'src\Foundry-m45'
$out = Join-Path $root 'out'
$extra = " -Mode $Mode"
if ($Evidence) { $extra += " -Evidence '$Evidence'" }
if ($IgnoreCpuLimit) { $extra += ' -IgnoreCpuLimit' }
# Through `-File`, a list arrives as one comma-joined string, which would match no run at all.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only) { $extra += " -Only " + (($Only | ForEach-Object { "'$_'" }) -join ',') }
$body = "Start-Transcript -Path '$log' -Force | Out-Null; try { & '$script' -Repo '$repo' -Zig '$zig' -Output '$out'$extra } catch { Write-Output `"$($Mode.ToUpper()) FAILED: `$_`" } finally { Stop-Transcript | Out-Null; Set-Content '$done' 'done' }"
$wrapper = Join-Path $root "$Mode-task.ps1"
Set-Content $wrapper $body -Encoding UTF8
$user = (Get-CimInstance Win32_ComputerSystem).UserName
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$wrapper`""
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$name = "FoundryM45$((Get-Culture).TextInfo.ToTitleCase($Mode))"
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
