# Codex - 2026-07-16 - begin
[CmdletBinding()]
param(
    [string]$ReferenceRoot,
    [string]$SjasmPlus,
    [string]$Mhmt,
    [switch]$RequireExact
)
# Codex - 2026-07-16 - end

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

# Codex - 2026-07-16 - begin
# SjASMPlus 1.21 аварийно завершается, если путь к исходнику содержит кириллицу.
# Проект остаётся на месте, а ассемблер получает короткий ASCII-псевдодиск.
# Имя каталога проекта не зашито: рядом могут одновременно лежать Original и
# Improved, как в рабочем дереве разработки.
if (-not (Test-Path -LiteralPath 'W:\' -PathType Container)) {
    & subst.exe W: $WcParent
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create W: source alias.' }
}
$ProjectLeaf = Split-Path -Leaf $ProjectRoot
$ProjectRootAlias = Join-Path 'W:\' $ProjectLeaf
if (-not (Test-Path -LiteralPath $ProjectRootAlias -PathType Container)) {
    throw "W: does not expose the current project: $ProjectRootAlias"
}
$ProjectRootAscii = ('W:/' + $ProjectLeaf).Replace('\', '/')
# Codex - 2026-07-16 - end

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

# Codex - 2026-07-16 - begin
if (-not $Mhmt) {
    $Mhmt = Join-Path $WcParent 'ZiFi\_spg\mhmt.exe'
}
if (-not (Test-Path -LiteralPath $Mhmt -PathType Leaf)) {
    throw "MHMT not found: $Mhmt"
}
# Codex - 2026-07-16 - end

# Codex - 2026-07-17 - begin
function Set-HrustPackedLength {
    param([Parameter(Mandatory)][string]$Path)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 12 -or $bytes[0] -ne 0x48 -or $bytes[1] -ne 0x52) {
        throw "Некорректный HR-блок: $Path"
    }
    if ($bytes.Length -gt [UInt16]::MaxValue) {
        throw "HR-блок не помещается в 16-битное поле длины: $Path"
    }

    # MHMT 2009 ошибочно дублирует в +4 размер результата. DEHR2 использует
    # это слово как полный размер упакованного блока при безопасном переносе
    # перекрывающегося потока, поэтому записываем фактическую длину файла.
    $bytes[4] = $bytes.Length -band 0xFF
    $bytes[5] = ($bytes.Length -shr 8) -band 0xFF
    [IO.File]::WriteAllBytes($Path, $bytes)

    $storedLength = [int]$bytes[4] -bor ([int]$bytes[5] -shl 8)
    if ($storedLength -ne $bytes.Length) {
        throw "Не удалось исправить длину HR-блока: $Path"
    }
}
# Codex - 2026-07-17 - end

New-Item -ItemType Directory -Path $BuildDir, $ExeDir -Force | Out-Null

# Все активные исследованные исходники и тексты обязаны быть UTF-8 без BOM.
# Карантин `source\to delete` намеренно не входит в эту проверку.
$Utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$TextExtensions = '.asm', '.a80', '.s', '.c', '.h', '.txt', '.md'
$TextRoots = (Join-Path $ProjectRoot 'source'), (Join-Path $ProjectRoot 'FTViewConvert')
Get-ChildItem -LiteralPath $TextRoots -Recurse -File |
    Where-Object {
        $_.Extension.ToLowerInvariant() -in $TextExtensions -and
        $_.FullName -notlike '*\to delete\*'
    } |
    ForEach-Object {
        # Путь запоминается ДО try: внутри catch $_ — это пойманная ошибка, а не
        # файл, и обращение к $_.FullName в строгом режиме падает само,
        # подменяя внятное «файл не в UTF-8» на «нет свойства FullName».
        $path = $_.FullName
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "UTF-8 BOM is forbidden: $path"
        }
        try {
            $null = $Utf8Strict.GetString($bytes)
        } catch {
            throw "File is not valid UTF-8: $path"
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
    # Codex - 2026-07-16 - begin
    @{ Name = 'DSDZC';    Length = 1164; Sha256 = 'f3909ee06932ab8bea15894a3541b16614dfaa21641f207944d020b3e09de953' },
    # Codex - 2026-07-16 - end
    @{ Name = 'DSDNGS';   Length = 1378; Sha256 = '468c306c1f10a6956faae65472315f37d78117779ceabd8ee371e2e72ede4ebe' }
)
foreach ($driver in $DriverChecks) {
    $driverName = $driver.Name
    $driverOutput = Join-Path $DriverBuildDir "$driverName.bin"
    Remove-Item -LiteralPath $driverOutput -Force -ErrorAction SilentlyContinue
    # Codex - 2026-07-16 - begin
    $driverSymbolsAscii = "$ProjectRootAscii/Build/driver-runtime/$driverName.sym"
    $driverListingAscii = "$ProjectRootAscii/Build/driver-runtime/$driverName.lst"
    & $SjasmPlus '--nologo' '--msg=err' `
        "--raw=$ProjectRootAscii/Build/driver-runtime/$driverName.bin" `
        "--sym=$driverSymbolsAscii" "--lst=$driverListingAscii" `
        "$ProjectRootAscii/source/$driverName.ASM"
    # Codex - 2026-07-16 - end
    if ($LASTEXITCODE -ne 0) { throw "$driverName.ASM assembly failed." }
    if ((Get-Item -LiteralPath $driverOutput).Length -ne $driver.Length) {
        throw "Unexpected $driverName runtime size."
    }
    $driverHash = (Get-FileHash -LiteralPath $driverOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($driverHash -ne $driver.Sha256) {
        throw "$driverName runtime hash mismatch: $driverHash"
    }
}

# Codex - 2026-07-16 - begin
# Codex - 2026-07-17 - begin
# После аппаратно выявленного отказа записи боевой CORE32 снова использует
# точный DOSpSDZC35.CPD. Этот блок остаётся диагностическим артефактом: сборка
# проверяет обратную распаковку экспериментального варианта, но не включает его
# в boot.$C без отдельного аппаратного подтверждения.
$DsdzcPacked = Join-Path $DriverBuildDir 'DSDZC.fixed.CPD'
$DsdzcVerify = Join-Path $DriverBuildDir 'DSDZC.fixed.verify.bin'
Remove-Item -LiteralPath $DsdzcPacked, $DsdzcVerify -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $Mhmt '-hst' '-zxh' `
        "$ProjectRootAscii/Build/driver-runtime/DSDZC.bin" `
        "$ProjectRootAscii/Build/driver-runtime/DSDZC.fixed.CPD"
    if ($LASTEXITCODE -ne 0) { throw 'DSDZC runtime packing failed.' }
    # Codex - 2026-07-17 - begin
    Set-HrustPackedLength -Path $DsdzcPacked
    # Codex - 2026-07-17 - end
    & $Mhmt '-hst' '-zxh' '-d' `
        "$ProjectRootAscii/Build/driver-runtime/DSDZC.fixed.CPD" `
        "$ProjectRootAscii/Build/driver-runtime/DSDZC.fixed.verify.bin"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'DSDZC packed runtime verification failed.' }
$DsdzcSourceHash = (Get-FileHash -LiteralPath (Join-Path $DriverBuildDir 'DSDZC.bin') -Algorithm SHA256).Hash
$DsdzcVerifyHash = (Get-FileHash -LiteralPath $DsdzcVerify -Algorithm SHA256).Hash
if ($DsdzcSourceHash -ne $DsdzcVerifyHash) {
    throw 'DSDZC packed runtime does not unpack byte-for-byte.'
}
Remove-Item -LiteralPath $DsdzcVerify -Force
$global:LASTEXITCODE = 0
# Codex - 2026-07-17 - end
# Codex - 2026-07-16 - end

# Codex - 2026-07-17 - begin
# Боевой SD-ZC обязан оставаться тем самым проверенным HR-потоком, с которым
# файловые операции работали на реальном Z-Controller.
$StockDsdzcPacked = Join-Path $ProjectRoot 'source\DOSpSDZC35.CPD'
$StockDsdzcPackedHash = (Get-FileHash -LiteralPath $StockDsdzcPacked -Algorithm SHA256).Hash.ToLowerInvariant()
if ($StockDsdzcPackedHash -ne '06742113aff8306b39a1a808ae6042cafc784d7dc9ee6aa0b178d75f9825c03d') {
    throw "Stock SD-ZC packed hash mismatch: $StockDsdzcPackedHash"
}
# Codex - 2026-07-17 - end

# Claude - 2026-09-26 - begin
# Ресурсы запуска — шрифт FONT32L3 (#800) и пара распаковщиков MLZ50F (#E9) и
# DEHR1M (#117) — нужны только VDAC, который раскладывает их по страницам #01
# и #09. В boot.$C они лежат HR-потоками (распаковывает тот же DEHR #5AAA, что
# и расширение): так перед #BF60 свободнее на ~1,2 КиБ. Пара склеивается в
# порядке назначения — MLZ50F с #FE00, DEHR1M с #FEE9 — и распаковывается одним
# вызовом. Каждый поток проверяется обратной распаковкой. Упаковка — до
# символического прохода BOOT: от размера ресурсов зависят адреса всего за WCINI.
$ResourceStreams = @(
    @{ Raw = Join-Path $ProjectRoot 'source\FONT32L3.CDB'; RawAscii = 'source/FONT32L3.CDB';
       Packed = Join-Path $BuildDir 'FONT32L3.CPD'; PackedAscii = 'Build/FONT32L3.CPD' },
    @{ Raw = Join-Path $BuildDir 'DECODERS.bin'; RawAscii = 'Build/DECODERS.bin';
       Packed = Join-Path $BuildDir 'DECODERS.CPD'; PackedAscii = 'Build/DECODERS.CPD' }
)
[byte[]]$Mlz50f = [IO.File]::ReadAllBytes((Join-Path $ProjectRoot 'source\MLZ50F.CCB'))
[byte[]]$Dehr1m = [IO.File]::ReadAllBytes((Join-Path $ProjectRoot 'source\DEHR1M.CCB'))
if ($Mlz50f.Length -ne 0xE9 -or $Dehr1m.Length -ne 0x117) {
    throw 'MLZ50F.CCB или DEHR1M.CCB не того размера: #E9 и #117 байт.'
}
# DEHR берёт длину результата из потока и назначение не ограничивает: шрифт
# длиннее #800 байт лёг бы за #C7FF страниц #01 и #09 (прежде это ловил ASSERT
# за INCBIN в BOOT.ASM; аудит Codex, R17-01).
if ((Get-Item -LiteralPath (Join-Path $ProjectRoot 'source\FONT32L3.CDB')).Length -ne 0x800) {
    throw 'FONT32L3.CDB не того размера: #800 байт.'
}
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'DECODERS.bin'), [byte[]]($Mlz50f + $Dehr1m))
foreach ($Stream in $ResourceStreams) {
    $Verify = $Stream.Packed + '.verify'
    Remove-Item -LiteralPath $Stream.Packed, $Verify -Force -ErrorAction SilentlyContinue
    Push-Location -LiteralPath $ProjectRootAlias
    try {
        & $Mhmt '-hst' '-zxh' "$ProjectRootAscii/$($Stream.RawAscii)" `
            "$ProjectRootAscii/$($Stream.PackedAscii)"
        if ($LASTEXITCODE -ne 0) { throw "Не упаковался $($Stream.RawAscii)." }
        Set-HrustPackedLength -Path $Stream.Packed
        & $Mhmt '-hst' '-zxh' '-d' "$ProjectRootAscii/$($Stream.PackedAscii)" `
            "$ProjectRootAscii/$($Stream.PackedAscii).verify"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw "Не распаковался для сверки $($Stream.PackedAscii)." }
    if ((Get-FileHash -LiteralPath $Stream.Raw -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Verify -Algorithm SHA256).Hash) {
        throw "$($Stream.PackedAscii) распаковывается не байт в байт."
    }
    Remove-Item -LiteralPath $Verify -Force
}
$global:LASTEXITCODE = 0
# Claude - 2026-09-26 - end

# Codex - 2026-07-17 - begin
# Расширение больше физического нулевого окна boot.$C, но свободно помещается
# в выделенную страницу #E8. Сначала строится карта CORE32 без runtime, затем отдельный
# бинарник расширения, после чего его HR-поток проверяется обратной распаковкой.
$CoreSymbolPayload = Join-Path $BuildDir 'boot.symbol-pass.bin'
$CoreSymbolMap = Join-Path $BuildDir 'boot.symbol-pass.sym'
$CoreSymbolList = Join-Path $BuildDir 'boot.symbol-pass.lst'
$CoreInterface = Join-Path $BuildDir 'CORE32_WDOS_SYMBOLS.INC'
$ExtensionRaw = Join-Path $BuildDir 'CORE32_EXT.bin'
$ExtensionPacked = Join-Path $BuildDir 'CORE32_EXT.CPD'
$ExtensionVerify = Join-Path $BuildDir 'CORE32_EXT.verify.bin'
$ExtensionSymbols = Join-Path $BuildDir 'CORE32_EXT.sym'
$ExtensionListing = Join-Path $BuildDir 'CORE32_EXT.lst'
Remove-Item -LiteralPath $CoreSymbolPayload, $CoreSymbolMap, $CoreSymbolList, `
    $CoreInterface, $ExtensionRaw, $ExtensionPacked, $ExtensionVerify, `
    $ExtensionSymbols, $ExtensionListing -Force -ErrorAction SilentlyContinue

& $SjasmPlus '--nologo' '--msg=err' '-DWDOS_SYMBOL_PASS=1' `
    "--raw=$ProjectRootAscii/Build/boot.symbol-pass.bin" `
    "--sym=$ProjectRootAscii/Build/boot.symbol-pass.sym" `
    "--lst=$ProjectRootAscii/Build/boot.symbol-pass.lst" `
    "$ProjectRootAscii/source/BOOT.ASM"
if ($LASTEXITCODE -ne 0) { throw 'BOOT.ASM symbol pass failed.' }
& python (Join-Path $ProjectRoot 'tools\make_core32_ext_symbols.py') `
    --source (Join-Path $ProjectRoot 'source\CORE32_EXT.ASM') `
    --source (Join-Path $ProjectRoot 'source\plugins\filex\FILEX.ASM') `
    --source (Join-Path $ProjectRoot 'source\plugins\filex\FILEX_RUNTIME.ASM') `
    --symbols $CoreSymbolMap `
    --output $CoreInterface
if ($LASTEXITCODE -ne 0) { throw 'CORE32 extension interface generation failed.' }

# Claude - 2026-09-27 - begin
# Код ядра (#4000..DR1) лежит в boot.$C HR-потоком, драйверы DR1..DR4 и DEHR —
# как есть (BOOT.ASM): так файл короче на ~1,1 КиБ. Байты — из символического
# прохода, где CORE32 лежит по #C00C как прежде. CORE32_RUNTIME.bin — весь
# рабочий образ #4000..END (им пользуются тесты).
$SymbolPassText = [IO.File]::ReadAllText($CoreSymbolMap)
function Get-SymbolPassAddress([string]$Name) {
    $match = [regex]::Match($SymbolPassText, "(?m)^$([regex]::Escape($Name)):\s+EQU\s+0x([0-9A-Fa-f]+)")
    if (-not $match.Success) { throw "$Name not found in boot.symbol-pass.sym." }
    [Convert]::ToInt32($match.Groups[1].Value, 16)
}
$CoreStart = Get-SymbolPassAddress 'WDOS.START'
$CoreEnd = Get-SymbolPassAddress 'WDOS.END'
$CoreDr1 = Get-SymbolPassAddress 'WDOS.DR1'
$CoreOffset = (Get-SymbolPassAddress 'WDOS.CORE32') - 0x6011
[byte[]]$SymbolPassBytes = [IO.File]::ReadAllBytes($CoreSymbolPayload)
if ($SymbolPassBytes[$CoreOffset - 12] -ne 0x21) { throw 'CORE32 not found at WDOS.CORE32 in the symbol pass.' }
[byte[]]$CoreRuntime = $SymbolPassBytes[$CoreOffset..($CoreOffset + $CoreEnd - $CoreStart - 1)]
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'CORE32_RUNTIME.bin'), $CoreRuntime)
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'CORE32_CODE.bin'), [byte[]]$CoreRuntime[0..($CoreDr1 - $CoreStart - 1)])
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'CORE32_RAW.bin'),
    [byte[]]$CoreRuntime[($CoreDr1 - $CoreStart)..($CoreRuntime.Length - 1)])
