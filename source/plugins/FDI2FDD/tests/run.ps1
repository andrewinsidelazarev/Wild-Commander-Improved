$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & .\build.ps1
    python -B tests\run.py
    if ($LASTEXITCODE -ne 0) { throw 'FDI2FDD tests failed' }
} finally { Pop-Location }
