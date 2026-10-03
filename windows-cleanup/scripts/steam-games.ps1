# steam-games.ps1 — ИНФОРМАЦИЯ о Steam-библиотеках: топ игр по размеру (блок «где место», Фаза 3).
# Ничего не удаляет: игры Steam удаляются ТОЛЬКО через клиент Steam. Цель — чтобы объём игр
# оставался видимым в анализе, но НЕ попадал в кандидаты на удаление (см. U4).
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File steam-games.ps1 -Work "рабочая папка"
# Выход: steam_games.txt  (GB<TAB>Name<TAB>Path, сортировка по размеру; порог -MinMB, дефолт 100).
param([Parameter(Mandatory=$true)][string]$Work, [int]$MinMB = 100)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
$out = Join-Path $Work 'steam_games.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }

$fixedVols = @(Get-FixedVolumes)   # DriveType — СТРОКА, не enum: старый фильтр `-ne 2` молча не работал
$roots = New-Object 'System.Collections.Generic.HashSet[string]'
$realRoots = @{}   # ключ (upper) -> реальный путь с исходным регистром (для вывода без ЗАГЛАВНЫХ)
function Norm-Lib([string]$p) {
    # ключ дедупликации: полный путь, один слэш, верхний регистр (в VDF/путях могут быть двойные \\).
    # GetFullPath кидает ArgumentException на путях с недопустимыми символами (значение чужого vdf
    # может быть произвольным) — ловим, иначе падает весь отчёт.
    try { return [IO.Path]::GetFullPath($p).TrimEnd('\').ToUpperInvariant() } catch { return $null }
}
function Add-Root([string]$p) {
    if (-not $p) { return }
    if (Test-Path -LiteralPath $p) {
        $k = Norm-Lib $p
        if ($k) {
            if ($roots.Add($k)) { try { $realRoots[$k] = [IO.Path]::GetFullPath($p) } catch { [void]$roots.Remove($k) } }
        }
    }
}
# 1) фиксированные относительные пути (быстрая страховка)
$rel = @('steamapps', 'Steam\steamapps', 'SteamLibrary\steamapps', 'Games\Steam\steamapps', 'Program Files (x86)\Steam\steamapps')
foreach ($v in $fixedVols) {
    $r = $v.DriveLetter + ':\'
    foreach ($x in $rel) { Add-Root (Join-Path $r $x) }
}
# 2) клиент Steam по реестру (InstallPath, запасной SteamPath) — адаптивно к нестандартной установке
foreach ($hk in @('HKLM:\Software\WOW6432Node\Valve\Steam','HKLM:\Software\Valve\Steam','HKCU:\Software\Valve\Steam')) {
    $vp = Get-ItemProperty -LiteralPath $hk -ErrorAction SilentlyContinue
    $ip = $vp.InstallPath
    if (-not $ip) { $ip = $vp.SteamPath }   # реальный клиент пишет SteamPath (иногда с прямыми слэшами)
    if ($ip) { Add-Root (Join-Path ([string]$ip).Replace('/','\') 'steamapps') }
}
# 3) адаптивный shallow-скан: топ-уровень каждого фикс-тома — любые папки, внутри которых есть steamapps
foreach ($v in $fixedVols) {
    $r = $v.DriveLetter + ':\'
    foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {
        Add-Root (Join-Path $d.FullName 'steamapps')
    }
}
# 4) цепочка libraryfolders.vdf: из каждого найденного корня добираем ВСЕ библиотеки (не только стандартные)
for ($round = 0; $round -lt 10; $round++) {
    $check = @($realRoots.Values)
    if (-not $check) { break }
    $added = $false
    foreach ($root in $check) {
        $vdf = Join-Path $root 'libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf)) { continue }
        # Steam пишет vdf в UTF-8 БЕЗ BOM; Get-Content без -Encoding в PS 5.1 декодирует как ANSI
        # (cp1251 на ru-RU) → кириллический путь библиотеки ('D:\Игры\Steam') превращается в мусор,
        # Test-Path=False и вся библиотека с играми теряется из отчёта.
        $txt = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $txt) { $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue }
        $txt = [string]$txt
        # vdf экранирует слэши как '\\'; нормализуем до '\' (и '/' на случай ручных правок).
        $paths = New-Object 'System.Collections.Generic.List[string]'
        # формат v2: "path"  "D:\\Games\\Steam"
        foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) { $paths.Add($m.Groups[1].Value) }
        # формат v1 (старый): значения у числовых ключей — "1"  "D:\\SteamLibrary"
        foreach ($m in [regex]::Matches($txt, '(?m)^\s*"\d+"\s+"([^"]+)"')) { $paths.Add($m.Groups[1].Value) }
        foreach ($raw in $paths) {
            $norm = $raw.Replace('\\','\').Replace('/','\').TrimEnd('\')
            if (-not $norm) { continue }
            $sa = Join-Path $norm 'steamapps'
            $cnt = $roots.Count
            Add-Root $sa
            if ($roots.Count -gt $cnt) { $added = $true }
        }
    }
    if (-not $added) { break }
}

$rows = New-Object 'System.Collections.Generic.List[object]'
$minBytes = [long]$MinMB * 1MB
foreach ($sa in $realRoots.Values) {
    $common = Join-Path $sa 'common'
    if (-not (Test-Path -LiteralPath $common)) { continue }
    # Размер игры Steam уже хранит в appmanifest_<id>.acf ("SizeOnDisk") — не обходим дерево каждой
    # игры (для библиотеки в 200 игр Get-SizeBytes = десятки минут лишнего I/O). Обход остаётся
    # только fallback'ом для каталогов без манифеста.
    $manifest = @{}   # installdir (UPPER) -> @{ Name; Bytes }
    foreach ($mf in (Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
        $mt = [string](Get-Content -LiteralPath $mf.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        if (-not $mt) { continue }
        $mdir = [regex]::Match($mt, '"installdir"\s+"([^"]+)"').Groups[1].Value
        if (-not $mdir) { continue }
        $msz = [regex]::Match($mt, '"SizeOnDisk"\s+"?([0-9]+)').Groups[1].Value
        $manifest[$mdir.TrimEnd('\').ToUpperInvariant()] = [pscustomobject]@{
            Name  = [regex]::Match($mt, '"name"\s+"([^"]+)"').Groups[1].Value
            Bytes = $(if ($msz) { [long]$msz } else { $null })
        }
    }
    foreach ($g in (Get-ChildItem -LiteralPath $common -Directory -Force -ErrorAction SilentlyContinue)) {
        $m = $manifest[$g.Name.TrimEnd('\').ToUpperInvariant()]
        $sz = $null
        if ($m -and $null -ne $m.Bytes) { $sz = $m.Bytes }
        if ($null -eq $sz) { $sz = Get-SizeBytes -Path $g.FullName }
        if ($sz -lt $minBytes) { continue }
        $name = if ($m -and $m.Name) { $m.Name } else { $g.Name }
        $rows.Add([pscustomobject]@{ GB = ([double]$sz / 1GB); Name = $name; Path = $g.FullName })
    }
}

$totalGB = 0.0
Add-Content -Path $out -Value ('# Steam-библиотеки: {0} (корней steamapps). Топ игр >= {1} МБ.' -f $roots.Count, $MinMB) -Encoding UTF8
Add-Content -Path $out -Value '# Удаление игр — ТОЛЬКО через клиент Steam (это информация, не кандидаты на удаление).' -Encoding UTF8
$rows | Sort-Object GB -Descending | ForEach-Object {
    $totalGB += $_.GB
    Add-Content -Path $out -Value ("{0}`t{1}`t{2}" -f (fmt-N $_.GB 2), $_.Name, $_.Path) -Encoding UTF8
}
Add-Content -Path $out -Value ('# ИТОГО в Steam (по показанным играм): {0} ГБ' -f (fmt-N $totalGB 2)) -Encoding UTF8
Write-Output ("steam-games: корней=" + $roots.Count + "  игр=" + $rows.Count + "  итого=" + [math]::Round($totalGB,2) + " ГБ  =>  " + $out)