Remove-Item -LiteralPath (Join-Path $BuildDir 'CORE32_CODE.CPD'), (Join-Path $BuildDir 'CORE32_CODE.verify.bin') `
    -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $Mhmt '-hst' '-zxh' "$ProjectRootAscii/Build/CORE32_CODE.bin" "$ProjectRootAscii/Build/CORE32_CODE.CPD" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'CORE32 code packing failed.' }
    Set-HrustPackedLength -Path (Join-Path $BuildDir 'CORE32_CODE.CPD')
    & $Mhmt '-hst' '-zxh' '-d' "$ProjectRootAscii/Build/CORE32_CODE.CPD" "$ProjectRootAscii/Build/CORE32_CODE.verify.bin" | Out-Null
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'CORE32 code stream verification failed.' }
if ((Get-FileHash -LiteralPath (Join-Path $BuildDir 'CORE32_CODE.bin') -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $BuildDir 'CORE32_CODE.verify.bin') -Algorithm SHA256).Hash) {
    throw 'CORE32 code stream does not unpack byte-for-byte.'
}
Remove-Item -LiteralPath (Join-Path $BuildDir 'CORE32_CODE.verify.bin') -Force
# Claude - 2026-09-27 - end

Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--raw=$ProjectRootAscii/Build/CORE32_EXT.bin" `
        "--sym=$ProjectRootAscii/Build/CORE32_EXT.sym" `
        "--lst=$ProjectRootAscii/Build/CORE32_EXT.lst" `
        "$ProjectRootAscii/source/CORE32_EXT_BUILD.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'CORE32_EXT.ASM assembly failed.' }
