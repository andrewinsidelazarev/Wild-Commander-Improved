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
Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'source') -Recurse -File |
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

Push-Location -LiteralPath $ProjectRootAlias
try {
    & $Mhmt '-hst' '-zxh' `
        "$ProjectRootAscii/Build/CORE32_EXT.bin" `
        "$ProjectRootAscii/Build/CORE32_EXT.CPD"
    if ($LASTEXITCODE -ne 0) { throw 'CORE32 extension packing failed.' }
    # Codex - 2026-07-17 - begin
    Set-HrustPackedLength -Path $ExtensionPacked
    # Codex - 2026-07-17 - end
    & $Mhmt '-hst' '-zxh' '-d' `
        "$ProjectRootAscii/Build/CORE32_EXT.CPD" `
        "$ProjectRootAscii/Build/CORE32_EXT.verify.bin"
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'CORE32 packed extension verification failed.' }
$ExtensionRawHash = (Get-FileHash -LiteralPath $ExtensionRaw -Algorithm SHA256).Hash
$ExtensionVerifyHash = (Get-FileHash -LiteralPath $ExtensionVerify -Algorithm SHA256).Hash
if ($ExtensionRawHash -ne $ExtensionVerifyHash) {
    throw 'CORE32 packed extension does not unpack byte-for-byte.'
}
Remove-Item -LiteralPath $ExtensionVerify -Force
$global:LASTEXITCODE = 0

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
# ENTRYN=#A600, где менеджер передаёт редактору имя файла.
if ((Get-Item -LiteralPath $TxtEditOutput).Length -gt (512 + 0x2600)) {
    throw 'TXTEDIT.WMF overlaps ENTRYN at #A600.'
}
& python (Join-Path $ProjectRoot 'tests\core32_unreal\test_txtedit_safety.py')
if ($LASTEXITCODE -ne 0) { throw 'TXTEDIT machine safety tests failed.' }
# Codex - 2026-07-17 - end

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
if ((Get-Item -LiteralPath $Payload).Length -ne 0x7C00) {
    throw "Unexpected boot payload size: $((Get-Item -LiteralPath $Payload).Length)"
}

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

& python (Join-Path $ProjectRoot 'tools\pack_hobeta.py') $Payload $BootOutput
if ($LASTEXITCODE -ne 0) { throw 'HoBeta packing failed.' }

# Плагины, меню и конфигурация — готовые runtime-файлы.
# boot.$C собирается выше, а WC_History.txt и WC_todo.txt ведутся самим
# Improved; остальные неизменяемые файлы берутся из локального эталона.
# Все они входят в хэш-аудит.
$ProjectOwnedRuntime = @(
    'boot.$C', 'WC_History.txt', 'WC_todo.txt', 'WC\TXTEDIT.WMF'
)
Get-ChildItem -LiteralPath $ReferenceExe -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($ReferenceExe.Length + 1)
    if ($ProjectOwnedRuntime -inotcontains $relative) {
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
        'boot.$C', 'WC_History.txt', 'WC_todo.txt',
        'WC/FILEX.WMF', 'WC/TXTEDIT.WMF', 'WC/wc.ini'
    )
    $MismatchPaths = @($Mismatches | ForEach-Object { $_.path })
    $Unexpected = @($MismatchPaths | Where-Object { $ExpectedMismatchPaths -inotcontains $_ })
    $MissingExpected = @($ExpectedMismatchPaths | Where-Object { $MismatchPaths -inotcontains $_ })
    if ($RequireExact -or $Unexpected.Count -ne 0 -or $MissingExpected.Count -ne 0 -or
        $Mismatches.Count -ne $ExpectedMismatchPaths.Count) {
        throw "Hash verification failed. See $HashReport"
    }
    Write-Warning 'boot.$C, FILEX, TXTEDIT, runtime config and Improved history files intentionally differ from the reference; all other runtime files match.'
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
