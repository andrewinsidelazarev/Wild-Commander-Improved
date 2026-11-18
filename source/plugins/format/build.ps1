[CmdletBinding()]
param([string]$SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# FORMAT.WMF и обвязка теста расчёта разметки. Не создаём глобальных SUBST и
# не пишем вне каталога плагина.
if (-not (Test-Path -LiteralPath $SjasmPlus)) {
    $SjasmPlus = Join-Path $env:USERPROFILE 'Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
}
if (-not (Test-Path -LiteralPath $SjasmPlus)) { throw "Assembler missing: $SjasmPlus" }
if (-not ('FormatShortPath' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FormatShortPath {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
 public static extern uint GetShortPathName(string path, StringBuilder buffer, uint size);
}
'@
}
$buf = New-Object Text.StringBuilder 2048
if ([FormatShortPath]::GetShortPathName($PSScriptRoot, $buf, 2048) -eq 0) { throw 'No ASCII short path' }
$asciiRoot = $buf.ToString()
if ($asciiRoot -match '[^\x00-\x7F]') { throw 'sjasmplus requires an ASCII path (enable 8.3 names or use an existing ASCII alias)' }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'build') | Out-Null

function Invoke-Sjasm([string]$Directory, [string]$Arguments, [string]$What) {
    Push-Location $Directory
    try {
        $cmd = '""' + $SjasmPlus + '" --nologo --msg=err ' + $Arguments + ' 2>&1"'
        $log = & cmd.exe /d /s /c $cmd
        if ($LASTEXITCODE -ne 0) { $log | ForEach-Object { Write-Host $_ }; throw "$What assembly failed" }
        if ($log) { $log | ForEach-Object { Write-Host $_ } }
    } finally { Pop-Location }
}

Invoke-Sjasm $asciiRoot '--sym=build/FORMAT.sym --lst=build/FORMAT.lst FORMAT.ASM' 'FORMAT'
Invoke-Sjasm (Join-Path $asciiRoot 'tests') '--sym=../build/layout_harness.sym layout_harness.asm' 'layout harness'
Invoke-Sjasm (Join-Path $asciiRoot 'tests') '--sym=../build/sectors_harness.sym sectors_harness.asm' 'sectors harness'
Write-Host ('FORMAT.WMF: {0} bytes' -f (Get-Item (Join-Path $PSScriptRoot 'build\FORMAT.WMF')).Length)
