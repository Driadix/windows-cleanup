# Параметры
param(
    # -Work — путь рабочей папки (единообразно с остальными phase-скриптами). Алиас -OutDir
    # оставлен для совместимости со старыми вызовами (оба имени работают).
    [Parameter(Mandatory=$true)][Alias('OutDir')][string]$Work,
    [string[]]$Places,
    [switch]$Remove
)

# Поиск битых ярлыков (.lnk и .url) в стандартных местах; с -Places сканирует указанные каталоги.
# Места берутся через shell-folders, а не склейкой $env:USERPROFILE — иначе при OneDrive KFM
# (Desktop/Documents перенесены в %USERPROFILE%\OneDrive\...) реальный рабочий стол пропускается.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File shortcuts.ps1 -Work "<рабочая папка>"
#   (совместимо: -OutDir "<рабочая папка>")
# Без -Remove — только отчёт; с -Remove — удаляет битые (с логом removed/LOCKED). Живые не трогаются.
# Нюансы: .url — это INI ([InternetShortcut] URL=...); для веб-ссылки TargetPath пустой легитимно,
# поэтому .url считается битой только при пустой/отсутствующей URL=. Отчёт построчно, пути без усечения.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')   # Test-UrlBroken / Test-ProtectedRoot из общей библиотеки
$ErrorActionPreference = 'SilentlyContinue'

if (-not $Places -or $Places.Count -eq 0) {
    # shell-folders: учитывают перенаправление (OneDrive KFM) и локализованные имена.
    # CommonDesktopDirectory/CommonPrograms могут отсутствовать на старых сборках — подстраховываемся литералом.
    $Places = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        "$env:ProgramData\Microsoft\Windows\Desktop",
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms'),
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch"
    ) | Where-Object { $_ }
}
# COM-объект один на весь прогон (создание внутри цикла — утечка RCW на сотнях ярлыков).
$sh = New-Object -ComObject WScript.Shell

$broken = New-Object 'System.Collections.Generic.List[object]'
$alive = 0
try {
    foreach ($p in $Places) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        # -Include нельзя с -LiteralPath (пропускает фильтр) → фильтруем по Extension явно
        Get-ChildItem -LiteralPath $p -Recurse -Force -File |
            Where-Object { $_.Extension -in '.lnk', '.url' } |
            ForEach-Object {
                $f = $_.FullName
                if ($_.Extension -eq '.lnk') {
                    $sc = $null
                    $target = ''
                    try { $sc = $sh.CreateShortcut($f); $target = $sc.TargetPath } catch { }
                    finally { if ($sc) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc) } }
                    # Цель может храниться нераскрытой (%windir%\system32\...); без раскрытия Test-Path
                    # дал бы ложный «битый».
                    $target = [Environment]::ExpandEnvironmentVariables([string]$target)
                    if ([string]::IsNullOrWhiteSpace($target)) {
                        # Пустая цель = shell-объект (Этот компьютер, Панель управления...) — НЕ битая
                        $alive++
                    } elseif ($target -like '::*' -or $target -match '^(shell|folder|appx?|digitalsigner|ms-settings|ms-appx):') {
                        $alive++   # namespace-таргеты (shell:, ms-settings: и т.п.) — валидны
                    } elseif (-not (Test-Path -LiteralPath $target)) {
                        $broken.Add([pscustomobject]@{ Link = $f; Target = $target })
                    } else { $alive++ }
                } else {
                    # .url: битая, только если URL отсутствует/пустая
                    if (Test-UrlBroken $f) { $broken.Add([pscustomobject]@{ Link = $f; Target = '(нет URL)' }) }
                    else { $alive++ }
                }
            }
    }
} finally { if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) } }

if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$report = Join-Path $Work 'broken_shortcuts.txt'
$broken | ForEach-Object { "$($_.Link)`t$($_.Target)" } | Set-Content -Path $report -Encoding UTF8

if ($Remove) {
    $log = Join-Path $Work 'broken_shortcuts_log.txt'
    foreach ($b in $broken) {
        # SilentlyContinue не делает ошибку terminating → catch не сработал бы, и заблокированный
        # ярлык записался бы как 'removed'. Поэтому -ErrorAction Stop + обязательный Test-Path.
        try { Remove-Item -LiteralPath $b.Link -Force -Recurse -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $b.Link) { Add-Content -Path $log -Value "LOCKED: $($b.Link)" -Encoding UTF8 }
        else { Add-Content -Path $log -Value "removed: $($b.Link)" -Encoding UTF8 }
    }
}

Write-Output "broken=$($broken.Count) alive=$alive report=$report"
