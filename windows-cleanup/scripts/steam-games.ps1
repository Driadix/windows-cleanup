# steam-games.ps1 — ИНФОРМАЦИЯ о Steam-библиотеках: топ игр по размеру (блок «где место», Фаза 3).
# Ничего не удаляет: игры Steam удаляются ТОЛЬКО через клиент Steam. Цель — чтобы объём игр
# оставался видимым в анализе, но НЕ попадал в кандидаты на удаление (см. U4).
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File steam-games.ps1 -Work "рабочая папка"
# Выход: steam_games.txt  (GB<TAB>Name<TAB>Path, сортировка по размеру; порог 100 МБ).
param([Parameter(Mandatory=$true)][string]$Work)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
$out = Join-Path $Work 'steam_games.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }

$roots = New-Object 'System.Collections.Generic.HashSet[string]'
$realRoots = @{}   # ключ (upper) -> реальный путь с исходным регистром (для вывода без ЗАГЛАВНЫХ)
function Norm-Lib([string]$p) {
    # ключ дедупликации: полный путь, один слэш, верхний регистр (в VDF/путях могут быть двойные \\)
    return [IO.Path]::GetFullPath($p).TrimEnd('\').ToUpperInvariant()
}
$rel = @('steamapps', 'Steam\steamapps', 'SteamLibrary\steamapps', 'Games\Steam\steamapps', 'Program Files (x86)\Steam\steamapps')
foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -ne 2 -and $_.DriveType -ne 4 -and $_.DriveType -ne 5 })) {
    $r = $v.DriveLetter + ':\'
    foreach ($x in $rel) {
        $p = Join-Path $r $x
        if (Test-Path -LiteralPath $p) {
            $k = Norm-Lib $p
            if ($roots.Add($k)) { $realRoots[$k] = $p }
        }
    }
}
# дополнительные библиотеки из libraryfolders.vdf (только существующие steamapps)
foreach ($root in @($realRoots.Values)) {
    $vdf = Join-Path $root 'libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        foreach ($m in [regex]::Matches([string]$txt, '"path"\s+"([^"]+)"')) {
            $sa = Join-Path ($m.Groups[1].Value.TrimEnd('\')) 'steamapps'
            if (Test-Path -LiteralPath $sa) {
                $k = Norm-Lib $sa
                if ($roots.Add($k)) { $realRoots[$k] = ([IO.Path]::GetFullPath($sa)) }
            }
        }
    }
}

$rows = @()
foreach ($sa in $realRoots.Values) {
    $common = Join-Path $sa 'common'
    if (-not (Test-Path -LiteralPath $common)) { continue }
    foreach ($g in (Get-ChildItem -LiteralPath $common -Directory -Force -ErrorAction SilentlyContinue)) {
        $sz = Get-SizeBytes -Path $g.FullName
        if ($sz -lt 100MB) { continue }
        $rows += [pscustomobject]@{ GB = ([double]$sz / 1GB); Name = $g.Name; Path = $g.FullName }
    }
}

$totalGB = 0.0
Add-Content -Path $out -Value ('# Steam-библиотеки: {0} (корней steamapps). Топ игр >= 100 МБ.' -f $roots.Count) -Encoding UTF8
Add-Content -Path $out -Value '# Удаление игр — ТОЛЬКО через клиент Steam (это информация, не кандидаты на удаление).' -Encoding UTF8
$rows | Sort-Object GB -Descending | ForEach-Object {
    $totalGB += $_.GB
    Add-Content -Path $out -Value ("{0}`t{1}`t{2}" -f (fmt-N $_.GB 2), $_.Name, $_.Path) -Encoding UTF8
}
Add-Content -Path $out -Value ('# ИТОГО в Steam (по показанным играм): {0} ГБ' -f (fmt-N $totalGB 2)) -Encoding UTF8
Write-Output ("steam-games: корней=" + $roots.Count + "  игр=" + $rows.Count + "  итого=" + [math]::Round($totalGB,2) + " ГБ  =>  " + $out)