if ((Get-Item -LiteralPath $ExtensionRaw).Length -gt 0x4000) {
    throw 'CORE32 extension exceeds one 16-KiB physical page.'
}

# Claude - 2026-09-27 - begin
# Расширение — две части: часть 1 (в boot.$C перед #BF60) и часть 2 (хвост
# boot.$C за образом ядра). Весь boot.$C — не длиннее 32768 байт: BIOS TS-Conf
# читает его целыми кластерами с #6000, и при кластере 32 КиБ второй кластер
# через #FFFF затирал #0000..#5FFF — машина падала до старта WC (BOOT.ASM,
# стенд combo64). Поэтому граница частей — по месту: проход замера BOOT.ASM
# без потоков даёт начало потока части 1 и хвоста, а tools/split_extension.py
# ищет границу, при которой поток части 1 влезает до #BF60, поток части 2 — в
# хвост до #E000 и на место потока части 1 (туда его переносит установщик), и
# обе части распаковываются обратно (двоичный поиск и окно вокруг него: длина
# потока растёт с границей не строго, Codex R37-3; части — от 16 байт, R37-4).
# Каждая часть затем пакуется и сверяется ещё раз; адрес начала части 2
# получает BOOT.ASM (Build/CORE32_EXT_PARTS.INC).
$MeasureSymbols = Join-Path $BuildDir 'boot.measure.sym'
Remove-Item -LiteralPath $MeasureSymbols, (Join-Path $BuildDir 'boot.measure.bin') `
    -Force -ErrorAction SilentlyContinue
& $SjasmPlus '--nologo' '--msg=err' '-DWDOS_MEASURE_PASS=1' `
    "--raw=$ProjectRootAscii/Build/boot.measure.bin" `
    "--sym=$ProjectRootAscii/Build/boot.measure.sym" `
    "$ProjectRootAscii/source/BOOT.ASM"
if ($LASTEXITCODE -ne 0) { throw 'BOOT.ASM measure pass failed.' }
$MeasureText = [IO.File]::ReadAllText($MeasureSymbols)
function Get-MeasuredAddress([string]$Name) {
    $match = [regex]::Match($MeasureText, "(?m)^$([regex]::Escape($Name)):\s+EQU\s+0x([0-9A-Fa-f]+)")
    if (-not $match.Success) { throw "$Name not found in boot.measure.sym." }
    [Convert]::ToInt32($match.Groups[1].Value, 16)
}
$Part1Room = 0xBF60 - (Get-MeasuredAddress 'WDOS_EXTENSION_PACKED')
$Part2Room = 0xE000 - (Get-MeasuredAddress 'WDOS_EXTENSION2_PACKED') - 2   # за потоком — метка сборки
[byte[]]$ExtensionBytes = [IO.File]::ReadAllBytes($ExtensionRaw)
$SplitText = & python (Join-Path $ProjectRoot 'tools\split_extension.py') `
    --raw "$ProjectRootAscii/Build/CORE32_EXT.bin" --part1-room $Part1Room --part2-room $Part2Room `
    --mhmt $Mhmt --work "$ProjectRootAscii/Build"
