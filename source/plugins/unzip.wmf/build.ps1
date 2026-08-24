[CmdletBinding()]
param(
    [string]$Sdcc = 'C:\Program Files\SDCC\bin\sdcc.exe',
    [string]$Sdasz80 = 'C:\Program Files\SDCC\bin\sdasz80.exe',
    [string]$Objcopy = 'C:\Program Files\SDCC\bin\sdobjcopy.exe',
    [string]$SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$BuildDir = Join-Path $ProjectRoot 'build'
$ObjectDir = Join-Path $BuildDir 'obj'

if (-not (Test-Path -LiteralPath 'U:\Desktop' -PathType Container)) {
    & subst.exe U: $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create U: ASCII path alias.' }
}

foreach ($tool in $Sdcc, $Sdasz80, $Objcopy, $SjasmPlus) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Build tool not found: $tool"
    }
}

$ProjectAlias = 'U:\Desktop\WC\WildCommander Improved\source\plugins\unzip.wmf'
if (-not (Test-Path -LiteralPath $ProjectAlias -PathType Container)) {
    throw "U: does not expose the project: $ProjectAlias"
}

New-Item -ItemType Directory -Path $BuildDir, $ObjectDir -Force | Out-Null

Push-Location $ProjectAlias
try {
    & $Sdasz80 -plosgff -o 'build\obj\crt0.rel' 'src\crt0.s'
    if ($LASTEXITCODE -ne 0) { throw 'crt0 assembly failed.' }

    $CompileOptions = @(
        '-mz80', '--std-sdcc11', '--opt-code-size', '--max-allocs-per-node', '100000',
        '-Isrc', '-c'
    )
    & $Sdcc @CompileOptions 'src\wc_api.c' -o 'build\obj\wc_api.rel'
    if ($LASTEXITCODE -ne 0) { throw 'wc_api.c compilation failed.' }
    & $Sdcc @CompileOptions 'src\inflate.c' -o 'build\obj\inflate.rel'
    if ($LASTEXITCODE -ne 0) { throw 'inflate.c compilation failed.' }
    & $Sdcc @CompileOptions 'src\unzip.c' -o 'build\obj\unzip.rel'
    if ($LASTEXITCODE -ne 0) { throw 'unzip.c compilation failed.' }

    & $Sdcc -mz80 --no-std-crt0 --code-loc 0x8020 --data-loc 0xB000 `
        'build\obj\crt0.rel' 'build\obj\wc_api.rel' 'build\obj\inflate.rel' `
        'build\obj\unzip.rel' -Wl-m -o 'build\obj\unzip.ihx'
    if ($LASTEXITCODE -ne 0) { throw 'Z80 link failed.' }

    & $Objcopy -I ihex -O binary 'build\obj\unzip.ihx' 'build\code.bin'
    if ($LASTEXITCODE -ne 0) { throw 'Intel HEX conversion failed.' }

    & $SjasmPlus '--lst=build/UNZIP.lst' '--sym=build/UNZIP.sym' 'src/wmf.asm'
    if ($LASTEXITCODE -ne 0) { throw 'WMF packaging failed.' }
} finally {
    Pop-Location
}

$Code = Get-Item -LiteralPath (Join-Path $BuildDir 'code.bin')
$Wmf = Get-Item -LiteralPath (Join-Path $BuildDir 'UNZIP.WMF')
if ($Code.Length -gt 0x4000) {
    throw "Code/data image exceeds one 16-KiB page: $($Code.Length) bytes"
}
if ($Wmf.Length -lt 1024) {
    throw "WMF output is unexpectedly short: $($Wmf.Length) bytes"
}

$Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Wmf.FullName).Hash
Write-Host "UNZIP.WMF build complete: $($Wmf.FullName)"
Write-Host "Code/data image: $($Code.Length) bytes"
Write-Host "WMF size: $($Wmf.Length) bytes"
Write-Host "SHA-256: $Hash"
