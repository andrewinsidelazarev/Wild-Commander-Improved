[CmdletBinding()]
param([switch]$SkipPluginBuild)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath 'U:\Desktop' -PathType Container)) {
    & subst.exe U: $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create U: ASCII path alias.' }
}

$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ProjectAlias = 'U:\Desktop\WC\WildCommander Improved\source\plugins\unzip.wmf'
$Sdcc = 'C:\Program Files\SDCC\bin\sdcc.exe'
$Sdasz80 = 'C:\Program Files\SDCC\bin\sdasz80.exe'
$Objcopy = 'C:\Program Files\SDCC\bin\sdobjcopy.exe'

if (-not $SkipPluginBuild) {
    & (Join-Path $ProjectRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed.' }
}

Push-Location $ProjectAlias
try {
    & $Sdasz80 -plosgff -o 'build\obj\inflate_test_crt0.rel' 'tests\inflate_crt0.s'
    if ($LASTEXITCODE -ne 0) { throw 'Test crt0 assembly failed.' }

    & $Sdcc -mz80 --std-sdcc11 --opt-code-size --max-allocs-per-node 100000 `
        -Isrc -c 'tests\inflate_harness.c' -o 'build\obj\inflate_harness.rel'
    if ($LASTEXITCODE -ne 0) { throw 'Inflate harness compilation failed.' }

    & $Sdcc -mz80 --no-std-crt0 --code-loc 0x8020 --data-loc 0xB000 `
        'build\obj\inflate_test_crt0.rel' 'build\obj\inflate_harness.rel' `
        'build\obj\inflate.rel' -Wl-m -o 'build\obj\inflate_test.ihx'
    if ($LASTEXITCODE -ne 0) { throw 'Inflate harness link failed.' }

    & $Objcopy -I ihex -O binary 'build\obj\inflate_test.ihx' `
        'build\inflate_test.bin'
    if ($LASTEXITCODE -ne 0) { throw 'Inflate harness conversion failed.' }

    python -m unittest discover -s tests -p 'test_*.py' -v
    if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed.' }
} finally {
    Pop-Location
}