if ($LASTEXITCODE -ne 0) {
    throw ('boot.$C не помещается в 32768 байт: нет границы частей расширения при месте части 1 ' +
           $Part1Room + ' и хвосте ' + $Part2Room + '.')
}
$SplitMatch = [regex]::Match(($SplitText -join "`n"), 'split=(\d+) part1=(\d+) part2=(\d+)')
if (-not $SplitMatch.Success) { throw "Unexpected split_extension.py output: $SplitText" }
$Part2Offset = [int]$SplitMatch.Groups[1].Value
$Part2PackedLength = [int]$SplitMatch.Groups[3].Value
$Part2Start = 0xC000 + $Part2Offset
Write-Host ("CORE32 extension split at #{0:X4}: part 2 stream {1} of {2} bytes of tail room" -f `
    $Part2Start, $Part2PackedLength, $Part2Room)
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'CORE32_EXT1.bin'), [byte[]]$ExtensionBytes[0..($Part2Offset - 1)])
[IO.File]::WriteAllBytes((Join-Path $BuildDir 'CORE32_EXT2.bin'),
    [byte[]]$ExtensionBytes[$Part2Offset..($ExtensionBytes.Length - 1)])
foreach ($ExtensionPart in @(@('CORE32_EXT1.bin', 'CORE32_EXT.CPD', 'CORE32_EXT1.verify.bin'),
                              @('CORE32_EXT2.bin', 'CORE32_EXT2.CPD', 'CORE32_EXT2.verify.bin'))) {
    $PartRaw, $PartPacked, $PartVerify = $ExtensionPart
    Push-Location -LiteralPath $ProjectRootAlias
    try {
        & $Mhmt '-hst' '-zxh' `
            "$ProjectRootAscii/Build/$PartRaw" `
            "$ProjectRootAscii/Build/$PartPacked"
        if ($LASTEXITCODE -ne 0) { throw "CORE32 extension packing failed: $PartRaw" }
        # Codex - 2026-07-17 - begin
        Set-HrustPackedLength -Path (Join-Path $BuildDir $PartPacked)
        # Codex - 2026-07-17 - end
        & $Mhmt '-hst' '-zxh' '-d' `
            "$ProjectRootAscii/Build/$PartPacked" `
            "$ProjectRootAscii/Build/$PartVerify"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw "CORE32 packed extension verification failed: $PartPacked" }
    $PartRawHash = (Get-FileHash -LiteralPath (Join-Path $BuildDir $PartRaw) -Algorithm SHA256).Hash
    $PartVerifyHash = (Get-FileHash -LiteralPath (Join-Path $BuildDir $PartVerify) -Algorithm SHA256).Hash
    if ($PartRawHash -ne $PartVerifyHash) {
        throw "CORE32 packed extension does not unpack byte-for-byte: $PartPacked"
    }
    Remove-Item -LiteralPath (Join-Path $BuildDir $PartVerify) -Force
}
[IO.File]::WriteAllText((Join-Path $BuildDir 'CORE32_EXT_PARTS.INC'),
    ("; Claude - 2026-09-27: создано build.ps1`nWDOS_EXT_PART2_START EQU 0x{0:X4}`n" -f $Part2Start))
$global:LASTEXITCODE = 0
# Claude - 2026-09-27 - end

# API 77 lives in a mandatory one-page type-#06 provider. Its installer is
# position independent at #8000; the implementation is called at #C010.
$FilexSource = Join-Path $ProjectRoot 'source\plugins\filex\FILEX.ASM'
$FilexOutput = Join-Path $BuildDir 'FILEX.WMF'
$FilexSymbols = Join-Path $BuildDir 'FILEX.sym'
$FilexListing = Join-Path $BuildDir 'FILEX.lst'
Remove-Item -LiteralPath $FilexOutput, $FilexSymbols, $FilexListing `
    -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--sym=$ProjectRootAscii/Build/FILEX.sym" `
        "--lst=$ProjectRootAscii/Build/FILEX.lst" `
        "$ProjectRootAscii/source/plugins/filex/FILEX.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'FILEX.ASM assembly failed.' }
if (-not (Test-Path -LiteralPath $FilexOutput -PathType Leaf)) {
    throw 'FILEX.WMF was not created.'
}
if ((Get-Item -LiteralPath $FilexOutput).Length -gt (512 + 0x4000)) {
    throw 'FILEX.WMF exceeds one 16-KiB runtime page.'
}

# TXTEDIT больше не берётся как непрозрачный готовый бинарник: безопасное
# сохранение и проверки границ обязаны собираться из проверяемого исходника.
$TxtEditSource = Join-Path $ProjectRoot 'source\plugins\txt_editor\TXTEDIT.ASM'
$TxtEditOutput = Join-Path $BuildDir 'TXTEDIT.WMF'
$TxtEditSymbols = Join-Path $BuildDir 'TXTEDIT.sym'
$TxtEditListing = Join-Path $BuildDir 'TXTEDIT.lst'
Remove-Item -LiteralPath $TxtEditOutput, $TxtEditSymbols, $TxtEditListing `
    -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--raw=$ProjectRootAscii/Build/TXTEDIT.WMF" `
        "--sym=$ProjectRootAscii/Build/TXTEDIT.sym" `
        "--lst=$ProjectRootAscii/Build/TXTEDIT.lst" `
        "$ProjectRootAscii/source/plugins/txt_editor/TXTEDIT.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT.ASM assembly failed.' }
if (-not (Test-Path -LiteralPath $TxtEditOutput -PathType Leaf)) {
    throw 'TXTEDIT.WMF was not created.'
}
# Заголовок занимает 512 байт, код начинается с #8000 и не должен дойти до
# ENTRYN=#B700, куда редактор копирует имя из аргумента менеджера.
if ((Get-Item -LiteralPath $TxtEditOutput).Length -gt (512 + 0x3700)) {
    throw 'TXTEDIT.WMF overlaps ENTRYN at #B700.'
}
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txtedit_safety.py')
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT machine safety tests failed.' }
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txtedit_editing.py')
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT machine editing tests failed.' }
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txtedit_features.py')
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT audit regression tests failed.' }
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txtedit_navigation.py')
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT cursor/exit regression tests failed.' }

# TXTVIEW.WMF собирается из исходников вместо старого эталонного RE.WMF.
# Потоковое чтение, UTF-8 и выбор CP866/CP1251 проверяются по тому же
# исходнику, что используется для поставляемого runtime.
& python (Join-Path $ProjectRoot 'tools\make_txthex_tables.py') --check
if ($LASTEXITCODE -ne 0) { throw 'TXT/HEX encoding tables are out of date.' }
$TxtHexOutput = Join-Path $BuildDir 'TXTVIEW.WMF'
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--raw=$ProjectRootAscii/Build/TXTVIEW.WMF" `
        "--sym=$ProjectRootAscii/Build/TXTVIEW.sym" `
        "--lst=$ProjectRootAscii/Build/TXTVIEW.lst" `
        "$ProjectRootAscii/source/plugins/txthex_viewer/TXTVIEW.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'TXTVIEW.ASM assembly failed.' }
if ((Get-Item -LiteralPath $TxtHexOutput).Length -gt (512 + 0x2800)) {
    throw 'TXTVIEW.WMF overlaps its row history at #A800.'
}
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txthex_viewer.py')
if ($LASTEXITCODE -ne 0) { throw 'TXT/HEX viewer machine regression tests failed.' }
# Codex - 2026-07-17 - end

# Графический просмотрщик VDAC2 собирается своим скриптом из source/plugins.
# Его готовый WMF находится в корне каталога плагина; build хранит только
# вспомогательные материалы. Ниже он включается в общий комплект exe/WC.
$TxtHexVdac2Project = Join-Path $ProjectRoot 'source\plugins\txthex_viewer_VDAC2'
$TxtHexVdac2Output = Join-Path $TxtHexVdac2Project 'TXTVIEW2.WMF'
& (Join-Path $TxtHexVdac2Project 'build.ps1') -AssemblerPath $SjasmPlus
if ($LASTEXITCODE -ne 0) { throw 'TXTVIEW2.WMF build failed.' }
if (-not (Test-Path -LiteralPath $TxtHexVdac2Output -PathType Leaf)) {
    throw 'TXTVIEW2.WMF was not created.'
}

# UNZIP хранится вместе с остальными исходниками плагинов и входит в runtime WC.
# Сборка здесь не позволяет следующему обновлению exe вернуть старый wc.ini
# без строки плагина или оставить устаревший бинарник.
$UnzipProject = Join-Path $ProjectRoot 'source\plugins\unzip.wmf'
$UnzipBuildScript = Join-Path $UnzipProject 'build.ps1'
$UnzipOutput = Join-Path $UnzipProject 'build\UNZIP.WMF'
if (-not (Test-Path -LiteralPath $UnzipBuildScript -PathType Leaf)) {
    throw "UNZIP build script not found: $UnzipBuildScript"
}
& $UnzipBuildScript
if ($LASTEXITCODE -ne 0) { throw 'UNZIP.WMF build failed.' }
if (-not (Test-Path -LiteralPath $UnzipOutput -PathType Leaf)) {
    throw 'UNZIP.WMF was not created.'
}

# WPLAYER поставляется из побайтово проверенного эталона. Восстановленный
# исходник пока не воспроизводит этот бинарник и в runtime не собирается.

# FTView собирается из локальных исходников и проверенного vendor SDK.
# Проверки исполняют собранный Z80-код, сверяют поток DMA и границы страниц.
# Только после их успеха ниже заменяется runtime; эталон его не перезаписывает.
$FtViewProject = Join-Path $ProjectRoot 'source\plugins\ftview'
$FtViewBuild = Join-Path $BuildDir 'ftview'
$FtViewOutput = Join-Path $FtViewBuild 'FTVIEW.WMF'
& python (Join-Path $FtViewProject 'build.py') --out $FtViewBuild
if ($LASTEXITCODE -ne 0) { throw 'FTVIEW.WMF build failed.' }
& python (Join-Path $FtViewProject 'tests\test_ftview.py') --out $FtViewBuild
if ($LASTEXITCODE -ne 0) { throw 'FTView Z80/DMA regression tests failed.' }
# Звук AVI на General Sound: код плагина вместе с ПЗУ GS и драйвером.
# Без образа ПЗУ GS (Unreal rom/gs105a.rom) тесты пропускаются.
& python (Join-Path $FtViewProject 'tests\test_gs.py') --out $FtViewBuild
if ($LASTEXITCODE -ne 0) { throw 'FTView General Sound tests failed.' }

# Claude - 2026-09-24 - begin
# VIDEO_PL (ролики TGV) собирается из исходника. Без правок исходник даёт
# побайтно эталонный VIDEO_PL.WMF v0.71. v0.77 перед звуком MP3 ищет NeoGS и
# проверяет, что MP3 влезает в его память (иначе предупреждает и пропускает
# звуковой блок), а при VDAC2 выводит кадры на FT812. OUTPUT в исходнике —
# video_pl.wmf в текущем каталоге, поэтому сборка идёт из Build.
$VideoPlProject = Join-Path $ProjectRoot 'source\plugins\video_pl'
$VideoPlOutput = Join-Path $BuildDir 'VIDEO_PL.WMF'
Remove-Item -LiteralPath $VideoPlOutput, (Join-Path $BuildDir 'VIDEO_PL.sym'),
    (Join-Path $BuildDir 'VIDEO_PL.lst') -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath (Join-Path $ProjectRootAlias 'Build')
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--sym=$ProjectRootAscii/Build/VIDEO_PL.sym" `
        "--lst=$ProjectRootAscii/Build/VIDEO_PL.lst" `
        "$ProjectRootAscii/source/plugins/video_pl/PLUGXX.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'VIDEO_PL assembly failed.' }
if (-not (Test-Path -LiteralPath $VideoPlOutput -PathType Leaf)) {
    throw 'VIDEO_PL.WMF was not created.'
}
# Код плеера вместе с ПЗУ GS: обычный GS, NeoGS и без GS.
& python (Join-Path $VideoPlProject 'tests\test_video_pl.py')
if ($LASTEXITCODE -ne 0) { throw 'VIDEO_PL tests failed.' }
# Вывод на FT812 (VDAC2): модель FT812 и DMA, график кадров, старт звука.
& python (Join-Path $VideoPlProject 'tests\test_video_pl_ft.py')
if ($LASTEXITCODE -ne 0) { throw 'VIDEO_PL FT812 tests failed.' }
# Claude - 2026-09-24 - end

# Claude - 2026-09-24 - begin
# PLM — менеджер загрузки плагинов: резидент в одну страницу, который держит
# плагины на диске и подгружает их при запуске. Он переписывает в RAM пять
# известных кусков кода WC, поэтому ниже, уже после сборки boot.$C, эталоны
# перехватов сверяются с собранным runtime.
$PlmSource = Join-Path $ProjectRoot 'source\plugins\plm\PLM.ASM'
$PlmOutput = Join-Path $BuildDir 'PLM.WMF'
Remove-Item -LiteralPath $PlmOutput, (Join-Path $BuildDir 'PLM.sym'),
    (Join-Path $BuildDir 'PLM.lst') -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $PlmSource -PathType Leaf)) {
    throw "PLM source not found: $PlmSource"
}
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--sym=$ProjectRootAscii/Build/PLM.sym" `
        "--lst=$ProjectRootAscii/Build/PLM.lst" `
        "$ProjectRootAscii/source/plugins/plm/PLM.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'PLM.ASM assembly failed.' }
if (-not (Test-Path -LiteralPath $PlmOutput -PathType Leaf)) {
    throw 'PLM.WMF was not created.'
}
# Заголовок 512 байт плюс одна страница пула: менеджер не имеет права занимать
# больше, чем он освобождает.
if ((Get-Item -LiteralPath $PlmOutput).Length -gt (512 + 0x4000)) {
    throw 'PLM.WMF exceeds one 16-KiB runtime page.'
}

# SETUP.WMF — настройки WC обычным плагином меню F10 («WC Setup», тип #03):
# диалога F9 в ядре больше нет. Плагин сам читает и пишет wc.ini, а первой
# строкой пишет версию из VERSION.ASM — ту же, что показывает заголовок WC.
$SetupOutput = Join-Path $BuildDir 'SETUP.WMF'
Remove-Item -LiteralPath $SetupOutput, (Join-Path $BuildDir 'SETUP.sym'),
    (Join-Path $BuildDir 'SETUP.lst') -Force -ErrorAction SilentlyContinue
Push-Location -LiteralPath $ProjectRootAlias
try {
    & $SjasmPlus '--nologo' '--msg=err' `
        "--sym=$ProjectRootAscii/Build/SETUP.sym" `
        "--lst=$ProjectRootAscii/Build/SETUP.lst" `
        "$ProjectRootAscii/source/plugins/setup/SETUP.ASM"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'SETUP.ASM assembly failed.' }
