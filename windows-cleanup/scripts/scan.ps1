# Параметры
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$Top = 50
)

# Карта папок (топ-N) + топ файлов + кандидаты дублей.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Root "D:\" -OutDir "<рабочая папка>"
# Всё пишется в UTF-8; -LiteralPath обязателен (кириллица/пробелы); reparse points пропускаются (защита от циклов).

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$dirTop  = Join-Path $OutDir 'dirs_top.txt'
$fileTop = Join-Path $OutDir 'files_top.txt'
$dupes   = Join-Path $OutDir 'dupes.txt'

# --- Топ папок ---
$dirs = Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
$rows = foreach ($d in $dirs) {
    $sum = (Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -File |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Path = $d.FullName; GB = [math]::Round(($sum/1GB), 2) }
}
$rows | Sort-Object GB -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-File -FilePath $dirTop -Encoding UTF8

# --- Топ файлов ---
Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
    Sort-Object Length -Descending | Select-Object -First $Top Length,LastWriteTime,FullName |
    Format-Table -AutoSize | Out-File -FilePath $fileTop -Encoding UTF8

# --- Дубликаты (группировка Name+Length, >50 МБ; хеш не делаем — только кандидаты) ---
Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
    Where-Object { $_.Length -gt 50MB -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
    Group-Object Length,Name |
    Where-Object { $_.Count -gt 1 } |
    ForEach-Object { $_.Group | Select-Object Length,FullName } |
    Format-Table -AutoSize | Out-File -FilePath $dupes -Encoding UTF8

Write-Output "OK: dirs_top=$dirTop files_top=$fileTop dupes=$dupes"
