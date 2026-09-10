# Сквозной прогон UNZIP.WMF в настоящем Wild Commander под Unreal:
# готовый образ FAT32 с WC, FILEX и новым UNZIP.WMF, тестовый TEST.ZIP последним
# в корне; клавиши через vkey.req патченного Unreal; проверка образа после.
param(
    [string]$Base = 'wc.img',
    [string]$Image = 'unzip_asm_test.img',
    [int]$WaitSeconds = 10,
    [int]$DownCount = -1,
    [string]$Archive = '',
    [string]$Plugin = '',
    [string]$CapturePrefix = 'unzip_asm'
)

$ErrorActionPreference = 'Stop'
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectRoot = (Resolve-Path (Join-Path $pluginRoot '..\..\..')).Path
$unrealRoot = Join-Path $env:USERPROFILE 'Desktop\Unreal'
$unrealExe = Join-Path $unrealRoot 'Unreal.exe'
$activeIni = Join-Path $unrealRoot 'Unreal.ini'
$helper = Join-Path $unrealRoot 'codex_wc_real.ps1'
$request = Join-Path $unrealRoot 'vkey.req'
$basePath = Join-Path $unrealRoot $Base
$imagePath = Join-Path $unrealRoot $Image
$fixture = Join-Path $pluginRoot 'tools\unreal_zip_fixture.py'
$archive = if ($Archive) { (Resolve-Path $Archive).Path } else { Join-Path $pluginRoot 'build\unzip-test.zip' }
$checker = Join-Path $pluginRoot 'tools\unreal_zip_check.py'
$originalIni = [IO.File]::ReadAllBytes($activeIni)
$process = $null

function Invoke-PythonChecked {
    param([string[]]$Arguments)
    $output = & cmd.exe /c ('python "' + ($Arguments -join '" "') + '" 2>&1')
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Output $_ }
        throw "Python failed: $($Arguments -join ' ')"
    }
    return @($output)
}

function Send-VKey {
    param([string]$Name, [int]$Frames = 4, [int]$PauseMs = 120)
    if ([IO.File]::Exists($request)) {
        throw "Previous vkey request was not consumed: $request"
    }
    [IO.File]::WriteAllText($request, "$Name $Frames`n", [Text.Encoding]::ASCII)
    $deadline = (Get-Date).AddSeconds(5)
    while ([IO.File]::Exists($request) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 15
    }
    if ([IO.File]::Exists($request)) { throw "vkey request was not consumed: $Name" }
    Start-Sleep -Milliseconds $PauseMs
}

function Capture-Unreal {
    param([string]$Name)
    Push-Location $unrealRoot
    try {
        $capture = @(& $helper -Action capture -TargetId $process.Id -Out $Name 2>&1)
    } finally {
        Pop-Location
    }
    $capture | ForEach-Object { Write-Output $_ }
    if (($capture -join "`n") -notmatch 'CAPTURED') {
        throw "Unreal capture failed: $Name"
    }
}

function Test-UnzipWindow {
    # $true — окно «ZIP unpacker» на экране: в полосе строк 255..280 есть строка,
    # где больше 60 % пикселей между x=130 и x=600 почти белые (рамка окна).
    $name = "${CapturePrefix}_probe.png"
    Push-Location $unrealRoot
    try {
        $probe = @(& $helper -Action capture -TargetId $process.Id -Out $name 2>&1)
    } finally {
        Pop-Location
    }
    if (($probe -join "`n") -notmatch 'CAPTURED') { return $true }
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::FromFile((Join-Path $unrealRoot $name))
    try {
        for ($y = 255; $y -le [Math]::Min(280, $bitmap.Height - 1); $y++) {
            $white = 0
            for ($x = 130; $x -lt 600; $x++) {
                $color = $bitmap.GetPixel($x, $y)
                if ($color.R -gt 200 -and $color.G -gt 200 -and $color.B -gt 200) { $white++ }
            }
            if ($white -gt 282) { return $true }
        }
        return $false
    } finally {
        $bitmap.Dispose()
    }
}

