# observe.ps1 — диагностический журнал (observations.md) для отладки скилла у тестеров.
# НИКАК не влияет на основной воркфлоу: только дописывает строку в observations.md рабочей папки.
# Включено по умолчанию; отключить разово: $env:PC_CLEANUP_DIAG='0' (в bash: export PC_CLEANUP_DIAG=0).
# Выкорчевать целиком: удалить этот скрипт + секцию «Диагностика» в SKILL.md (воркфлоу не трогаем).
# Использование:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File observe.ps1 -Work "рабочая папка" -Level error -Phase "scan" -Msg "текст"
#   Уровни: info | warn | error. Формат строки: | HH:MM:SS | Фаза | LEVEL | запись |
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [Parameter(Mandatory=$true)][string]$Msg,
    [string]$Level = 'info',
    [string]$Phase = '-'
)
if ($env:PC_CLEANUP_DIAG -eq '0') { exit 0 }   # диагностика выключена — no-op
if (-not $Work -or -not $Msg) { exit 0 }
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$out = Join-Path $Work 'observations.md'
$lvl = $Level.ToUpperInvariant()
if (-not (Test-Path -LiteralPath $out)) {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $hdr = @(
        '# Диагностика прогона windows-cleanup (observations.md)',
        '',
        ('ОС: {0} | Build {1} | PS {2}' -f $(if ($os) { $os.Caption } else { '?' }), $(if ($os) { $os.BuildNumber } else { '?' }), $PSVersionTable.PSVersion),
        ('Машина: ' + $env:COMPUTERNAME + ' | Пользователь: ' + $env:USERNAME + ' | Рабочая папка: ' + $Work),
        ('Старт журнала: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        '',
        'Проблемы/затупы/аномалии, замеченные при прогоне. Скинь этот файл тому, кто собирает отзывы о скилле.',
        '',
        '| Когда | Фаза | Уровень | Запись |',
        '|---|---|---|---|'
    )
    $hdr | Set-Content -Path $out -Encoding UTF8
}
$flat = ($Msg -replace '\|', '/' -replace '\s*\r?\n\s*', ' ')
$line = '| {0} | {1} | {2} | {3} |' -f (Get-Date -Format 'HH:mm:ss'), $Phase, $lvl, $flat
Add-Content -Path $out -Value $line -Encoding UTF8
Write-Output ("OBSERVATION-LOGGED: " + $out)
