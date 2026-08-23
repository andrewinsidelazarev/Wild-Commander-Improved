param([switch]$FullOnly)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$unrealRoot = Join-Path $env:USERPROFILE 'Desktop\Unreal'
$unrealExe = Join-Path $unrealRoot 'Unreal.exe'
$activeIni = Join-Path $unrealRoot 'Unreal.ini'
$helper = Join-Path $unrealRoot 'codex_wc_real.ps1'
$request = Join-Path $unrealRoot 'vkey.req'
$originalIni = [IO.File]::ReadAllBytes($activeIni)
$process = $null

function Invoke-PythonChecked {
    param([string[]]$Arguments)
    & python @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python failed: python $($Arguments -join ' ')"
    }
}

function Set-SdCard {
    param([string]$ImageName)
    $encoding = [Text.Encoding]::GetEncoding(866)
    $text = $encoding.GetString($originalIni)
    $updated = [regex]::Replace($text, '(?m)^SDCARD=.*$', "SDCARD=$ImageName")
    if ($updated -eq $text) { throw 'SDCARD line was not found in Unreal.ini' }
    [IO.File]::WriteAllBytes($activeIni, $encoding.GetBytes($updated))
    Write-Output "ACTIVE_SDCARD $ImageName"
}

function Send-VKey {
    param([string]$Name, [int]$Frames = 8, [int]$PauseMs = 150)
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

function Start-Unreal {
    if (Get-Process Unreal -ErrorAction SilentlyContinue) {
        throw 'Unreal is already running'
    }
    $script:process = Start-Process -FilePath $unrealExe -WorkingDirectory $unrealRoot -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 12
    $process.Refresh()
    if ($process.HasExited) { throw "Unreal exited during startup: $($process.ExitCode)" }
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

function Run-MenuPlugin {
    param([string]$Label, [string]$ImageName, [switch]$ConfirmTwice)
    Set-SdCard $ImageName
    Start-Unreal
    Capture-Unreal "test_20260823_${Label}_00_start.png"
    Send-VKey F10 12 700
    Capture-Unreal "test_20260823_${Label}_01_menu.png"
    Send-VKey ENTER 12 0
    if ($ConfirmTwice) {
        Start-Sleep -Seconds 1
        Send-VKey ENTER 12 0
    }
    Start-Sleep -Seconds 18
    Capture-Unreal "test_20260823_${Label}_02_after.png"
    Close-Unreal
}

function Run-AutoPlugin {
    param([string]$Label, [string]$ImageName)
    Set-SdCard $ImageName
    Start-Unreal
    Start-Sleep -Seconds 45
    Capture-Unreal "test_20260823_${Label}_02_after.png"
    Close-Unreal
}

$imageTool = Join-Path $projectRoot 'tests\core32_unreal\core32_image_test.py'
$exeRoot = Join-Path $projectRoot 'exe'
$corePlugin = Join-Path $projectRoot 'Build\CORE32T.WMF'
$filexPlugin = Join-Path $projectRoot 'Build\FILEXT.WMF'
$matrix = @(
    @{ Label='core_spc1_mirrored'; Base='core32_lbacache_base_spc1.img'; Image='core32_lbacache_spc1_mirrored.img'; Mode='mirrored' },
    @{ Label='core_spc1_active1'; Base='core32_lbacache_base_spc1.img'; Image='core32_lbacache_spc1_active1.img'; Mode='active1' },
    @{ Label='core_spc8_mirrored'; Base='core32_lbacache_base_spc8.img'; Image='core32_lbacache_spc8_mirrored.img'; Mode='mirrored' },
    @{ Label='core_spc8_active1'; Base='core32_lbacache_base_spc8.img'; Image='core32_lbacache_spc8_active1.img'; Mode='active1' }
)

try {
    if (-not $FullOnly) { foreach ($scenario in $matrix) {
        Write-Output "SCENARIO_BEGIN $($scenario.Label)"
        Invoke-PythonChecked @(
            $imageTool, 'prepare',
            '--base', (Join-Path $unrealRoot $scenario.Base),
            '--image', (Join-Path $unrealRoot $scenario.Image),
            '--exe', $exeRoot, '--plugin', $corePlugin,
            '--filex-test-plugin', $filexPlugin, '--mode', $scenario.Mode
        )
        Run-MenuPlugin $scenario.Label $scenario.Image
        Invoke-PythonChecked @($imageTool, 'inspect', '--image', (Join-Path $unrealRoot $scenario.Image))
        Write-Output "SCENARIO_PASS $($scenario.Label)"
    } }

    $fullImage = 'filex_spc1_full.img'
    Write-Output 'SCENARIO_BEGIN filex_full'
    Invoke-PythonChecked @(
        $imageTool, 'prepare-full',
        '--base', (Join-Path $unrealRoot 'core32_lbacache_base_spc8.img'),
        '--image', (Join-Path $unrealRoot $fullImage), '--exe', $exeRoot,
        '--filex-no-space-plugin', (Join-Path $projectRoot 'Build\FILEXNST.WMF')
    )
    Run-AutoPlugin 'filex_full' $fullImage
    Invoke-PythonChecked @($imageTool, 'inspect-full', '--image', (Join-Path $unrealRoot $fullImage))
    Write-Output 'SCENARIO_PASS filex_full'
    Write-Output 'CORE32_MATRIX_UNREAL_PASS'
} finally {
    if ([IO.File]::Exists($request)) { Remove-Item -LiteralPath $request -Force }
    if ($process -and -not $process.HasExited) {
        Write-Output "FORCED_CLEANUP pid=$($process.Id)"
        Stop-Process -Id $process.Id -Force
    }
    [IO.File]::WriteAllBytes($activeIni, $originalIni)
    Write-Output 'UNREAL_INI_RESTORED'
}