if (-not (Test-Path -LiteralPath $SetupOutput -PathType Leaf)) {
    throw 'SETUP.WMF was not created.'
}
# Правка текста wc.ini исполняется настоящим Z80: отметки, флаги, новые
# строки плагинов, ключи по секциям, строка версии и переполнение буфера.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_setup_plugin.py')
if ($LASTEXITCODE -ne 0) { throw 'SETUP plugin machine tests failed.' }
# Claude - 2026-09-24 - end

# Codex - 2026-07-16 - begin
$MainSourceAscii = "$ProjectRootAscii/source/BOOT.ASM"
$PayloadAscii = "$ProjectRootAscii/Build/boot.payload.bin"
$SymbolsAscii = "$ProjectRootAscii/Build/boot.sym"
$ListingAscii = "$ProjectRootAscii/Build/boot.lst"
# Codex - 2026-07-16 - end
$Payload = Join-Path $BuildDir 'boot.payload.bin'
$BootOutput = Join-Path $ExeDir 'boot.$C'

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'source\BOOT.ASM') -PathType Leaf)) {
    throw 'source\BOOT.ASM not found.'
}
Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $BootOutput -Force -ErrorAction SilentlyContinue

# Codex - 2026-07-16 - begin
# Карта символов и листинг нужны детерминированному Z80-харнессу: тесты
# обращаются к собранным процедурам, а не дублируют их адреса вручную.
& $SjasmPlus '--nologo' '--msg=err' "--raw=$PayloadAscii" `
    "--sym=$SymbolsAscii" "--lst=$ListingAscii" $MainSourceAscii
# Codex - 2026-07-16 - end
if ($LASTEXITCODE -ne 0) { throw 'BOOT.ASM assembly failed.' }
# Claude - 2026-09-26 - begin
# Отрицательный DS у sjasmplus — лишь предупреждение, и адрес уходит назад:
# ASSERT после такого DS проходит, а в образе оказывается лишний байт.
if (Select-String -LiteralPath (Join-Path $BuildDir 'boot.lst') -Pattern 'Negative BLOCK' -SimpleMatch -Quiet) {
    throw 'BOOT.ASM: negative DS (a module outgrew its fixed slot), see Build/boot.lst.'
}
# Claude - 2026-09-26 - end
# Claude - 2026-09-27 - begin
# За логическим концом (WDOS_BOOT_TAIL_END) sjasmplus дописал сам CORE32.ASM —
# он там ради символов WDOS.* (BOOT.ASM). Его образ должен совпасть с тем, что
# взят из символического прохода (CORE32_RUNTIME.bin); затем он отрезается.
# Payload — до логического конца, последний сектор Hobeta не добивается: весь
# boot.$C с 17 байтами заголовка — не длиннее 32768 байт (BOOT.ASM: BIOS
# TS-Conf читает файл целыми кластерами, кластер 32 КиБ).
$BootSymbolText = [IO.File]::ReadAllText((Join-Path $BuildDir 'boot.sym'))
$Part2EndMatch = [regex]::Match($BootSymbolText, '(?m)^WDOS_BOOT_TAIL_END:\s+EQU\s+0x([0-9A-Fa-f]+)')
if (-not $Part2EndMatch.Success) { throw 'WDOS_BOOT_TAIL_END not found in boot.sym.' }
$BootLogicalLength = [Convert]::ToInt32($Part2EndMatch.Groups[1].Value, 16) - 0x6011
[byte[]]$PayloadBytes = [IO.File]::ReadAllBytes($Payload)
$CoreRuntimeBytes = [IO.File]::ReadAllBytes((Join-Path $BuildDir 'CORE32_RUNTIME.bin'))
$TrailingCore = $BootLogicalLength + 12                  # за заглушкой #C000..#C00B
if ($PayloadBytes.Length -ne $TrailingCore + $CoreRuntimeBytes.Length) {
    throw "boot payload tail is not the CORE32 module: $($PayloadBytes.Length) bytes."
}
for ($i = 0; $i -lt $CoreRuntimeBytes.Length; $i++) {
    if ($PayloadBytes[$TrailingCore + $i] -ne $CoreRuntimeBytes[$i]) {
        throw ("CORE32 of the main pass differs from the symbol pass at +#{0:X4}." -f $i)
    }
}
[IO.File]::WriteAllBytes($Payload, [byte[]]$PayloadBytes[0..($BootLogicalLength - 1)])
$PayloadLength = (Get-Item -LiteralPath $Payload).Length
if ($PayloadLength -lt 0x7000 -or $PayloadLength -gt (0x8000 - 17)) {
    throw "Unexpected boot payload size: $PayloadLength"
}
# Claude - 2026-09-27 - end

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_fat_allocator_hint.py')
if ($LASTEXITCODE -ne 0) { throw 'FAT allocator hint machine tests failed.' }

# Claude - 2026-09-24 - begin
# Время новой записи каталога: GENTRY читает часы CMOS с проверкой BCD и
# диапазонов; сбитые часы или год раньше 2026 дают 2026-01-01 00:00.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_file_time.py')
if ($LASTEXITCODE -ne 0) { throw 'File time machine tests failed.' }
# Claude - 2026-09-24 - end

# Claude - 2026-09-25 - begin
# USPO (API 46) не виснет на потерянном отпускании клавиши, но ждёт клавишу,
# которую действительно держат (автоповтор PS/2 отмечает её снова).
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_key_release.py')
if ($LASTEXITCODE -ne 0) { throw 'Key release machine tests failed.' }
# RENAME с откатом: прежняя запись не удалилась — только что созданная
# удаляется, две записи на одной цепочке не остаются.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_rename.py')
if ($LASTEXITCODE -ne 0) { throw 'RENAME rollback machine tests failed.' }
# Граница data-кластеров своя у каждого тома (страница потока), а не общая
# ячейка расширения: панели на разных устройствах не выходят за свой раздел.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_volume_limit.py')
if ($LASTEXITCODE -ne 0) { throw 'Per-volume data cluster limit machine tests failed.' }
# Claude - 2026-09-25 - end

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_wcfx_copy_bounds.py')
if ($LASTEXITCODE -ne 0) { throw 'WCFX COPYF bounds machine tests failed.' }

# Окно хода F5 — одно на всю операцию: «Copying started», затем «Copying
# имя», полоса только растёт (настоящие CP_GO, PBPR и CP_*).
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_copy_window.py')
if ($LASTEXITCODE -ne 0) { throw 'F5 progress window machine tests failed.' }

# Codex - 2026-07-16 - begin
# Регрессионный плагин обязан пересобираться вместе с ядром, иначе автономный
# прогон в Unreal может незаметно проверить устаревший бинарный файл.
$Core32TestSource = Join-Path $ProjectRoot 'tests\core32_unreal\CORE32T.ASM'
$Core32TestOutput = Join-Path $BuildDir 'CORE32T.WMF'
if (Test-Path -LiteralPath $Core32TestSource -PathType Leaf) {
    Remove-Item -LiteralPath $Core32TestOutput -Force -ErrorAction SilentlyContinue
    Push-Location -LiteralPath $ProjectRootAlias
    try {
        & $SjasmPlus '--nologo' '--msg=err' `
            "--lst=$ProjectRootAscii/Build/CORE32T.lst" `
            "--sym=$ProjectRootAscii/Build/CORE32T.sym" `
            "$ProjectRootAscii/tests/core32_unreal/CORE32T.ASM"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw 'CORE32T.ASM assembly failed.' }
    if (-not (Test-Path -LiteralPath $Core32TestOutput -PathType Leaf)) {
        throw 'CORE32T.WMF was not created.'
    }
}

