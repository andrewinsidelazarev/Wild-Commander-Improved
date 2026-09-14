param(
    [string]$AssemblerPath = $env:SJASMPLUS,
    [switch]$TestGraphics
)
$ErrorActionPreference = 'Stop'
$ViewerOutput = Join-Path $PSScriptRoot 'TXTVIEW2.WMF'
$ViewerWcRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$ViewerRuntimeDir = Join-Path $ViewerWcRoot 'exe\WC'
$ViewerRuntime = Join-Path $ViewerRuntimeDir 'TXTVIEW2.WMF'
# SjASMPlus использует узкие Win32 пути: временное ASCII-имя каталога
# создаём через subst, не копируя проект и не меняя его исходные пути.
$ViewerDrive = @('V','Y','X','Q') | Where-Object { -not (Test-Path ($_.ToString() + ':\')) } | Select-Object -First 1
if (-not $ViewerDrive) { throw 'No free drive letter for SjASMPlus path alias.' }
$ViewerAlias = $ViewerDrive + ':'
if (-not $AssemblerPath) {
    $AssemblerPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
}
if (-not (Test-Path -LiteralPath $AssemblerPath)) { throw "Assembler not found: $AssemblerPath" }
& subst $ViewerAlias $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'Cannot create temporary path alias.' }
Push-Location -LiteralPath $PSScriptRoot
try {
    python tools\gen_assets.py
    if ($LASTEXITCODE -ne 0) { throw 'Font generation failed.' }
    # Как у отдельных плагинов WC, готовый WMF создаётся рядом со скриптом.
    # Каталог build содержит только ресурсы, листинг и материалы проверок.
    & $AssemblerPath --nologo "--raw=$ViewerAlias/TXTVIEW2.WMF" "--sym=$ViewerAlias/build/TXTVIEW2.sym" "--lst=$ViewerAlias/build/TXTVIEW2.lst" "$ViewerAlias/src/main.asm"
    if ($LASTEXITCODE -ne 0) { throw 'TXTVIEW2 assembly failed.' }
    if ($TestGraphics) { python tests\test_viewer.py }
    else { python tests\test_viewer.py CoreTests }
    if ($LASTEXITCODE -ne 0) { throw 'TXTVIEW2 regression tests failed.' }
    # В загрузочный комплект попадает только успешно проверенный плагин.
    # Лицензия встроенного шрифта поставляется рядом с WMF; сам TTF WC не нужен.
    New-Item -ItemType Directory -Path $ViewerRuntimeDir -Force | Out-Null
    [IO.File]::Copy($ViewerOutput, $ViewerRuntime, $true)
    [IO.File]::Copy((Join-Path $PSScriptRoot 'fonts\OFL.txt'),
        (Join-Path $ViewerRuntimeDir 'TXTVIEW2.LIC'), $true)
    Write-Host "Plugin built: $ViewerOutput"
    Write-Host "WC runtime installed: $ViewerRuntime"
    Get-FileHash -Algorithm SHA256 -LiteralPath $ViewerRuntime
} finally {
    # Сборку вызывает и корневой build.ps1: его рабочий каталог надо сохранить.
    Pop-Location
    & subst $ViewerAlias /D
}