function Close-Unreal {
    Push-Location $unrealRoot
    try {
        $close = @(& $helper -Action close -TargetId $process.Id 2>&1)
    } finally {
        Pop-Location
    }
    $close | ForEach-Object { Write-Output $_ }
    if (($close -join "`n") -notmatch 'CLOSE_POSTED ok=True') {
        throw 'Normal Unreal close request failed'
    }
    if (-not $process.WaitForExit(10000)) {
        throw 'Unreal did not exit after File -> Exit'
    }
    Write-Output "UNREAL_CLOSED exit=$($process.ExitCode)"
    $script:process = $null
}

try {
    if (Get-Process Unreal -ErrorAction SilentlyContinue) {
        throw 'Unreal is already running'
    }
    if (-not (Test-Path -LiteralPath $basePath)) { throw "Base image not found: $basePath" }

    Invoke-PythonChecked @((Join-Path $pluginRoot 'tools\make_test_zip.py')) | ForEach-Object { Write-Output $_ }
    Copy-Item -LiteralPath $basePath -Destination $imagePath -Force
    $prepare = Invoke-PythonChecked @($fixture, 'prepare', '--image', $imagePath, '--exe', (Join-Path $projectRoot 'exe'), '--archive', $archive)
    $prepare | ForEach-Object { Write-Output $_ }
    if ($Plugin) {
        # Другой UNZIP.WMF (например, прежняя версия из git) — для сравнения
        $refresh = Invoke-PythonChecked @($fixture, 'refresh-plugin', '--image', $imagePath, '--plugin', (Resolve-Path $Plugin).Path, '--allow-used')
        $refresh | ForEach-Object { Write-Output $_ }
    }
    if ($DownCount -lt 0) {
        # TEST.ZIP занимает первую свободную запись каталога, не обязательно последнюю
        # @() обязателен: одна строка вернулась бы строкой, и [-1] дал бы символ
        $DownCount = [int]@(Invoke-PythonChecked @($checker, 'index', '--image', $imagePath, '--name', 'TEST.ZIP'))[-1]
    }
    Write-Output "DOWN_COUNT $DownCount"

    $encoding = [Text.Encoding]::GetEncoding(866)
    $iniText = $encoding.GetString($originalIni)
    if ($iniText -notmatch '(?m)^SDCARD=') { throw 'SDCARD line was not found in Unreal.ini' }
    $updatedIni = [regex]::Replace($iniText, '(?m)^SDCARD=.*$', "SDCARD=$Image")
    [IO.File]::WriteAllBytes($activeIni, $encoding.GetBytes($updatedIni))
    Write-Output "ACTIVE_SDCARD $Image"

    $process = Start-Process -FilePath $unrealExe -WorkingDirectory $unrealRoot -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 8
    $process.Refresh()
    if ($process.HasExited) { throw "Unreal exited during startup: $($process.ExitCode)" }

    # Заставки нет: обе панели в корне, активна правая, курсор на первой
    # записи. TEST.ZIP — на позиции DownCount по физическому порядку каталога.
    Capture-Unreal "${CapturePrefix}_00_boot.png"
    for ($index = 0; $index -lt $DownCount; $index++) {
        Send-VKey DOWN 4 150
    }
    Capture-Unreal "${CapturePrefix}_02_selected.png"
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Send-VKey ENTER 8 1500                   # запуск UNZIP.WMF
    Capture-Unreal "${CapturePrefix}_03_running.png"
    # Каждые 2 с снимок экрана: пока окно плагина открыто, его верхняя рамка —
    # сплошная белая строка пикселей. Исчезла — распаковка закончилась.
    $finished = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt $WaitSeconds) {
        Start-Sleep -Seconds 2
        if (-not (Test-UnzipWindow)) { $finished = $true; break }
    }
    Write-Output "ELAPSED_MS $($stopwatch.ElapsedMilliseconds) FINISHED=$finished"
    Capture-Unreal "${CapturePrefix}_04_after.png"

    Close-Unreal
    $inspect = Invoke-PythonChecked @($checker, 'inspect', '--image', $imagePath, '--archive', $archive)
    $inspect | ForEach-Object { Write-Output $_ }
    Write-Output 'UNZIP_UNREAL_RUN_DONE'
} finally {
    if ([IO.File]::Exists($request)) { Remove-Item -LiteralPath $request -Force }
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    [IO.File]::WriteAllBytes($activeIni, $originalIni)
}