# Отдельный автономный тест типа #03 вызывает новый API 77 через публичный
# диспетчер. Он собирается всегда, но в боевой каталог exe не копируется.
$FilexTestSource = Join-Path $ProjectRoot 'tests\core32_unreal\FILEXT.ASM'
$FilexTestOutput = Join-Path $BuildDir 'FILEXT.WMF'
if (Test-Path -LiteralPath $FilexTestSource -PathType Leaf) {
    Remove-Item -LiteralPath $FilexTestOutput -Force -ErrorAction SilentlyContinue
    Push-Location -LiteralPath $ProjectRootAlias
    try {
        & $SjasmPlus '--nologo' '--msg=err' `
            "--lst=$ProjectRootAscii/Build/FILEXT.lst" `
            "--sym=$ProjectRootAscii/Build/FILEXT.sym" `
            "$ProjectRootAscii/tests/core32_unreal/FILEXT.ASM"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw 'FILEXT.ASM assembly failed.' }
    if (-not (Test-Path -LiteralPath $FilexTestOutput -PathType Leaf)) {
        throw 'FILEXT.WMF was not created.'
    }
    if ((Get-Item -LiteralPath $FilexTestOutput).Length -gt (512 + 0x4000)) {
        throw 'FILEXT.WMF exceeds one 16-KiB runtime page.'
    }
}

# Минимальный тест настоящего заполненного тома отделён от общей регрессии:
# его образ имеет ноль свободных кластеров и проверяет атомарный NO_SPACE.
$FilexNoSpaceSource = Join-Path $ProjectRoot 'tests\core32_unreal\FILEXNST.ASM'
$FilexNoSpaceOutput = Join-Path $BuildDir 'FILEXNST.WMF'
if (Test-Path -LiteralPath $FilexNoSpaceSource -PathType Leaf) {
    Remove-Item -LiteralPath $FilexNoSpaceOutput -Force -ErrorAction SilentlyContinue
    Push-Location -LiteralPath $ProjectRootAlias
    try {
        & $SjasmPlus '--nologo' '--msg=err' `
            "--lst=$ProjectRootAscii/Build/FILEXNST.lst" `
            "--sym=$ProjectRootAscii/Build/FILEXNST.sym" `
            "$ProjectRootAscii/tests/core32_unreal/FILEXNST.ASM"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw 'FILEXNST.ASM assembly failed.' }
    if (-not (Test-Path -LiteralPath $FilexNoSpaceOutput -PathType Leaf)) {
        throw 'FILEXNST.WMF was not created.'
    }
    if ((Get-Item -LiteralPath $FilexNoSpaceOutput).Length -gt (512 + 0x4000)) {
        throw 'FILEXNST.WMF exceeds one 16-KiB runtime page.'
    }
}
# Codex - 2026-07-16 - end

