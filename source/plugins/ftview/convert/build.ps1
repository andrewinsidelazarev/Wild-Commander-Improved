# Сборка FTViewConvert.exe: C# 5 из .NET Framework 4 (есть в Windows), x64,
# ffmpeg.exe внутри ресурсом. Архив ffmpeg скачивается один раз и проверяется
# по SHA-256 с сайта сборок (gyan.dev, на него ссылается ffmpeg.org).
param([string]$Out = (Join-Path $PSScriptRoot '..\..\..\..\Build\ftview-convert'))
$ErrorActionPreference = 'Stop'
$Out = [IO.Path]::GetFullPath($Out)
$zipName = 'ffmpeg-9.0.2-essentials_build.zip'
$url = 'https://www.gyan.dev/ffmpeg/builds/packages/' + $zipName
$sha = '60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA'
New-Item -ItemType Directory -Force $Out | Out-Null
$zip = Join-Path $Out $zipName
if (-not (Test-Path -LiteralPath $zip)) {
    & curl.exe -sL -o $zip $url
    if ($LASTEXITCODE -ne 0) { throw 'ffmpeg download failed' }
}
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $sha) { throw 'ffmpeg archive SHA-256 mismatch' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -like '*/bin/ffmpeg.exe') {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Out 'ffmpeg.exe'), $true)
        } elseif ($entry.FullName -like '*/LICENSE') {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Out 'ffmpeg-LICENSE.txt'), $true)
        }
    }
} finally { $archive.Dispose() }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe = Join-Path $Out 'FTViewConvert.exe'
# Иконка (make_icon.py): в exe для проводника и ресурсом для заголовка окна.
$icon = Join-Path $PSScriptRoot 'app.ico'
Push-Location $Out
try {
    & $csc /nologo /target:winexe /platform:x64 /optimize+ "/out:$exe" "/win32icon:$icon" `
        '/resource:ffmpeg.exe,FTViewConvert.ffmpeg.exe' "/resource:$icon,FTViewConvert.app.ico" `
        /r:System.Windows.Forms.dll /r:System.Drawing.dll (Join-Path $PSScriptRoot 'Program.cs')
    if ($LASTEXITCODE -ne 0) { throw 'csc failed' }
} finally { Pop-Location }
Write-Host ('FTViewConvert.exe: {0:N0} bytes' -f (Get-Item $exe).Length)
