# scan.ps1 — инвентаризация корня: карта топ-папок + топ-файлов + кандидаты дублей.
# ОДИН проход по дереву (одна рекурсия), в отличие от старой версии (3+ обхода).
# Использование (из git-bash путь лучше с прямыми слэшами):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Root "C:/" -OutDir "D:\путь\рабочей папки"
# Параметры: -Root -OutDir -Top (50) -MinDupBytes (50MB) -SkipSystemDupes -ExcludeRoots @(пути)
# Выход: dirs_top.txt ("GB\tPath"), files_top.txt ("Length\tdate\tFullName"), dupes.txt ("Length\tFullName").
#   При пустом результате пишется маркер "(пусто — совпадений нет)" (файл всегда создаётся).
#   Рабочая папка (OutDir), $Recycle.Bin, System Volume Information и -ExcludeRoots — исключаются из обхода.
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$Top = 50,
    [long]$MinDupBytes = 50MB,
    [switch]$SkipSystemDupes,
    [string[]]$ExcludeRoots = @()
)

$ErrorActionPreference = 'Continue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$dirTop  = Join-Path $OutDir 'dirs_top.txt'
$fileTop = Join-Path $OutDir 'files_top.txt'
$dupes   = Join-Path $OutDir 'dupes.txt'
$dupesSys = Join-Path $OutDir 'dupes_system.txt'