& python (Join-Path $ProjectRoot 'tools\pack_hobeta.py') $Payload $BootOutput `
    --length $BootLogicalLength --expected-size $PayloadLength
if ($LASTEXITCODE -ne 0) { throw 'HoBeta packing failed.' }
# Claude - 2026-09-27 - begin
if ((Get-Item -LiteralPath $BootOutput).Length -gt 0x8000) {
    throw 'boot.$C is longer than 32768 bytes: TS-Conf BIOS would not boot it from 32-KiB clusters.'
}
# Claude - 2026-09-27 - end

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_lfn_namespace.py')
if ($LASTEXITCODE -ne 0) { throw 'LFN/SFN namespace machine tests failed.' }

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_plugin_panel_refresh.py')
if ($LASTEXITCODE -ne 0) { throw 'Plugin panel refresh machine tests failed.' }

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_wcini_version.py')
if ($LASTEXITCODE -ne 0) { throw 'WCINI version compatibility tests failed.' }

# Шрифт и распаковщики из HR-потоков образа: настоящие установщик и VDAC.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_boot_resources.py')
if ($LASTEXITCODE -ne 0) { throw 'Boot resource unpacking tests failed.' }

# Шина SPI (SD и FT812 VDAC2) в покое до первого обращения WC: сброс TS-Config
# её не нормализует; установщик выполняет SpiBusIdle до FINI.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_spi_idle.py')
if ($LASTEXITCODE -ne 0) { throw 'SPI idle at start tests failed.' }

# Замороженный ABI: CURIT/GIPAG/DLSG и шлюз FILEX обязаны остаться на своих
# адресах, иначе уже собранные плагины входят в середину процедуры. Набор
# существовал, но в сборку включён не был, и сдвиг на 8 байт прошёл незамеченным.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_filex_abi.py')
if ($LASTEXITCODE -ne 0) { throw 'FILEX/WildDOS frozen ABI tests failed.' }

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_core32_regressions.py')
if ($LASTEXITCODE -ne 0) { throw 'CORE32 boundary/gate/rollback regressions failed.' }

& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_allocator_wrap.py')
if ($LASTEXITCODE -ne 0) { throw 'MKSG wrap/count/data preservation tests failed.' }

# Claude - 2026-09-25 - begin
# Сбои ввода-вывода посреди операций (аудит Codex): BUtoFAT не пишет FAT после
# отказа CURIT, DELFL сообщает об отказе освобождения цепочки. Нужен готовый
# exe/boot.$C, поэтому — здесь, рядом с регрессиями ядра.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_io_failures.py')
if ($LASTEXITCODE -ne 0) { throw 'I/O failure machine tests failed.' }
# Короткое имя длинного файла (расширение из 1–2 знаков), аварийные пути
# RENAME и MKDIR — настоящее ядро на носителе в памяти.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_crash_paths.py')
if ($LASTEXITCODE -ne 0) { throw 'Short name, RENAME and MKDIR crash-path tests failed.' }
# FILEX MOVE_RENAME каталога: откат записи «..» после неоднозначной записи;
# отказ удаления источника с LFN — сектор SFN перечитывается по месту.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_filex_move.py')
if ($LASTEXITCODE -ne 0) { throw 'FILEX MOVE rollback tests failed.' }
# FILEX SET_EOF32: отказ носителя после обнуления хвоста сектора — сектор
# возвращается из копии, файл остаётся прежним (с 2026-09-26).
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_filex_truncate.py')
if ($LASTEXITCODE -ne 0) { throw 'FILEX truncation fault tests failed.' }
# Даты для программ: API 58 бит 6 (время и дата изменения) и FILEX
# GET_METADATA — чтение атрибута и времён без записи (с 2026-09-26).
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_dates_api.py')
if ($LASTEXITCODE -ne 0) { throw 'File date API tests failed.' }
# Claude - 2026-09-25 - end

# Claude - 2026-09-25 - begin
# Время изменения при записи внутри файла и усечении через FILEX: настоящие
# FILEX, ядро и расширение на диске в памяти, порты CMOS отвечают часами.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_filex_time.py')
if ($LASTEXITCODE -ne 0) { throw 'FILEX modification time tests failed.' }
# Claude - 2026-09-25 - end

# Claude - 2026-09-21 - begin
# Кэш сектора FAT потока LOAD512/SAVE512/LOADNON: те же данные и флаги, что
# модель цепочки, одно чтение на сектор FAT и сброс кэша записью FAT с
# клона страницы, CURIT, DEVINI, DOS_SWP, HDD и NXTINI; цикл UCHN и DELEN.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_fat_stream_cache.py')
if ($LASTEXITCODE -ne 0) { throw 'CORE32 FAT stream cache tests failed.' }
# Claude - 2026-09-21 - end

# Claude - 2026-09-22 - begin
# Перезапись существующего файла (DELETE, MKFILE, APPEND) — путь плагина FTP:
# одна живая запись в каталоге, новая цепочка и содержимое, отсутствие
# потерянных кластеров и чтение новых данных через кэш сектора FAT.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_overwrite_path.py')
if ($LASTEXITCODE -ne 0) { throw 'CORE32 file overwrite path tests failed.' }
# Claude - 2026-09-22 - end

# Claude - 2026-09-26 - begin
# Короткое имя без «~n» для имени 8.3 с заглавными буквами: ПЗУ ищет boot.$C
# по «BOOT    $C» и после замены файла иначе его не находило.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_sfn_alias.py')
if ($LASTEXITCODE -ne 0) { throw 'CORE32 short-name alias tests failed.' }
# Claude - 2026-09-26 - end

# Плагины, меню и конфигурация — готовые runtime-файлы.
# boot.$C собирается выше, а WC_History.txt, WC_todo.txt и Help.txt (с
# 2026-09-27: F9 свободна, Ctrl+F5) ведутся самим Improved; остальные
# неизменяемые файлы берутся из локального эталона. Все они входят в хэш-аудит.
$ProjectOwnedRuntime = @(
    'boot.$C', 'WC_History.txt', 'WC_todo.txt', 'Help.txt',
    'WC\TXTEDIT.WMF', 'WC\TXTVIEW.WMF', 'WC\TXTVIEW2.WMF', 'WC\TXTVIEW2.LIC',
    'WC\UNZIP.WMF', 'WC\CHKDSK.WMF', 'WC\FTVIEW.WMF', 'WC\VIDEO_PL.WMF'
)
# Старое имя встречается только в эталоне. Не возвращаем второй просмотрщик
# в runtime при каждой сборке после переименования в TXTVIEW.WMF.
$RetiredRuntime = @('WC\RE.WMF')
Get-ChildItem -LiteralPath $ReferenceExe -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($ReferenceExe.Length + 1)
    if ($ProjectOwnedRuntime -inotcontains $relative -and $RetiredRuntime -inotcontains $relative) {
        $destination = Join-Path $ExeDir $relative
        $parent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [IO.File]::Copy($_.FullName, $destination, $true)
    }
}

# FILEX — обязательный type-#06 провайдер API 77. Он должен загрузиться до
# остальных плагинов, записать свою физическую страницу и исчезнуть из меню.
& python (Join-Path $ProjectRoot 'tools\install_filex_runtime.py') `
    --provider $FilexOutput `
    --wc-dir (Join-Path $ExeDir 'WC')
if ($LASTEXITCODE -ne 0) { throw 'FILEX runtime installation failed.' }

$TxtEditRuntime = Join-Path $ExeDir 'WC\TXTEDIT.WMF'
[IO.File]::Copy($TxtEditOutput, $TxtEditRuntime, $true)
[IO.File]::Copy($FtViewOutput, (Join-Path $ExeDir 'WC\FTVIEW.WMF'), $true)
[IO.File]::Copy($FtViewOutput, (Join-Path $FtViewProject 'ftview.wmf'), $true)
[IO.File]::Copy($VideoPlOutput, (Join-Path $ExeDir 'WC\VIDEO_PL.WMF'), $true)
[IO.File]::Copy($VideoPlOutput, (Join-Path $VideoPlProject 'video_pl.wmf'), $true)
[IO.File]::Copy($TxtHexOutput, (Join-Path $ExeDir 'WC\TXTVIEW.WMF'), $true)
[IO.File]::Copy($TxtHexVdac2Output, (Join-Path $ExeDir 'WC\TXTVIEW2.WMF'), $true)
[IO.File]::Copy((Join-Path $TxtHexVdac2Project 'fonts\OFL.txt'),
    (Join-Path $ExeDir 'WC\TXTVIEW2.LIC'), $true)
# Удаляем единственное устаревшее имя из каталога результата: это позволяет
# обновлять уже собранный exe без повторной регистрации старого просмотрщика.
$LegacyViewerRuntime = Join-Path $ExeDir 'WC\RE.WMF'
if (Test-Path -LiteralPath $LegacyViewerRuntime -PathType Leaf) {
    Remove-Item -LiteralPath $LegacyViewerRuntime -Force
}

# wc.ini использует OEM-текст и исторические одиночные CR. Однобайтовое
# соответствие Latin-1 сохраняет каждый байт: заменяем только отдельный токен
# имени плагина, не перекодируем русские комментарии и не нормализуем строки.
# После копирования эталона имя ещё RE.WMF; повторная обработка TXTVIEW.WMF
# ничего не меняет. Параметры и комментарий на той же строке сохраняются.
$ViewerIniPath = Join-Path $ExeDir 'WC\wc.ini'
$ViewerByteEncoding = [Text.Encoding]::GetEncoding(28591)
$ViewerIniText = $ViewerByteEncoding.GetString([IO.File]::ReadAllBytes($ViewerIniPath))
$ViewerIniText = [regex]::Replace($ViewerIniText,
    '(?im)(^|[\r\n])([ \t]*)RE\.WMF(?=[ \t;\r\n]|$)', '$1$2TXTVIEW.WMF')
# Эталон содержит историческую версию 1.1, а уже собранный exe — версию
# прошлого выпуска. Поставляемый INI должен совпадать с заголовком Improved и
# с тем, что пишет SETUP.WMF при сохранении, поэтому первая строка приводится
# к версии из VERSION.ASM; OEM-байты комментариев и одиночные CR остаются как
# есть.
$VersionMatch = [regex]::Match(
    [IO.File]::ReadAllText((Join-Path $ProjectRoot 'source\VERSION.ASM')),
    'DEFINE\s+WC_VERSION\s+"([^"]+)"')
if (-not $VersionMatch.Success) { throw 'WC_VERSION not found in VERSION.ASM.' }
$ViewerIniText = [regex]::Replace($ViewerIniText,
    '\AWild Commander v1\.1[0-9]*i?(?=\r|\n|$)', $VersionMatch.Groups[1].Value)
# Сортировка панели по дате изменения (CSORT=4, Ctrl+F5) — в подсказке к ключу.
$ViewerIniText = $ViewerIniText.Replace('3 - by size)', '3 - by size, 4 - by date)')
# Строка информации (размер, дата и время изменения) под обеими панелями
# включена по умолчанию; подсказка к ключу остаётся из эталона.
$ViewerIniText = $ViewerIniText.Replace("`rINFO=0;", "`rINFO=1;")
[IO.File]::WriteAllBytes($ViewerIniPath, $ViewerByteEncoding.GetBytes($ViewerIniText))

# UNZIP запускается по Enter на расширении ZIP и располагается сразу после
# обязательного FILEX, который обязан сохранять первую позицию в списке.
& python (Join-Path $ProjectRoot 'tools\install_unzip_runtime.py') `
    --plugin $UnzipOutput `
    --wc-dir (Join-Path $ExeDir 'WC')
if ($LASTEXITCODE -ne 0) { throw 'UNZIP runtime installation failed.' }

# ChkDsk поставляется готовым runtime-бинарником из отдельного проекта. Автор
# патча AlexKorochinskiy: v0.07 центрирует окно плагина в текстовых режимах WC
# 80x25, 80x30 и 90x36. Сборка проверяет точную версию и число выделенных
# страниц, а затем восстанавливает его строку после UNZIP в wc.ini, который
# перед этим берётся из эталона.
$ChkdskRuntime = Join-Path $ExeDir 'WC\CHKDSK.WMF'
& python (Join-Path $ProjectRoot 'tools\install_chkdsk_runtime.py') `
    --plugin $ChkdskRuntime `
    --wc-dir (Join-Path $ExeDir 'WC')
if ($LASTEXITCODE -ne 0) { throw 'CHKDSK runtime installation failed.' }

# Claude - 2026-09-24 - begin
# Менеджер плагинов идёт второй строкой, сразу за обязательным FILEX: резидент
# обязан получить страницу пула раньше остальных плагинов, иначе их страницы
# останутся занятыми ниже его собственной.
& python (Join-Path $ProjectRoot 'tools\install_plm_runtime.py') `
    --plugin $PlmOutput `
    --wc-dir (Join-Path $ExeDir 'WC')
if ($LASTEXITCODE -ne 0) { throw 'PLM runtime installation failed.' }
# Плагин настроек — третьей строкой, за менеджером: в том же порядке ядро
# перечисляет плагины, если wc.ini нет, — тогда оно подсказывает открыть
# «WC Setup» из F10, и F2 в нём создаёт файл.
& python (Join-Path $ProjectRoot 'tools\install_setup_runtime.py') `
    --plugin $SetupOutput `
    --wc-dir (Join-Path $ExeDir 'WC')
if ($LASTEXITCODE -ne 0) { throw 'SETUP runtime installation failed.' }
# Эталоны перехватов сверяются с собранным boot.$C, а рабочие подпрограммы
# исполняются настоящим Z80 на модели страниц TS-Conf.
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_plugin_manager.py')
if ($LASTEXITCODE -ne 0) { throw 'Plugin manager machine tests failed.' }
# Claude - 2026-09-24 - end

# Claude - 2026-09-25 - begin
# Собственный набор UNZIP (Z80-модель плагина, Deflate, контракт WMF и
# wc.ini) прежде в сборку не входил и незаметно устарел. Здесь wc.ini уже
# окончательный. Плагин только что собран — повторно не собираем.
& (Join-Path $UnzipProject 'test.ps1') -SkipPluginBuild
if ($LASTEXITCODE -ne 0) { throw 'UNZIP plugin tests failed.' }
# Claude - 2026-09-25 - end

$HashReport = Join-Path $BuildDir 'hash-report.tsv'
& python (Join-Path $ProjectRoot 'tools\verify_hashes.py') `
    --actual $ExeDir `
    --reference $ReferenceExe `
    --format tsv `
    --output $HashReport
# Codex - 2026-07-16 - begin
$HashExitCode = $LASTEXITCODE
if ($HashExitCode -ne 0) {
    $Mismatches = @(
        Import-Csv -LiteralPath $HashReport -Delimiter "`t" |
            Where-Object { $_.status -ne 'MATCH' }
    )
    $ExpectedMismatchPaths = @(
        'boot.$C', 'WC_History.txt', 'WC_todo.txt', 'Help.txt',
        'WC/FILEX.WMF', 'WC/TXTEDIT.WMF', 'WC/RE.WMF', 'WC/TXTVIEW.WMF',
        'WC/TXTVIEW2.WMF', 'WC/TXTVIEW2.LIC', 'WC/UNZIP.WMF',
        'WC/CHKDSK.WMF', 'WC/FTVIEW.WMF', 'WC/VIDEO_PL.WMF', 'WC/PLM.WMF', 'WC/SETUP.WMF',
        'WC/wc.ini'
    )
    $MismatchPaths = @($Mismatches | ForEach-Object { $_.path })
    $Unexpected = @($MismatchPaths | Where-Object { $ExpectedMismatchPaths -inotcontains $_ })
    $MissingExpected = @($ExpectedMismatchPaths | Where-Object { $MismatchPaths -inotcontains $_ })
    if ($RequireExact -or $Unexpected.Count -ne 0 -or $MissingExpected.Count -ne 0 -or
        $Mismatches.Count -ne $ExpectedMismatchPaths.Count) {
        throw "Hash verification failed. See $HashReport"
    }
    # Переименование даёт две записи аудита: старое имя отсутствует, новое
    # добавлено. VDAC2 и лицензия его шрифта также являются новыми файлами.
    # Проверяем эти статусы явно; для остальных плагинов сохраняется прежний аудит.
    foreach ($Mismatch in $Mismatches) {
        $ExpectedStatus = switch ($Mismatch.path) {
            'WC/RE.WMF' { 'MISSING_ACTUAL' }
            'WC/TXTVIEW.WMF' { 'EXTRA_ACTUAL' }
            'WC/TXTVIEW2.WMF' { 'EXTRA_ACTUAL' }
            'WC/TXTVIEW2.LIC' { 'EXTRA_ACTUAL' }
            'WC/PLM.WMF' { 'EXTRA_ACTUAL' }
            'WC/SETUP.WMF' { 'EXTRA_ACTUAL' }
            default { $null }
        }
        if ($ExpectedStatus -and $Mismatch.status -ne $ExpectedStatus) {
            throw "Unexpected audit status for $($Mismatch.path): $($Mismatch.status)"
        }
    }
    Write-Warning 'boot.$C, FILEX, TXTEDIT, TXTVIEW (renamed from RE), TXTVIEW2 with font license, UNZIP, CHKDSK, FTVIEW, VIDEO_PL, PLM plugin manager, SETUP settings plugin, runtime config and Improved history intentionally differ from the reference; all other runtime files match.'
    # Ожидаемые отличия уже строго проверены. Не оставлять код 1
    # verify_hashes.py в $LASTEXITCODE: вызывающий автономный цикл иначе
    # ошибочно принимает успешно завершённую сборку за провал.
    $global:LASTEXITCODE = 0
}
# Codex - 2026-07-16 - end

$BootHash = (Get-FileHash -LiteralPath $BootOutput -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "WC build complete: $BootOutput"
Write-Host ('boot.$C SHA-256: {0}' -f $BootHash)
Write-Host "Full exe audit: $HashReport"
