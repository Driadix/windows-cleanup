# cleanup-common.ps1 — общая библиотека для phase-скриптов windows-cleanup
# Подключается из phase-скриптов той же папки:  . (Join-Path $PSScriptRoot 'cleanup-common.ps1')
# Правила:
#   * Никаких функций с именами ключевых слов PS (Do/ForEach/...).
#   * Никаких `return $null` внутри ForEach-Object-пайплайнов (emit $null ломает вызов).
#   * Счётчики возвращаем из функций, агрегирует вызывающий (в `$script:` своей области).
#   * Любое удаление: только -LiteralPath -Recurse -Force + статус через Test-Path.
#   * Логи/CSV — UTF-8.
$ErrorActionPreference = 'Continue'

function Test-Elevated {
    # Возвращает True, если процесс под администратором (по привилегии, не по SID).
    # BuiltInRole-enum вместо строки 'Administrators' — локаленезависимо (на ru-RU/др. языках
    # встроенная группа называется иначе, и поиск по имени дал бы ложный False).
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SizeBytes([string]$Path) {
    # Суммарный размер всех файлов внутри пути (рекурсивно, пропуская ошибки доступа).
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0L }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $s) { return 0L }
    return [long]$s
}

function ConvertTo-Bytes {
    # Преобразует строку размера в байты [long]: '50MB' / '1.5 GB' / '50000000' / '123 KB'.
    # Нужна, чтобы размерные параметры можно было передавать из командной строки с суффиксом:
    # в PS 5.1 строка '50MB' НЕ конвертируется в [long] напрямую (ParameterArgumentTransformationError:
    # 'Input string was not in a correct format'), хотя литерал 50MB в теле скрипта — валиден.
    # Реальный кейс: scan.ps1 -MinDupBytes 50MB падал при вызове из командной строки.
    param([string]$Size)
    $s = ([string]$Size).Trim()
    if (-not $s) { return 0L }
    if ($s -match '^(\d+(?:[.,]\d+)?)\s*([KMGTP]?B?)$') {
        $num = [double]($Matches[1] -replace ',', '.')
        switch ($Matches[2].ToUpperInvariant()) {
            'KB' { return [long]($num * 1KB) }
            'MB' { return [long]($num * 1MB) }
            'GB' { return [long]($num * 1GB) }
            'TB' { return [long]($num * 1TB) }
            'PB' { return [long]($num * 1PB) }
            'B'  { return [long]$num }
            default { return [long]$num }   # голое число без суффикса = байты
        }
    }
    return 0L   # нераспознанный формат
}

function Format-Gb([long]$Bytes) {
    return '{0:N2}' -f ($Bytes / 1GB)
}
function Format-Mb([long]$Bytes) {
    return '{0:N1}' -f ($Bytes / 1MB)
}