# --- нормализация корня (всегда завершающий обратный слэш: 'C:\' и 'C:/' -> 'C:\') ---
$rootWin = $Root.Replace('/','\')
if (-not $rootWin.EndsWith('\')) { $rootWin += '\' }
$rootLen = $rootWin.Length

# --- исключаемые префиксы (case-insensitive) ---
$excl = New-Object 'System.Collections.Generic.List[string]'
if ($OutDir.StartsWith($rootWin, [StringComparison]::OrdinalIgnoreCase)) { $excl.Add(($OutDir.Replace('/','\').TrimEnd('\') + '\')) }
$excl.Add(($rootWin + '$RECYCLE.BIN\'))
$excl.Add(($rootWin + 'System Volume Information\'))
foreach ($x in $ExcludeRoots) { $excl.Add(($x.Replace('/','\').TrimEnd('\') + '\')) }
$exclUpper = @($excl | ForEach-Object { $_.ToUpperInvariant() })

function Is-Excluded([string]$FullPath) {
    $u = $FullPath.ToUpperInvariant()
    foreach ($p in $exclUpper) { if ($u.StartsWith($p)) { return $true } }
    return $false
}

# --- аккумуляторы ---
$dirSizes = @{}                                  # segment-key -> bytes (только топ-уровень внутри Root)
$topFiles = New-Object 'System.Collections.Generic.List[object[]]'   # топ-N крупнейших (без сортировки сотен тысяч)
$dupeMap  = @{}                                  # "length|name" -> List[string] (только > MinDupBytes)

$FileAttr = [IO.FileAttributes]::ReparsePoint
foreach ($file in (Get-ChildItem -LiteralPath $rootWin -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    if ($file.Attributes -band $FileAttr) { continue }
    if (Is-Excluded $file.FullName) { continue }
    $len = [long]$file.Length
    # топ-уровневый сегмент (папка 1-го уровня от корня)
    $rel = $file.FullName.Substring($rootLen)
    $idx = $rel.IndexOf('\')
    if ($idx -ge 0) { $seg = $rel.Substring(0, $idx); $key = $rootWin + $seg + '\' } else { $key = $rootWin }
    if ($dirSizes.ContainsKey($key)) { $dirSizes[$key] += $len } else { $dirSizes[$key] = $len }
    # топ-файлы (инкрементальный top-N, без полной коллекции)
    if ($topFiles.Count -lt $Top) {
        $topFiles.Add([object[]]@($len, $file.LastWriteTime, $file.FullName))
        if ($topFiles.Count -eq $Top) {
            $topFiles.Sort([System.Comparison[object[]]]{ param($a, $b) ([long]$b[0]).CompareTo([long]$a[0]) })
        }
    } elseif ($len -gt [long]$topFiles[$topFiles.Count - 1][0]) {
        $topFiles[$topFiles.Count - 1] = [object[]]@($len, $file.LastWriteTime, $file.FullName)
        $topFiles.Sort([System.Comparison[object[]]]{ param($a, $b) ([long]$b[0]).CompareTo([long]$a[0]) })
    }
    # кандидаты в дубли (только большие)
    if ($len -gt $MinDupBytes) {
        $dk = [string]$len + '|' + $file.Name
        if ($dupeMap.ContainsKey($dk)) { $dupeMap[$dk].Add($file.FullName) } else { $dupeMap[$dk] = New-Object 'System.Collections.Generic.List[string]'; $dupeMap[$dk].Add($file.FullName) }
    }
}

# --- карта папок: добавить пустые дочерние, чтобы они не пропадали (0 ГБ) ---
foreach ($d in (Get-ChildItem -LiteralPath $rootWin -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($d.Attributes -band $FileAttr) { continue }
    if (Is-Excluded ($d.FullName + '\')) { continue }
    $dk = $rootWin + $d.Name + '\'
    if (-not $dirSizes.ContainsKey($dk)) { $dirSizes[$dk] = 0L }
}

$dirRows = $dirSizes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    "{0:N2}`t{1}" -f ($_.Value / 1GB), $_.Key
}
if ($dirRows) { $dirRows | Set-Content -Path $dirTop -Encoding UTF8 } else { '(пусто — совпадений нет)' | Set-Content -Path $dirTop -Encoding UTF8 }

$fileRows = $topFiles | ForEach-Object {
    $e = $_; "{0}`t{1}`t{2}" -f $e[0], ([datetime]$e[1]).ToString('yyyy-MM-dd'), $e[2]
}
if ($fileRows) { $fileRows | Set-Content -Path $fileTop -Encoding UTF8 } else { '(пусто — совпадений нет)' | Set-Content -Path $fileTop -Encoding UTF8 }

# --- дубли: только группы Count>1 ---
$sysPrefixesUpper = @(
    (($rootWin + 'Windows\WinSxS\').ToUpperInvariant()),
    (($rootWin + 'Windows\assembly\').ToUpperInvariant()),
    (($rootWin + 'Windows\System32\DriverStore\').ToUpperInvariant()),
    (($rootWin + 'Windows\System32\lxss\').ToUpperInvariant())
)
$userLines = New-Object 'System.Collections.Generic.List[string]'
$sysLines  = New-Object 'System.Collections.Generic.List[string]'
foreach ($kv in $dupeMap.GetEnumerator()) {
    if ($kv.Value.Count -gt 1) {
        $len = [int64]([string]$kv.Key -split '\|')[0]
        $sys = $false
        foreach ($f in $kv.Value) {
            $u = $f.ToUpperInvariant()
            foreach ($sp in $sysPrefixesUpper) { if ($sp -and $u.StartsWith($sp)) { $sys = $true; break } }
            if ($sys) { break }
        }
        foreach ($f in $kv.Value) {
            $line = "{0}`t{1}" -f $len, $f
            if ($sys) { $sysLines.Add($line) } else { $userLines.Add($line) }
        }
    }
}
$userLines = @($userLines | Sort-Object { [int64](($_ -split "`t")[0]) } -Descending)
$sysLines  = @($sysLines  | Sort-Object { [int64](($_ -split "`t")[0]) } -Descending)
if ($userLines.Count) { $userLines | Set-Content -Path $dupes -Encoding UTF8 }
else { '(пусто — совпадений нет)' | Set-Content -Path $dupes -Encoding UTF8 }
if ($sysLines.Count) {
    $sysLines | Set-Content -Path $dupesSys -Encoding UTF8
    if (-not $SkipSystemDupes) {
        Add-Content -Path $dupes -Value '' -Encoding UTF8
        Add-Content -Path $dupes -Value '# by-design системные дубли (WinSxS/NGEN/DriverStore/lxss) — не кандидаты:' -Encoding UTF8
        Add-Content -Path $dupes -Value (($sysLines -join "`n")) -Encoding UTF8
    }
} elseif (Test-Path -LiteralPath $dupesSys) { Remove-Item -LiteralPath $dupesSys -Force }

$sw.Stop()
Write-Output ("OK: dirs_top=$dirTop files_top=$fileTop dupes=$dupes в {0:N1} с" -f $sw.Elapsed.TotalSeconds)
