param(
    [ValidateSet('Select', 'Save')]
    [string]$Mode = 'Select',
    [int]$DownCount = 23,
    [int]$PageDownCount = 0,
    [int]$TailDownCount = 0,
    [switch]$SelectLast,
    [string]$CapturePrefix = 'txtedit_cold'
)

$ErrorActionPreference = 'Stop'
$unrealRoot = Join-Path $env:USERPROFILE 'Desktop\Unreal'
$unrealExe = Join-Path $unrealRoot 'Unreal.exe'
$helper = Join-Path $unrealRoot 'codex_wc_real.ps1'
$request = Join-Path $unrealRoot 'vkey.req'

function Send-VKey {
    param([string]$Name, [int]$Frames = 4, [int]$PauseMs = 100)
    if ([IO.File]::Exists($request)) {
        throw "Previous vkey request was not consumed: $request"
    }
    [IO.File]::WriteAllText(
        $request,
        "$Name $Frames`n",
        [Text.UTF8Encoding]::new($false)
    )
    $deadline = (Get-Date).AddSeconds(5)
    while ([IO.File]::Exists($request) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 15
    }
    if ([IO.File]::Exists($request)) {
        throw "vkey request was not consumed: $Name"
    }
    Start-Sleep -Milliseconds $PauseMs
}

function Capture-Unreal {
    param([int]$ProcessId, [string]$Name)
    Push-Location $unrealRoot
    try {
        $capture = @(& $helper -Action capture -TargetId $ProcessId -Out $Name 2>&1)
        $capture | ForEach-Object { Write-Output $_ }
        if (($capture -join "`n") -notmatch 'CAPTURED') {
            throw "Unreal capture failed: $Name"
        }
    } finally {
        Pop-Location
    }
}

if (Get-Process Unreal -ErrorAction SilentlyContinue) {
    throw 'Unreal is already running'
}

$process = $null
try {
    $process = Start-Process -FilePath $unrealExe -WorkingDirectory $unrealRoot -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 8
    $process.Refresh()
    if ($process.HasExited) {
        throw "Unreal exited during startup: $($process.ExitCode)"
    }

    Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_00_root.png"
    Send-VKey -Name ENTER -Frames 8 -PauseMs 250
    if ($SelectLast) {
        Send-VKey -Name END -Frames 4 -PauseMs 250
    } else {
        for ($index = 0; $index -lt $DownCount; $index++) {
            Send-VKey -Name DOWN -Frames 4 -PauseMs 20
        }
    }
    for ($index = 0; $index -lt $PageDownCount; $index++) {
        Send-VKey -Name PGDN -Frames 4 -PauseMs 250
    }
    for ($index = 0; $index -lt $TailDownCount; $index++) {
        Send-VKey -Name DOWN -Frames 4 -PauseMs 100
    }
    Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_01_selected.png"

    if ($Mode -eq 'Save') {
        Send-VKey -Name F4 -Frames 4 -PauseMs 1500
        Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_02_editor.png"
        for ($index = 0; $index -lt 3; $index++) {
            Send-VKey -Name DOWN -Frames 4 -PauseMs 150
        }
        for ($index = 0; $index -lt 11; $index++) {
            Send-VKey -Name RIGHT -Frames 4 -PauseMs 150
        }
        Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_02a_cursor.png"
        Send-VKey -Name SPACE -Frames 4 -PauseMs 100
        Send-VKey -Name ESC -Frames 4 -PauseMs 400
        Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_03_prompt.png"
        Send-VKey -Name LEFT -Frames 4 -PauseMs 120

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Send-VKey -Name ENTER -Frames 8 -PauseMs 0
        $panels = $false
        while ($stopwatch.ElapsedMilliseconds -lt 30000) {
            $process.Refresh()
            if ($process.HasExited) {
                throw "Unreal exited during save: $($process.ExitCode)"
            }
            $capture = "${CapturePrefix}_probe.png"
            Push-Location $unrealRoot
            try {
                $probe = @(& $helper -Action capture -TargetId $process.Id -Out $capture 2>&1)
            } finally {
                Pop-Location
            }
            if (($probe -join "`n") -match 'CAPTURED') {
                Add-Type -AssemblyName System.Drawing
                $bitmap = [Drawing.Bitmap]::FromFile((Join-Path $unrealRoot $capture))
                try {
                    $blue = 0
                    for ($y = 400; $y -lt [Math]::Min(600, $bitmap.Height); $y += 4) {
                        for ($x = 200; $x -lt [Math]::Min(650, $bitmap.Width); $x += 4) {
                            $color = $bitmap.GetPixel($x, $y)
                            if ($color.B -gt 90 -and $color.R -lt 80 -and $color.G -lt 80) {
                                $blue++
                            }
                        }
                    }
                } finally {
                    $bitmap.Dispose()
                }
                if ($blue -gt 500) {
                    $panels = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $panels) {
            throw 'Panels were not detected after TXTEDIT save'
        }
        [pscustomobject]@{
            SaveElapsedMs = $stopwatch.ElapsedMilliseconds
            PanelsDetected = $panels
            ProcessId = $process.Id
        }
        Capture-Unreal -ProcessId $process.Id -Name "${CapturePrefix}_04_after.png"
    }

    Push-Location $unrealRoot
    try {
        $close = @(& $helper -Action close -TargetId $process.Id 2>&1)
        $close | ForEach-Object { Write-Output $_ }
    } finally {
        Pop-Location
    }
    if (($close -join "`n") -notmatch 'CLOSE_POSTED ok=True') {
        throw 'Normal Unreal close request failed'
    }
    if (-not $process.WaitForExit(10000)) {
        throw 'Unreal did not exit after File -> Exit'
    }
    "UNREAL_CLOSED exit=$($process.ExitCode)"
} finally {
    if ([IO.File]::Exists($request)) {
        Remove-Item -LiteralPath $request -Force
    }
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
