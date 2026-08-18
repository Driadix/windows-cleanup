# Параметры
param(
    # -Work — путь рабочей папки (единообразно с остальными phase-скриптами). Алиас -OutDir
    # оставлен для совместимости со старыми вызовами (оба имени работают).
    [Parameter(Mandatory=$true)][Alias('OutDir')][string]$Work,
    [string[]]$Places,
    [switch]$Remove
)

# Поиск битых ярлыков в 4 стандартных местах (.lnk и .url); с -Places сканирует указанные каталоги.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File shortcuts.ps1 -Work "<рабочая папка>"
#   (совместимо: -OutDir "<рабочая папка>")
# Без -Remove — только отчёт; с -Remove — удаляет битые (с логом). Живые никогда не трогаются.
# Нюансы: .url — это INI ([InternetShortcut] URL=...); для веб-ссылки TargetPath пустой легитимно,
# поэтому .url считается битой только при пустой/отсутствующей URL=. Отчёт пишем построчно без усечения путей.

$ErrorActionPreference = 'SilentlyContinue'
$sh = New-Object -ComObject WScript.Shell

if (-not $Places -or $Places.Count -eq 0) {
    $Places = @(
        "$env:USERPROFILE\Desktop",
        "$env:ProgramData\Microsoft\Windows\Desktop",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    )
}

function Test-UrlBroken([string]$path) {
    $content = $null
    try { $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { }
    if ($null -eq $content) { try { $content = Get-Content -LiteralPath $path -Raw } catch { } }
    $m = [regex]::Match([string]$content, '(?im)^URL=[ \t]*(.+?)\s*$')
    return (-not $m.Success) -or [string]::IsNullOrWhiteSpace($m.Groups[1].Value)
}

$broken = @(); $alive = 0
foreach ($p in $places) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    # -Include нельзя с -LiteralPath (пропускает фильтр) → фильтруем по Extension явно
    Get-ChildItem -LiteralPath $p -Recurse -Force -File |
        Where-Object { $_.Extension -in '.lnk', '.url' } |
        ForEach-Object {
            $f = $_.FullName
            if ($_.Extension -eq '.lnk') {
                $target = ''
                try { $target = $sh.CreateShortcut($f).TargetPath } catch { }
                if ([string]::IsNullOrWhiteSpace($target)) {
                    # Пустая цель = shell-объект/verbm (Этот компьютер, Панель управления...) — НЕ битая, не трогаем
                    $alive++
                } elseif ($target -like '::*' -or $target -match '^(shell|folder|appx?|digitalsigner|ms-settings):') {
                    $alive++   # namespace-таргеты (shell:, ms-settings: и т.п.) — валидны
                } elseif (-not (Test-Path -LiteralPath $target)) {
                    $broken += [pscustomobject]@{ Link = $f; Target = $target }
                } else { $alive++ }
            } else {
                # .url: битая, только если URL отсутствует/пустая
                if (Test-UrlBroken $f) { $broken += [pscustomobject]@{ Link = $f; Target = '(нет URL)' } }
                else { $alive++ }
            }
        }
}

if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$report = Join-Path $Work 'broken_shortcuts.txt'
$broken | ForEach-Object { "$($_.Link)`t$($_.Target)" } | Set-Content -Path $report -Encoding UTF8

if ($Remove) {
    $log = Join-Path $Work 'broken_shortcuts_log.txt'
    foreach ($b in $broken) {
        try {
            Remove-Item -LiteralPath $b.Link -Force -Recurse
            Add-Content -Path $log -Value "removed: $($b.Link)" -Encoding UTF8
        } catch { Add-Content -Path $log -Value "LOCKED: $($b.Link)" -Encoding UTF8 }
    }
}

Write-Output "broken=$($broken.Count) alive=$alive report=$report"