function fmt-N {
    # Форматирование числа с ИНВАРИАНТНОЙ культурой (разделитель — точка) для CSV/TSV-выходов.
    # В ru-RU `-f` печатает '56697,07' — запятая разрывает CSV-колонки и ломает парсинг
    # (реальный кейс: ledger.csv в тестовом прогоне). Для человекочитаемых логов оставляем -f.
    param([double]$Value, [int]$Decimals = 2)
    return ([double]$Value).ToString(('0.' + ('#' * $Decimals)), [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-FixedVolumes {
    # Только фиксированные тома с буквой (исключает Removable/Network/CD-ROM).
    # ВАЖНО: .DriveType у Get-Volume на живых сборках отдаётся СТРОКОЙ ('Fixed'/'Removable'),
    # а не enum — поэтому сравнение `-ne 2` молча не срабатывает (реальный кейс прогона 2026-10-03:
    # съёмный том E: просочился в отчёт корзин). Сравниваем по строковому представлению enum-имени,
    # что одинаково верно и когда DriveType — enum, и когда — строка.
    Get-Volume | Where-Object { $_.DriveLetter -and ($_.DriveType.ToString() -eq 'Fixed') }
}

function Test-SharedRoot([string]$Path) {
    # True, если путь — общий/корневой контейнер (Program Files, ProgramData, SystemRoot, корень тома,
    # профиль, LOCALAPPDATA, APPDATA), а не каталог конкретного приложения. Многие MSI пишут
    # InstallLocation = 'C:\Program Files' или 'C:\' — рекурсивный обход такой «локации» обходит ВЕСЬ
    # диск. Отсекаем их до замера размера (см. unused-detect.ps1).
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $p = $Path.Replace('/','\').TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $true }   # голый корень тома 'C:'
    $shared = @(
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemRoot,
        $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:SystemDrive
    ) | Where-Object { $_ } | ForEach-Object { $_.Replace('/','\').TrimEnd('\').ToUpperInvariant() }
    $pu = $p.ToUpperInvariant()
    foreach ($s in $shared) { if ($pu -eq $s) { return $true } }
    return $false
}

function New-WorkDir {
    # Создаёт рабочий каталог вида <base>\PC-Cleanup\<дата> (по умолчанию Документы) и возвращает его путь.
    param([string]$Base = '')
    if (-not $Base) { $Base = Join-Path $env:USERPROFILE 'Documents' }
    $dir = Join-Path $Base (Join-Path 'PC-Cleanup' (Get-Date -Format 'yyyy-MM-dd'))
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-ExePath([string]$CmdLine) {
    # Надёжно вычленяет исполняемый файл из командной строки (автозапуски/службы/задачи).
    # Понимает: "C:\...\app.exe" args... | C:\Program Files\X\app.exe --flag | app.exe.
    # Службы WMI отдают путь с удвоенными backslash'ами — схлопываем runs 2+ до одного, НО
    # ведущий run оставляем двойным (UNC \\server\share\app.exe). Простое .Replace('\\','\')
    # ломало UNC-автозапуски (\\srv -> \srv) и давало ложный BROKEN-статус.
    $t = [regex]::Replace($CmdLine.Trim(), '\\{2,}', { param($m) if ($m.Index -eq 0) { '\\' } else { '\' } })
    if ($t -match '^"([^"]+)"') { return $Matches[1] }
    # НЕТ аргументов: вся строка (с пробелами в пути) — сам исполняемый
    if ($t -match '\.(exe|dll|com|bat|cmd|ps1|vbs)$') { return $t }
    # Есть аргументы: первый .exe-кандидат на границе пробелов
    $sp = $t.IndexOf(' ')
    while ($sp -gt 0) {
        $cand = $t.Substring(0, $sp)
        if ($cand -match '\.(exe|dll|com|bat|cmd|ps1|vbs)$') { return $cand }
        $nx = $t.IndexOf(' ', $sp + 1)
        if ($nx -eq $sp) { break }
        $sp = $nx
    }
    return ($t -split '\s+')[0]
}

function Test-UrlBroken([string]$Path) {
    # .url (INI) считается битым только при пустой/отсутствующей URL=.
    $content = $null
    try { $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } catch { }
    if ($null -eq $content) { try { $content = Get-Content -LiteralPath $Path -Raw } catch { } }
    $m = [regex]::Match([string]$content, '(?im)^URL=[ \t]*(.+?)\s*$')
    return (-not $m.Success) -or [string]::IsNullOrWhiteSpace($m.Groups[1].Value)
}

function Test-ProtectedRoot([string]$Path) {
    # Defense-in-depth: возвращает $true, если $Path — сам защищённый системный корень
    # или лежит внутри него. Ворота (согласие пользователя) — первая линия; этот жёсткий
    # блок — вторая, на случай ошибки агента/скрипта. Удаление внутри этих корней никогда
    # не легитимно для скилла; легитимное системное (Windows\Temp, SoftwareDistribution,
    # $WINDOWS.~BT и т.п.) намеренно НЕ входит в список.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $sr = ($env:SystemRoot -replace '[\/]+$', '').ToUpperInvariant()
    $protected = @(
        "$sr\WINSXS",
        "$sr\SYSTEM32",
        "$sr\SYSWOW64",
        "$sr\ASSEMBLY",
        "$sr\SERVICEPROFILES"
    )
    $p = ([string]$Path).Replace('/','\').ToUpperInvariant().TrimEnd('\')
    # Allow-list: легитимные кэши живут под \ServiceProfiles\ (защищённый корень), но являются
    # законными целями elevated-прохода. Без исключения Test-ProtectedRoot молча блокировал их —
    # цель возвращала 0 байт при статусе 'done' (реальный кейс прогона 2026-10-03: DeliveryOptimization).
    # Перечисляем ТОЧНО, а не «всё ServiceProfiles» — профили LocalService/NetworkService сами по
    # себе содержат системные данные, их трогать нельзя.
    $allow = @(
        "$sr\SERVICEPROFILES\NETWORKSERVICE\APPDATA\LOCAL\MICROSOFT\WINDOWS\DELIVERYOPTIMIZATION",
        "$sr\SERVICEPROFILES\LOCALSERVICE\APPDATA\LOCAL\FONTCACHE"
    )
    foreach ($a in $allow) {
        if ($p -eq $a -or $p.StartsWith($a + '\')) { return $false }
    }
    foreach ($pr in $protected) {
        if ($p -eq $pr -or $p.StartsWith($pr + '\')) { return $true }
    }
    return $false
}

function Remove-Target {
    # Удалить файл ИЛИ папку целиком. Возвращает объект: Status / RemovedBytes / RemainsBytes.
    # Status: removed | already gone | LOCKED | BLOCKED (системный корень — не трогаем).
    param([Parameter(Mandatory=$true)][string]$Path)
    if (Test-ProtectedRoot $Path) { return [pscustomobject]@{ Status='BLOCKED'; RemovedBytes=0L; RemainsBytes=0L } }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Status='already gone'; RemovedBytes=0L; RemainsBytes=0L } }
    $before = Get-SizeBytes -Path $Path
    $ok = $false
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $ok = -not (Test-Path -LiteralPath $Path)
    } catch { $ok = -not (Test-Path -LiteralPath $Path) }
    if ($ok) { return [pscustomobject]@{ Status='removed'; RemovedBytes=$before; RemainsBytes=0L } }
    # LOCKED: Remove-Item мог УСПЕТЬ удалить часть содержимого до блокировки — не заявляем
    # RemovedBytes=0 (иначе ledger теряет реально освобождённое). Считаем before − осталось.
    $remains = Get-SizeBytes -Path $Path
    $partialRemoved = [math]::Max(0L, $before - $remains)
    return [pscustomobject]@{ Status='LOCKED'; RemovedBytes=$partialRemoved; RemainsBytes=$remains }
}

function Remove-Contents {
    # Удалить СОДЕРЖИМОЕ папки (саму папку не трогаем). Возвращает объект со статусами.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Status='already gone'; RemovedBytes=0L; LockedCount=0; RemainsBytes=0L } }
    # $before здесь был мёртв: RemovedBytes копится из размеров удалённых элементов, RemainsBytes
    # пересчитывается в конце — полный обход «до» ничего не давал (лишний проход по дереву цели).
    $removed = 0L; $lockedCnt = 0; $deletedCnt = 0
    foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if (Test-ProtectedRoot $item.FullName) { $lockedCnt++; continue }  # системный корень внутри — не трогаем
        $sz = if ($item.PSIsContainer) { Get-SizeBytes -Path $item.FullName } else { [long]$item.Length }
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $removed += $sz; $deletedCnt++
        } catch { $lockedCnt++ }
    }
    # Статус должен отражать РЕЗУЛЬТАТ, а не факт вызова (реальный кейс прогона 2026-10-03:
    # Office C2R / EdgeUpdate Download под Program Files из user-сессии: removed=0, всё locked,
    # а в ledger ушло 'done' — отчёт врал, что цель очищена).
    $status = if ($removed -eq 0 -and $lockedCnt -gt 0) { 'LOCKED' }
              elseif ($deletedCnt -eq 0) { 'already gone' }   # детей не было вовсе
              else { 'done' }   # пустые папки-дети дают 0 байт, но считаются удалёнными
    return [pscustomobject]@{ Status=$status; RemovedBytes=$removed; LockedCount=$lockedCnt; RemainsBytes=(Get-SizeBytes -Path $Path) }
}

function Init-Ledger {
    # Создаёт ledger.csv с заголовком, если его нет. ВАЖНО: никаких строк до заголовка
    # (иначе Import-Csv примет их за шапку — комментарии ломают колонки). Возвращает путь.
    param([string]$Work, [string]$Name = 'ledger.csv')
    $path = Join-Path $Work $Name
    if (-not (Test-Path -LiteralPath $path) -or ((Get-Item -LiteralPath $path).Length -eq 0)) {
        'ts,phase,object,path,size_before_mb,size_after_mb,status,removed_mb' | Set-Content -Path $path -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
    return $path
}

function Write-Ledger {
    # Дописать строку в ledger.csv. size_* в МБ (0, если не измерялось).
    # ВАЖНО: числовые поля форматируем с ИНВАРИАНТНОЙ культурой (точка как разделитель),
    # иначе в ru-RU '56697.07' печатается как '56697,07' — запятая разрывает CSV-колонки
    # и все поля следом съезжают (baseline/removed/status). Реальный кейс из тестового прогона.
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Phase,
        [string]$Object,
        [string]$TargetPath = '',
        [double]$SizeBeforeMB = 0,
        [double]$SizeAfterMB = 0,
        [string]$Status = '',
        [double]$RemovedMB = 0
    )
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $row = '{0},{1},{2},{3},{4},{5},{6},{7}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Phase, ($Object -replace '[,;]',' '), ($TargetPath -replace '[,";]',' '), ([double]$SizeBeforeMB).ToString('0.####', $ci), ([double]$SizeAfterMB).ToString('0.####', $ci), ($Status -replace '[,";]',''), ([double]$RemovedMB).ToString('0.####', $ci)
    Add-Content -Path $Path -Value $row -Encoding UTF8
}
