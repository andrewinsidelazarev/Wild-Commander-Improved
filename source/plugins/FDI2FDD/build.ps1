[CmdletBinding()]
param([string]$SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Не создаём глобальных SUBST и не пишем вне каталога плагина.
if (-not (Test-Path -LiteralPath $SjasmPlus)) {
    $SjasmPlus = Join-Path $env:USERPROFILE 'Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
}
if (-not (Test-Path -LiteralPath $SjasmPlus)) { throw "Assembler missing: $SjasmPlus" }
if (-not ('FdiShortPath' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FdiShortPath {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
 public static extern uint GetShortPathName(string path, StringBuilder buffer, uint size);
}
'@
}
$buf = New-Object Text.StringBuilder 2048
if ([FdiShortPath]::GetShortPathName($PSScriptRoot, $buf, 2048) -eq 0) { throw 'No ASCII short path' }
$asciiRoot = $buf.ToString()
if ($asciiRoot -match '[^\x00-\x7F]') { throw 'sjasmplus requires an ASCII path (enable 8.3 names or use an existing ASCII alias)' }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'build') | Out-Null
Push-Location $asciiRoot
try {
    $cmd = '""' + $SjasmPlus + '" --nologo --msg=err --sym=build/FDI2FDD.sym --lst=build/FDI2FDD.lst FDI2FDD.ASM 2>&1"'
    $log = & cmd.exe /d /s /c $cmd
    if ($LASTEXITCODE -ne 0) { $log | ForEach-Object { Write-Host $_ }; throw 'FDI2FDD assembly failed' }
    if ($log) { $log | ForEach-Object { Write-Host $_ } }
} finally { Pop-Location }
Write-Host ('FDI2FDD.WMF: {0} bytes' -f (Get-Item (Join-Path $PSScriptRoot 'build\FDI2FDD.WMF')).Length)
