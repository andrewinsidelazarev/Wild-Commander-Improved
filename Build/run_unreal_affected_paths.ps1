param()

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
    $output = & python @Arguments 2>&1
    $output | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "Python failed: python $($Arguments -join ' ')"
    }
    return @($output)
}

function Set-SdCard {
    param([string]$ImageName)
    $encoding = [Text.Encoding]::GetEncoding(866)
    $text = $encoding.GetString($originalIni)
    if ($text -notmatch '(?m)^SDCARD=') { throw 'SDCARD line was not found in Unreal.ini' }
    $updated = [regex]::Replace($text, '(?m)^SDCARD=.*$', "SDCARD=$ImageName")
    [IO.File]::WriteAllBytes($activeIni, $encoding.GetBytes($updated))
    Write-Output "ACTIVE_SDCARD $ImageName"
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

function Send-HostKeys {
    param([string]$Keys)
    Push-Location $unrealRoot
    try {
        $send = @(& $helper -Action send -TargetId $process.Id -Keys $Keys 2>&1)
    } finally {
        Pop-Location
    }
    $send | ForEach-Object { Write-Output $_ }
    if (($send -join "`n") -notmatch 'SENT') {
        throw "Host key send failed: $Keys"
    }
}

function Start-Unreal {
    if (Get-Process Unreal -ErrorAction SilentlyContinue) {
        throw 'Unreal is already running'
    }
    $script:process = Start-Process -FilePath $unrealExe -WorkingDirectory $unrealRoot -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 8
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

try {
    $wcfxImage = Join-Path $unrealRoot 'core32_current_ui_sd.img'
    Invoke-PythonChecked @(
        (Join-Path $projectRoot 'tests\core32_unreal\wcfx_copy_unreal.py'), 'prepare',
        '--base', (Join-Path $unrealRoot 'core32_lbacache_base_spc8.img'),
        '--image', $wcfxImage, '--exe', (Join-Path $projectRoot 'exe')
    ) | Out-Null
    Set-SdCard 'core32_current_ui_sd.img'
    Start-Unreal
    Capture-Unreal 'test_20260823_wcfx_00_root.png'
    Send-VKey ENTER 8 250
    Send-VKey TAB 4 150
    Send-VKey DOWN 4 150
    Send-VKey F5 4 250
    Send-VKey ENTER 8 0
    Start-Sleep -Seconds 15
    Capture-Unreal 'test_20260823_wcfx_01_after_copy.png'
    Send-VKey F6 4 300
    Send-VKey LEFT 4 100
    Send-VKey SPACE 4 100
    Send-VKey ENTER 8 1500
    Capture-Unreal 'test_20260823_wcfx_02_after_rename.png'
    Close-Unreal
    Invoke-PythonChecked @(
        (Join-Path $projectRoot 'tests\core32_unreal\wcfx_copy_unreal.py'), 'inspect',
        '--image', $wcfxImage, '--exe', (Join-Path $projectRoot 'exe'), '--renamed'
    ) | Out-Null

    Write-Output 'RUNNING_WCFX_RECURSIVE_F5_F8'
    & (Join-Path $projectRoot 'tests\core32_unreal\run_wcfx_recursive_unreal.ps1') -Depth 21

    $txtImage = Join-Path $unrealRoot 'txtedit_safe_spc1.img'
    $prepare = Invoke-PythonChecked @(
        (Join-Path $projectRoot 'tests\core32_unreal\txtedit_save_unreal.py'), 'prepare',
        '--base', (Join-Path $unrealRoot 'txtedit_clean_spc1.img'),
        '--image', $txtImage, '--exe', (Join-Path $projectRoot 'exe'),
        '--fsi-next-free', 'first-free'
    )
    $match = [regex]::Match(($prepare -join "`n"), 'wc_ini_cluster=(\d+)')
    if (-not $match.Success) { throw 'TXTEDIT old cluster was not reported' }
    $oldCluster = [int]$match.Groups[1].Value
    $nextMatch = [regex]::Match(($prepare -join "`n"), 'first_free=(\d+)')
    if (-not $nextMatch.Success) { throw 'TXTEDIT first free cluster was not reported' }
    $expectedNextFree = [int]$nextMatch.Groups[1].Value
    Set-SdCard 'txtedit_safe_spc1.img'
    Start-Unreal
    Capture-Unreal 'test_20260823_txtedit_00_root.png'
    Send-VKey ENTER 8 250
    for ($index = 0; $index -lt 23; $index++) { Send-VKey DOWN 4 20 }
    Send-VKey F4 4 1500
    for ($index = 0; $index -lt 3; $index++) { Send-VKey DOWN 4 120 }
    for ($index = 0; $index -lt 11; $index++) { Send-VKey RIGHT 4 120 }
    Send-VKey SPACE 4 100
    Send-VKey ESC 4 400
    Send-VKey LEFT 4 100
    Send-VKey ENTER 8 0
    Start-Sleep -Seconds 8
    Capture-Unreal 'test_20260823_txtedit_01_after_save.png'
    Close-Unreal
    Invoke-PythonChecked @(
        (Join-Path $projectRoot 'tests\core32_unreal\txtedit_save_unreal.py'), 'inspect',
        '--image', $txtImage, '--exe', (Join-Path $projectRoot 'exe'),
        '--comment-spaces', '1', '--old-cluster', "$oldCluster",
        '--expected-next-free', "$expectedNextFree"
    ) | Out-Null
    Write-Output 'AFFECTED_PATHS_UNREAL_PASS'
} finally {
    if ([IO.File]::Exists($request)) { Remove-Item -LiteralPath $request -Force }
    if ($process -and -not $process.HasExited) {
        Write-Output "FORCED_CLEANUP pid=$($process.Id)"
        Stop-Process -Id $process.Id -Force
    }
    [IO.File]::WriteAllBytes($activeIni, $originalIni)
    Write-Output 'UNREAL_INI_RESTORED'
}
