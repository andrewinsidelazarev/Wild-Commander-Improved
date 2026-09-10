[CmdletBinding()]
param(
    [string]$SjasmPlus = 'U:\Desktop\sjasmplus\sjasmplus-1.21.0.win\sjasmplus.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$BuildDir = Join-Path $ProjectRoot 'build'

# sjasmplus не работает с путями вне ASCII: проект открывается через U:.
if (-not (Test-Path -LiteralPath 'U:\Desktop' -PathType Container)) {
    & subst.exe U: $env:USERPROFILE
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create U: ASCII path alias.' }
}

if (-not (Test-Path -LiteralPath $SjasmPlus -PathType Leaf)) {
    throw "Build tool not found: $SjasmPlus"
}

$ProjectAlias = 'U:\Desktop\WC\WildCommander Improved\source\plugins\unzip.wmf'
if (-not (Test-Path -LiteralPath $ProjectAlias -PathType Container)) {
    throw "U: does not expose the project: $ProjectAlias"
}

New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

# sjasmplus пишет ход сборки в stderr; при ErrorActionPreference=Stop такие
# строки нельзя пропускать через конвейер PowerShell, поэтому вызов идёт
# через cmd с объединением потоков, а успех проверяется по коду возврата.
function Invoke-Sjasm {
    param([string[]]$Arguments)
    $line = '"' + $SjasmPlus + '" ' + ($Arguments -join ' ') + ' 2>&1'
    $output = & cmd.exe /c $line
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "sjasmplus failed: $($Arguments -join ' ')" }
}

Push-Location $ProjectAlias
try {
    # Плагин целиком на ассемблере: образ страницы #8000..#BFFF в build\code.bin
    Invoke-Sjasm @('--nologo', '--sym=build/code.sym', '--lst=build/code.lst', 'src/unzip.asm')
    Invoke-Sjasm @('--nologo', '--lst=build/UNZIP.lst', '--sym=build/UNZIP.sym', 'src/wmf.asm')
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
