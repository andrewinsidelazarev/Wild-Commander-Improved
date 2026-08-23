param(
    [ValidateRange(4, 128)]
    [int]$Depth = 21,
    [ValidateSet('chain', 'siblings', 'lfn-siblings', 'async-smb')]
    [string]$Shape = 'chain',
    [switch]$DeleteOnly,
    [switch]$CopyOnly,
    [ValidateRange(1, 120)]
    [int]$OperationWaitSeconds = 25
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$unrealRoot = Join-Path $env:USERPROFILE 'Desktop\Unreal'
$unrealExe = Join-Path $unrealRoot 'Unreal.exe'
$activeIni = Join-Path $unrealRoot 'Unreal.ini'
$helper = Join-Path $unrealRoot 'codex_wc_real.ps1'
$request = Join-Path $unrealRoot 'vkey.req'
$image = Join-Path $unrealRoot 'core32_current_ui_sd.img'
$originalIni = [IO.File]::ReadAllBytes($activeIni)
$process = $null

function Invoke-PythonChecked {
    param([string[]]$Arguments)
    $output = & python @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Output $_ }
        throw "Python failed: python $($Arguments -join ' ')"
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
    if ($DeleteOnly -and $CopyOnly) {
        throw 'DeleteOnly and CopyOnly are mutually exclusive'
    }
    if (Get-Process Unreal -ErrorAction SilentlyContinue) {
        throw 'Unreal is already running'
    }

    $prepareOutput = Invoke-PythonChecked @(
        (Join-Path $projectRoot 'tests\core32_unreal\wcfx_copy_unreal.py'), 'prepare-tree',
        '--base', (Join-Path $unrealRoot 'core32_lbacache_base_spc8.img'),
        '--image', $image, '--exe', (Join-Path $projectRoot 'exe'),
        '--depth', "$Depth", '--shape', $Shape
    )
    $prepareOutput | ForEach-Object { Write-Output $_ }

    $encoding = [Text.Encoding]::GetEncoding(866)
    $iniText = $encoding.GetString($originalIni)
    if ($iniText -notmatch '(?m)^SDCARD=') {
        throw 'SDCARD line was not found in Unreal.ini'
    }
    $updatedIni = [regex]::Replace(
        $iniText,
        '(?m)^SDCARD=.*$',
        'SDCARD=core32_current_ui_sd.img'
    )
    [IO.File]::WriteAllBytes($activeIni, $encoding.GetBytes($updatedIni))
    Write-Output 'ACTIVE_SDCARD core32_current_ui_sd.img'

    $process = Start-Process `
        -FilePath $unrealExe `
        -WorkingDirectory $unrealRoot `
        -WindowStyle Normal `
        -PassThru
    Start-Sleep -Seconds 8
    $process.Refresh()
    if ($process.HasExited) { throw "Unreal exited during startup: $($process.ExitCode)" }

    Capture-Unreal 'test_20260823_recursive_00_root.png'
    Send-VKey ENTER 8 250
    Send-VKey TAB 4 150
    Send-VKey DOWN 4 150
    Capture-Unreal 'test_20260823_recursive_01_selected.png'

    if (-not $DeleteOnly) {
        Send-VKey F5 4 300
        Send-VKey ENTER 8 0
        Start-Sleep -Seconds $OperationWaitSeconds
        Capture-Unreal 'test_20260823_recursive_02_after_copy.png'
    }

    if (-not $CopyOnly) {
        Send-VKey F8 4 300
        Capture-Unreal 'test_20260823_recursive_03_delete_prompt.png'
        Send-VKey ENTER 8 0
        Start-Sleep -Seconds $OperationWaitSeconds
        Capture-Unreal 'test_20260823_recursive_04_after_delete.png'
    }

    Close-Unreal
    $inspectArguments = @(
        (Join-Path $projectRoot 'tests\core32_unreal\wcfx_copy_unreal.py'), 'inspect-tree',
        '--image', $image, '--exe', (Join-Path $projectRoot 'exe'),
        '--depth', "$Depth", '--shape', $Shape
    )
    if ($DeleteOnly) { $inspectArguments += '--delete-only' }
    if ($CopyOnly) { $inspectArguments += '--copy-only' }
    $inspectOutput = Invoke-PythonChecked $inspectArguments
    $inspectOutput | ForEach-Object { Write-Output $_ }
    Write-Output 'WCFX_RECURSIVE_UNREAL_PASS'
} finally {
    if ([IO.File]::Exists($request)) { Remove-Item -LiteralPath $request -Force }
    if ($process -and -not $process.HasExited) {
        try {
            Close-Unreal
        } catch {
            Stop-Process -Id $process.Id -Force
        }
    }
    [IO.File]::WriteAllBytes($activeIni, $originalIni)
    Write-Output 'UNREAL_INI_RESTORED'
}
