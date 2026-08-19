# scan.ps1 — инвентаризация корня: карта топ-папок + топ-файлов + кандидаты дублей.
# ОДИН проход по дереву (одна рекурсия), в отличие от старой версии (3+ обхода).
# Использование (из git-bash путь лучше с прямыми слэшами):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Root "C:/" -OutDir "D:\путь\рабочей папки"
# Параметры: -Root -OutDir -Top (50) -MinDupBytes (по умолчанию 50MB; с суффиксом: '20MB','1.5GB',
#   или голые байты '50000000') -SkipSystemDupes -ExcludeRoots @(пути) -Tag ('c'/'d' и т.п.)
#   -ProgressFile <файл>: маркеры start/DONE для поллинга агентом фонового скана (см. ниже).
# Про обход: ЕДИНСТВЕННЫЙ проход — классический Get-ChildItem -Recurse -Force. .NET-вариант
#   ([System.IO.Directory]::EnumerateFiles со стеком) пробовали в 0.2.4 и УБРАЛИ: замеры на живом
#   диске не показали выигрыша (полный C: 287 с classic vs 296 с .NET; C:\Windows 126 с vs 180 с —
#   classic быстрее). Причина: узкое место не в способе перечисления, а в самом обходе NTFS-дерева
#   через Win32 API; единственный реальный путь к скорости — чтение MFT напрямую (как WizTree/
#   Everything/SpaceSniffer), а это нативный код + админ, вне PowerShell. Классика проще и надёжнее.
# -ProgressFile: пишем "# start" перед обходом и "DONE\t<сек>" после — агент поллит файл и по DONE
#   понимает, что скан завершён (показывая «скан идёт...» вместо тишины). Пофайловый прогресс в
#   классике недоступен (Get-ChildItem -Recurse — единый вызов), но маркер start/DONE уже даёт UX.
# Выход: dirs_top.txt ("GB\tPath"), files_top.txt ("Length\tdate\tFullName"), dupes.txt ("Length\tFullName").
#   + scan_meta.txt (JSON в одну строку: root/tag/время/сек_длительность/флаги) — кэш результата для агента:
#     можно не пересканировать диск при повторном показе отчёта.
#   -Tag: суффикс имён файлов — НЕ даёт второму скану (другой корень) затреть результаты первого
#   (dirs_top_c.txt / dirs_top_d.txt и т.д.). Без -Tag имена классические (один корень за прогон).
#   При пустом результате пишется маркер "(пусто — совпадений нет)" (файл всегда создаётся).
#   Рабочая папка (OutDir), $Recycle.Bin, System Volume Information и -ExcludeRoots — исключаются из обхода.
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$Top = 50,
    [string]$MinDupBytes = '50MB',
    [switch]$SkipSystemDupes,
    [string[]]$ExcludeRoots = @(),
    [string]$Tag = '',
    [string]$ProgressFile = ''
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')   # ConvertTo-Bytes и пр.
$minDupLong = ConvertTo-Bytes -Size $MinDupBytes   # '50MB'/'1.5GB'/число -> байты (см. ConvertTo-Bytes)
$suffix = if ($Tag) { '_' + ([string]$Tag).Trim().Trim('_') } else { '' }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$dirTop  = Join-Path $OutDir ('dirs_top' + $suffix + '.txt')
$fileTop = Join-Path $OutDir ('files_top' + $suffix + '.txt')
$dupes   = Join-Path $OutDir ('dupes' + $suffix + '.txt')
$dupesSys = Join-Path $OutDir ('dupes_system' + $suffix + '.txt')

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

