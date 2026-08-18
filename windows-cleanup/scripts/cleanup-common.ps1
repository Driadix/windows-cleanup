# cleanup-common.ps1 — общая библиотека для phase-скриптов windows-cleanup
# Подключается через  . "$env:USERPROFILE\AppData\Local\hermes\skills\...\scripts\cleanup-common.ps1"  (или путём из репо).
# Правила:
#   * Никаких функций с именами ключевых слов PS (Do/ForEach/...).
#   * Никаких `return $null` внутри ForEach-Object-пайплайнов (emit $null ломает вызов).
#   * Счётчики возвращаем из функций, агрегирует вызывающий (в `$script:` своей области).
#   * Любое удаление: только -LiteralPath -Recurse -Force + статус через Test-Path.
#   * Логи/CSV — UTF-8.
$ErrorActionPreference = 'Continue'

function Test-Elevated {
    # Возвращает True, если процесс под администратором (по привилегии, не по SID).
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
}

function Get-SizeBytes([string]$Path) {
    # Суммарный размер всех файлов внутри пути (рекурсивно, пропуская ошибки доступа).
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0L }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $s) { return 0L }
    return [long]$s
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

function Get-VolumeBrief {
    # Строки по томам с буквой:  "C: | label=X | free 54,20 ГБ"
    Get-Volume | Where-Object DriveLetter | ForEach-Object {
        '{0}: | {1} | свободно {2} ГБ' -f $_.DriveLetter, $(if ($_.FileSystemLabel) { $_.FileSystemLabel } else { '(нет метки)' }), [math]::Round($_.SizeRemaining / 1GB, 2)
    }
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
    # Службы WMI могут отдавать путь с удвоенными backslash'ами — схлопываем до старта разбора.
    $t = $CmdLine.Trim().Replace('\\','\')
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

function Test-LnkAlive([string]$Path) {
    # .lnk: живой, если цель существует; пустая цель / shell:/ms-settings:/::{CLSID} — легитимно.
    $sh = New-Object -ComObject WScript.Shell
    $target = ''
    try { $target = $sh.CreateShortcut($Path).TargetPath } catch { }
    if ([string]::IsNullOrWhiteSpace($target)) { return $true }          # shell-объекты
    if ($target -like '::*' -or $target -match '^(shell|folder|appx?|digitalsigner|ms-settings|ms-appx):') { return $true }
    return (Test-Path -LiteralPath $target)
}

function Remove-Target {
    # Удалить файл ИЛИ папку целиком. Возвращает объект: Status / RemovedBytes / RemainsBytes.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Status='already gone'; RemovedBytes=0L; RemainsBytes=0L } }
    $before = Get-SizeBytes -Path $Path
    $ok = $false
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $ok = -not (Test-Path -LiteralPath $Path)
    } catch { $ok = -not (Test-Path -LiteralPath $Path) }
    if ($ok) { return [pscustomobject]@{ Status='removed'; RemovedBytes=$before; RemainsBytes=0L } }
    return [pscustomobject]@{ Status='LOCKED'; RemovedBytes=0L; RemainsBytes=(Get-SizeBytes -Path $Path) }
}

function Remove-Contents {
    # Удалить СОДЕРЖИМОЕ папки (саму папку не трогаем). Возвращает объект со статусами.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Status='already gone'; RemovedBytes=0L; LockedCount=0; RemainsBytes=0L } }
    $before = Get-SizeBytes -Path $Path
    $removed = 0L; $lockedCnt = 0
    foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        $sz = if ($item.PSIsContainer) { Get-SizeBytes -Path $item.FullName } else { [long]$item.Length }
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $removed += $sz
        } catch { $lockedCnt++ }
    }
    return [pscustomobject]@{ Status='done'; RemovedBytes=$removed; LockedCount=$lockedCnt; RemainsBytes=(Get-SizeBytes -Path $Path) }
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
