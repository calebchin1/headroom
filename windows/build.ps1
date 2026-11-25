# Compiles windows/Headroom.cs into Headroom.exe with the C# compiler that ships with Windows (.NET Framework 4.x).
# Used by GitHub Actions to build the release download; also works locally:  .\windows\build.ps1 -Out Headroom.exe
param([string]$Out = 'Headroom.exe')
$ErrorActionPreference = 'Stop'
$csc = @('Framework64', 'Framework') |
    ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw 'Needs .NET Framework 4.x (ships with Windows 10 and 11).' }
$fw = Split-Path $csc
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$Out" "/lib:$fw\WPF" `
    /r:PresentationFramework.dll /r:PresentationCore.dll /r:WindowsBase.dll /r:System.Xaml.dll `
    /r:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'Headroom.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Out)) { throw 'Build failed' }
