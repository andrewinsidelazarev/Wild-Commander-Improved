[CmdletBinding()]
param([switch]$SkipPluginBuild)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath 'U:\Desktop' -PathType Container)) {
    & subst.exe U: $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create U: ASCII path alias.' }
}

$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
# Тот же расчёт пути через U:, что и в build.ps1: без зашитого имени проекта.
$ProfileRoot = [IO.Path]::GetFullPath($env:USERPROFILE)
if (-not $ProjectRoot.StartsWith($ProfileRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Project must live inside the user profile for the U: alias: $ProjectRoot"
}
$ProjectAlias = 'U:' + $ProjectRoot.Substring($ProfileRoot.Length)
$SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'

if (-not $SkipPluginBuild) {
    & (Join-Path $ProjectRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed.' }
}

Push-Location $ProjectAlias
try {
    # Обвязка ядра Deflate для эмулятора Z80: build\inflate_test.bin.
    # sjasmplus пишет ход сборки в stderr — вызов через cmd, см. build.ps1.
    $line = '"' + $SjasmPlus + '" --nologo --sym=build/inflate_test.sym --lst=build/inflate_test.lst tests/inflate_harness.asm 2>&1'
    $output = & cmd.exe /c $line
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Inflate harness assembly failed.' }

    $output = & cmd.exe /c 'python -m unittest discover -s tests -p "test_*.py" -v 2>&1'
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed.' }
} finally {
    Pop-Location
}
