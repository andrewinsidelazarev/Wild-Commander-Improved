[CmdletBinding()]
param(
    [string]$ReferenceRoot,
    [string]$SjasmPlus
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$ReferenceRoot = if ($ReferenceRoot) {
    $ReferenceRoot
} else {
    Join-Path $ProjectRoot '..\Chkdsk\wc_reference\pentevo\soft\WC'
}
$WcParent = [IO.Directory]::GetParent($ProjectRoot).FullName
$BuildDir = Join-Path $ProjectRoot 'Build'
$ExeDir = Join-Path $ProjectRoot 'exe'
$ReferenceRoot = [IO.Path]::GetFullPath($ReferenceRoot)
$ReferenceExe = Join-Path $ReferenceRoot 'exe'

if (-not (Test-Path -LiteralPath $ReferenceExe -PathType Container)) {
    throw "Reference exe directory not found: $ReferenceExe"
}

# SjASMPlus 1.21 аварийно завершается, если путь к исходнику содержит кириллицу.
# Проект остаётся на месте, а ассемблер получает короткие ASCII-псевдодиски.
if (-not (Test-Path -LiteralPath 'W:\WildCommander' -PathType Container)) {
    & subst.exe W: $WcParent
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create W: source alias.' }
}
if (-not (Test-Path -LiteralPath 'U:\Desktop' -PathType Container)) {
    & subst.exe U: $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create U: tool alias.' }
}

if (-not $SjasmPlus) {
    $SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
}
if (-not (Test-Path -LiteralPath $SjasmPlus -PathType Leaf)) {
    throw "SjASMPlus not found: $SjasmPlus"
}

New-Item -ItemType Directory -Path $BuildDir, $ExeDir -Force | Out-Null

# Все активные исследованные исходники и тексты обязаны быть UTF-8 без BOM.
# Карантин `source\to delete` намеренно не входит в эту проверку.
$Utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$TextExtensions = '.asm', '.a80', '.s', '.c', '.h', '.txt', '.md'
Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'source') -Recurse -File |
    Where-Object {
        $_.Extension.ToLowerInvariant() -in $TextExtensions -and
        $_.FullName -notlike '*\to delete\*'
    } |
    ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "UTF-8 BOM is forbidden: $($_.FullName)"
        }
        try {
            $null = $Utf8Strict.GetString($bytes)
        } catch {
            throw "File is not valid UTF-8: $($_.FullName)"
        }
    }

# Оригинальные ASM четырёх драйверов доказанно дают те же распакованные
# runtime-образы, что лежат внутри WildDOS. Сборка проверяет это при каждом
# запуске, чтобы осмысленные исходники не превратились в необязательную копию.
$DriverBuildDir = Join-Path $BuildDir 'driver-runtime'
New-Item -ItemType Directory -Path $DriverBuildDir -Force | Out-Null
$DriverChecks = @(
    @{ Name = 'DIDENEMO'; Length = 959;  Sha256 = '9e093cc840ab0a810332232b9e74b36c9f09068c39452b1900876e9ccf4d6756' },
    @{ Name = 'DIDESMUC'; Length = 903;  Sha256 = 'f9985ca2f5595979a02198991e9d412ed2cf43215def0c6310ebeac1edd4c635' },
    @{ Name = 'DSDZC';    Length = 1164; Sha256 = '12b4323aa4b70a7e009ae6003852b8d372acd9d8b62428f496055d8ebe1af2db' },
    @{ Name = 'DSDNGS';   Length = 1378; Sha256 = '468c306c1f10a6956faae65472315f37d78117779ceabd8ee371e2e72ede4ebe' }
)
foreach ($driver in $DriverChecks) {
    $driverName = $driver.Name
    $driverOutput = Join-Path $DriverBuildDir "$driverName.bin"
    Remove-Item -LiteralPath $driverOutput -Force -ErrorAction SilentlyContinue
    & $SjasmPlus '--nologo' '--msg=err' `
        "--raw=W:/WildCommander/Build/driver-runtime/$driverName.bin" `
        "W:/WildCommander/source/$driverName.ASM"
    if ($LASTEXITCODE -ne 0) { throw "$driverName.ASM assembly failed." }
    if ((Get-Item -LiteralPath $driverOutput).Length -ne $driver.Length) {
        throw "Unexpected $driverName runtime size."
    }
    $driverHash = (Get-FileHash -LiteralPath $driverOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($driverHash -ne $driver.Sha256) {
        throw "$driverName runtime hash mismatch: $driverHash"
    }
}

$MainSourceAscii = 'W:/WildCommander/source/BOOT.ASM'
$PayloadAscii = 'W:/WildCommander/Build/boot.payload.bin'
$Payload = Join-Path $BuildDir 'boot.payload.bin'
$BootOutput = Join-Path $ExeDir 'boot.$C'

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'source\BOOT.ASM') -PathType Leaf)) {
    throw 'source\BOOT.ASM not found.'
}
Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $BootOutput -Force -ErrorAction SilentlyContinue

& $SjasmPlus '--nologo' '--msg=err' "--raw=$PayloadAscii" $MainSourceAscii
if ($LASTEXITCODE -ne 0) { throw 'BOOT.ASM assembly failed.' }
if ((Get-Item -LiteralPath $Payload).Length -ne 0x7C00) {
    throw "Unexpected boot payload size: $((Get-Item -LiteralPath $Payload).Length)"
}

& python (Join-Path $ProjectRoot 'tools\pack_hobeta.py') $Payload $BootOutput
if ($LASTEXITCODE -ne 0) { throw 'HoBeta packing failed.' }

# Плагины, меню, конфигурация и документация — готовые runtime-файлы.
# Код Commander всегда собирается выше; остальные неизменяемые файлы берутся
# из указанного локального эталона и также входят в хэш-аудит.
Get-ChildItem -LiteralPath $ReferenceExe -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($ReferenceExe.Length + 1)
    if ($relative -ine 'boot.$C') {
        $destination = Join-Path $ExeDir $relative
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [IO.File]::Copy($_.FullName, $destination, $true)
    }
}

$HashReport = Join-Path $BuildDir 'hash-report.tsv'
& python (Join-Path $ProjectRoot 'tools\verify_hashes.py') `
    --actual $ExeDir `
    --reference $ReferenceExe `
    --format tsv `
    --output $HashReport
if ($LASTEXITCODE -ne 0) { throw "Hash verification failed. See $HashReport" }

$BootHash = (Get-FileHash -LiteralPath $BootOutput -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "WC build complete: $BootOutput"
Write-Host ('boot.$C SHA-256: {0}' -f $BootHash)
Write-Host "Full exe audit: $HashReport"