# --- обход: единственный проход Get-ChildItem -Recurse (классика; .NET-вариант убран — см. шапку) ---
$FileAttr = [IO.FileAttributes]::ReparsePoint
if ($ProgressFile) {
    if (Test-Path -LiteralPath $ProgressFile) { Remove-Item -LiteralPath $ProgressFile -Force }
    ("# scan progress`tstart " + (Get-Date -Format 'HH:mm:ss')) | Add-Content -Path $ProgressFile -Encoding UTF8
}
$nFiles = 0
foreach ($file in (Get-ChildItem -LiteralPath $rootWin -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    if ($file.Attributes -band $FileAttr) { continue }
    if (Is-Excluded $file.FullName) { continue }
    $len = [long]$file.Length
    $nFiles++
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
    if ($len -gt $minDupLong) {
        $dk = [string]$len + '|' + $file.Name
        if ($dupeMap.ContainsKey($dk)) { $dupeMap[$dk].Add($file.FullName) } else { $dupeMap[$dk] = New-Object 'System.Collections.Generic.List[string]'; $dupeMap[$dk].Add($file.FullName) }
    }
}
if ($ProgressFile) { ("DONE`t{0}`t{1}" -f [math]::Round($sw.Elapsed.TotalSeconds,1), $nFiles) | Add-Content -Path $ProgressFile -Encoding UTF8 }

# --- карта папок: добавить пустые дочерние, чтобы они не пропадали (0 ГБ) ---
foreach ($d in (Get-ChildItem -LiteralPath $rootWin -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($d.Attributes -band $FileAttr) { continue }
    if (Is-Excluded ($d.FullName + '\')) { continue }
    $dk = $rootWin + $d.Name + '\'
    if (-not $dirSizes.ContainsKey($dk)) { $dirSizes[$dk] = 0L }
}

$dirRows = $dirSizes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    # число с точкой (инвариантная культура) — в ru-RU N2 дало бы '56 697,00' (NBSP+запятая)
    "{0}`t{1}" -f (($_.Value / 1GB).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)), $_.Key
}
if ($dirRows) { $dirRows | Set-Content -Path $dirTop -Encoding UTF8 } else { '(пусто — совпадений нет)' | Set-Content -Path $dirTop -Encoding UTF8 }

$fileRows = $topFiles | ForEach-Object {
    $e = $_; "{0}`t{1}`t{2}" -f $e[0], ([datetime]$e[1]).ToString('yyyy-MM-dd'), $e[2]
}
if ($fileRows) { $fileRows | Set-Content -Path $fileTop -Encoding UTF8 } else { '(пусто — совпадений нет)' | Set-Content -Path $fileTop -Encoding UTF8 }

# --- дубли: только группы Count>1 ---
# Системные маркеры — ПОДСТРОКИ пути (не префиксы от корня скана!): префикс от $rootWin работал бы
# только при корне 'C:\', а на подкорне (напр. 'Program Files (x86)\Microsoft') собирался мусор — реальный кейс 0.2.3.
# Нужен $u.Contains(marker) — сработает при любом корне.
$sysMarkersUpper = @(
    '\WINDOWS\WINSXS\',
    '\WINDOWS\ASSEMBLY\',
    '\WINDOWS\SYSTEM32\DRIVERSTORE\',
    '\WINDOWS\SYSTEM32\LXSS\',
    # Edge vs EdgeWebView делят бинарники по-design (случай 0.2.2: msedge.dll 342 МБ пара) — не кандидаты
    '\MICROSOFT\EDGECORE\',
    '\MICROSOFT\EDGEWEBVIEW\'
)
$userLines = New-Object 'System.Collections.Generic.List[string]'
$sysLines  = New-Object 'System.Collections.Generic.List[string]'
foreach ($kv in $dupeMap.GetEnumerator()) {
    if ($kv.Value.Count -gt 1) {
        $len = [int64]([string]$kv.Key -split '\|')[0]
        $sys = $false
        foreach ($f in $kv.Value) {
            $u = $f.ToUpperInvariant()
            foreach ($m in $sysMarkersUpper) { if ($u.Contains($m)) { $sys = $true; break } }
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

# --- мета-кэш результата (для агента: не пересканировать при повторном показе отчёта) ---
$meta = Join-Path $OutDir ('scan_meta' + $suffix + '.txt')
$metaJson = @{
    root          = $rootWin
    tag           = $Tag
    started       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    duration_s    = [math]::Round($sw.Elapsed.TotalSeconds,1)
    min_dup_bytes = $minDupLong
    top_files     = $Top
    files         = $nFiles
}
$metaJson | ConvertTo-Json -Compress | Set-Content -Path $meta -Encoding UTF8

Write-Output ("OK: dirs_top=$dirTop files_top=$fileTop dupes=$dupes в {0:N1} с" -f $sw.Elapsed.TotalSeconds)
Write-Output ("META: " + $meta)
