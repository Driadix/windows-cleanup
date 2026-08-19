# ledger-report.ps1 — свод по ledger.csv для Фазы 10 (без ручного сложения).
# Печатает: baseline свободного места (по томам), сумму освобождённого по фазам, дельту Get-Volume сейчас vs baseline.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File ledger-report.ps1 -Work "рабочая папка" [-Ledger ledger.csv]
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [string]$Ledger = 'ledger.csv'
)
$ErrorActionPreference = 'Continue'
$led = Join-Path $Work $Ledger
$out = Join-Path $Work 'ledger_report.txt'
if (-not (Test-Path -LiteralPath $led)) { Write-Error ('нет ledger: ' + $led); exit 1 }

$rows = @(Import-Csv -LiteralPath $led)
$lines = @()
$lines += '=== СВОД ПО LEDGER.CSV ==='
$base = @($rows | Where-Object { $_.phase -eq 'baseline' })
$lines += ''
$lines += '--- Baseline (свободно на старте, МБ) ---'
foreach ($b in $base) { $lines += ('  {0}: {1:N0} МБ ({2:N2} ГБ)' -f $b.object, ([double]$b.size_before_mb), ([double]$b.size_before_mb/1024)) }

$lines += ''
$lines += '--- Освобождено по фазам (removed_mb, без baseline) ---'
$removed = @($rows | Where-Object { $_.phase -ne 'baseline' })
$byPhase = $removed | Group-Object phase | ForEach-Object {
    [pscustomobject]@{ Phase=$_.Name; MB=($_.Group | Measure-Object -Property removed_mb -Sum).Sum; N=$_.Count }
} | Sort-Object Phase
foreach ($p in $byPhase) { $lines += ('  {0}: {1:N1} МБ ({2:N2} ГБ)  ({3} записей)' -f $p.Phase, $p.MB, ($p.MB/1024), $p.N) }
$totalMB = ($removed | Measure-Object -Property removed_mb -Sum).Sum
if ($null -eq $totalMB) { $totalMB = 0 }   # syndrome: Measure-Object пустого набора возвращает $null, и {0:N1} печатает пустоту (0.2.2)
$lines += ('  ИТОГО освобождено (по строкам ledger): {0:N1} МБ ({1:N2} ГБ)' -f $totalMB, ($totalMB/1024))

$lines += ''
$lines += '--- Дельты томов: baseline vs сейчас (Get-Volume) ---'
foreach ($v in (Get-Volume | Where-Object DriveLetter)) {
    $bl = $base | Where-Object { $_.object -eq ('volume ' + $v.DriveLetter) } | Select-Object -First 1
    $nowMB = [double]$v.SizeRemaining / 1MB
    if ($bl) {
        $deltaGB = ($nowMB - [double]$bl.size_before_mb) / 1024
        $lines += ('  {0}: было {1:N2} ГБ -> стало {2:N2} ГБ свободно  (разница свободного: {3:N2} ГБ)' -f $v.DriveLetter, ([double]$bl.size_before_mb/1024), ($nowMB/1024), [math]::Abs($deltaGB))
    } else { $lines += ('  {0}: baseline нет (том не был в фазе 0)' -f $v.DriveLetter) }
}
$lines | Set-Content -Path $out -Encoding UTF8
$lines | ForEach-Object { Write-Output $_ }
