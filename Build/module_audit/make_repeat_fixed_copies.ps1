param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$sourceRoot = Join-Path $ProjectRoot 'source'
$auditRoot = Join-Path $ProjectRoot 'Build\module_audit'

$wcfx = Get-Content -LiteralPath (Join-Path $sourceRoot 'WCFX.ASM') -Raw
$wcfx = $wcfx.Replace(
    " .6      SRL D:RR E,H,L",
    ((1..6 | ForEach-Object { "        SRL D:RR E,H,L" }) -join "`r`n")
)
$wcfx = $wcfx.Replace(
    " .7      LD (DE),A:INC DE",
    ((1..7 | ForEach-Object { "        LD (DE),A:INC DE" }) -join "`r`n")
)
Set-Content -LiteralPath (Join-Path $auditRoot 'WCFX_repeat_fixed.ASM') -Value $wcfx -Encoding utf8

$wcvw = Get-Content -LiteralPath (Join-Path $sourceRoot 'WCVW.ASM') -Raw
$wcvw = $wcvw.Replace(
    " .5      SRL H:RR L",
    ((1..5 | ForEach-Object { "        SRL H:RR L" }) -join "`r`n")
)
Set-Content -LiteralPath (Join-Path $auditRoot 'WCVW_repeat_fixed.ASM') -Value $wcvw -Encoding utf8
