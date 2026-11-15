# One-line install for Windows 10/11 (paste into PowerShell):
#   irm https://raw.githubusercontent.com/calebchin1/headroom/main/install.ps1 | iex
# Downloads windows/Headroom.cs and compiles it with the C# compiler built into Windows
# (.NET Framework 4.x), so there's no downloaded .exe and no SmartScreen prompt.
# Installs to %LOCALAPPDATA%\Headroom and starts it at login. No admin needed.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 defaults to TLS 1.0

$Src  = 'https://raw.githubusercontent.com/calebchin1/headroom/main/windows/Headroom.cs'
$Dir  = Join-Path $env:LOCALAPPDATA 'Headroom'
$Exe  = Join-Path $Dir 'Headroom.exe'
$Cs   = Join-Path $Dir 'Headroom.cs'

$csc = @('Framework64', 'Framework') |
    ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    Write-Host 'Headroom needs .NET Framework 4.x, which ships with Windows 10 and 11.' -ForegroundColor Red
    return
}
$fw = Split-Path $csc

Write-Host '-> Downloading Headroom...'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Get-Process Headroom, UsageRings -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
# Clean up the pre-rename install (UsageRings).
Remove-Item (Join-Path $env:LOCALAPPDATA 'UsageRings') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\UsageRings' -Recurse -Force -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name UsageRings -ErrorAction SilentlyContinue
if ($env:HEADROOM_SRC) { Copy-Item $env:HEADROOM_SRC $Cs -Force }   # local source, for testing
else { Invoke-WebRequest -UseBasicParsing $Src -OutFile $Cs }

Write-Host '-> Building...'
$out = & $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$Exe" "/lib:$fw\WPF" `
    /r:PresentationFramework.dll /r:PresentationCore.dll /r:WindowsBase.dll /r:System.Xaml.dll `
    /r:System.Web.Extensions.dll $Cs 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Exe)) {
    Write-Host 'Build failed:' -ForegroundColor Red
    $out | Where-Object { $_ -match 'error' } | ForEach-Object { Write-Host "  $_" }
    return
}

Write-Host '-> Adding to startup...'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
Set-ItemProperty $run -Name Headroom -Value "`"$Exe`""
Start-Process $Exe

Write-Host 'Done! Look for the widget in the top-right of your screen.' -ForegroundColor Green
Write-Host '  Click it to switch Claude/Codex - drag to move - right-click for options.'
