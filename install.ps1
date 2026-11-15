# One-line install for Windows 10/11 (paste into PowerShell):
#   irm https://raw.githubusercontent.com/calebchin1/usage-rings/main/install.ps1 | iex
# Downloads windows/UsageRings.cs and compiles it with the C# compiler built into Windows
# (.NET Framework 4.x), so there's no downloaded .exe and no SmartScreen prompt.
# Installs to %LOCALAPPDATA%\UsageRings and starts it at login. No admin needed.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 defaults to TLS 1.0

$Src  = 'https://raw.githubusercontent.com/calebchin1/usage-rings/main/windows/UsageRings.cs'
$Dir  = Join-Path $env:LOCALAPPDATA 'UsageRings'
$Exe  = Join-Path $Dir 'UsageRings.exe'
$Cs   = Join-Path $Dir 'UsageRings.cs'

$csc = @('Framework64', 'Framework') |
    ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    Write-Host 'UsageRings needs .NET Framework 4.x, which ships with Windows 10 and 11.' -ForegroundColor Red
    return
}
$fw = Split-Path $csc

Write-Host '-> Downloading UsageRings...'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Get-Process UsageRings -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
if ($env:USAGERINGS_SRC) { Copy-Item $env:USAGERINGS_SRC $Cs -Force }   # local source, for testing
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
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name UsageRings -Value "`"$Exe`""
Start-Process $Exe

Write-Host 'Done! Look for the widget in the top-right of your screen.' -ForegroundColor Green
Write-Host '  Click it to switch Claude/Codex - drag to move - right-click for options.'
