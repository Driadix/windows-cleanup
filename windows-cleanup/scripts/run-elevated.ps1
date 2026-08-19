# run-elevated.ps1 — единый запуск elevated-скрипта через UAC.
# Особенности:
#   * ПЕРЕД промптом UAC делает parse-check целевого скрипта ([Parser]::ParseFile) —
#     чтобы не жечь UAC-промпты впустую из-за синтаксической ошибки.
#   * Печатает понятную фразу «сейчас появится окно UAC — подтверди» перед запуском.
#   * Ждёт завершения (-Wait) и печатает exit-код elevated-процесса.
# Использование:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File run-elevated.ps1 -Script "D:\...\elevated-cleanup.ps1" [-Args @('/dism')]
# ВАЖНО про -Args из git-bash/Hermes (bash их ломает):
#   * синтаксис @(...) — PowerShell, в bash это своя конструкция ('syntax error near unexpected token (`').
#   * даже словами `-Args '-Work' 'D:\путь'` из bash НЕ работает: bash срезает кавычки, и PS видит
#     `-Work ...` как параметр, а не как значение -> PositionalParameterNotFound. Реальный кейс прогона.
#   НАДЁЖНЫЕ пути из bash:
#     1) (рекомендуется U5) параметры elevated-скрипта со значениями по умолчанию — тогда -Args не нужен;
#     2) переменная окружения PC_ELEV_ARGS: аргументы построчно, ОДНА строка = ОДИН аргумент (без кавычек и
#        без '-' магии; пути с пробелами — целиком в одной строке). Из bash удобно через ANSI-C строку:
#          PC_ELEV_ARGS=$'-Work\nD:\путь\n-Dism'   ;   ./run-elevated.ps1 -Script "..."
#   (в PowerShell -Args работает как обычно: @(...) или 'a','b').
# Exit: 0 успех (см. exit-код elevated), 1 целевой скрипт не найден, 2 parse-ошибка,
#       3 VERIFY-FAIL — elevated-процесс не подтвердил права администратора (см. -ElevLog).
param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$Args = @(),
    [string]$ElevLog = ''   # ожидаемый лог elevated-скрипта (для верификации фактического подъёма прав)
)
$ErrorActionPreference = 'Stop'

# --- аргументы через PC_ELEV_ARGS (обход ломки quoting из bash), если -Args не передан ---
# Одна строка = один аргумент. НЕ используем Invoke-Expression с @(...)-обёрткой: там '-Work' парсится
# как команда и падает (реальный кейс прогона 0.2.2).
if (-not $Args -and $env:PC_ELEV_ARGS) {
    $Args = @($env:PC_ELEV_ARGS -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if (-not (Test-Path -LiteralPath $Script)) { Write-Error ("Целевой скрипт не найден: " + $Script); exit 1 }

# --- parse-check до UAC ---
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count) {
    Write-Output 'PARSE-FAIL: elevated-скрипт не пройдёт проверку синтаксиса — UAC НЕ запрашиваю:'
    $errs | ForEach-Object { Write-Output ('   ' + $_.Message) }
    exit 2
}

Write-Output 'Сейчас появится окно UAC — подтверди (подожди завершения elevated-скрипта).'
$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"'))
foreach ($arg in $Args) { $a += $arg }
$p = Start-Process -FilePath powershell.exe -ArgumentList $a -Verb RunAs -PassThru -Wait
Write-Output ("UAC-exit: " + $p.ExitCode)

# --- верификация фактического подъёма прав (не верим ни UAC-диалогу, ни exit-коду) ---
# В сессиях агентов подтверждённый UAC может оставить процесс на Medium integrity (реальный кейс
# 2026-08-19: diag_elevated.log показал elevated:False). Elevated-скрипт пишет в первую строку своего
# лога "elevated: True/False" — проверяем её и честно сообщаем результат + fallback.
if ($ElevLog -and (Test-Path -LiteralPath $ElevLog)) {
    $first = Get-Content -LiteralPath $ElevLog -TotalCount 1 -ErrorAction SilentlyContinue
    if ($first -match '^elevated:\s*True\b') {
        Write-Output 'VERIFY-OK: elevated-процесс подтвердил права администратора (elevated: True).'
    } elseif ($first -match '^elevated:\s*False\b') {
        Write-Output ''
        Write-Output 'VERIFY-FAIL: elevated-процесс НЕ получил права администратора (в его логе elevated: False).'
        Write-Output '  Это бывает, когда агент запущен не от админа в неинтерактивной сессии — даже подтверждённый'
        Write-Output '  UAC оставляет процесс на Medium integrity. Elevated-проход фактически НЕ выполнялся.'
        Write-Output '  Что делать (любой вариант):'
        Write-Output '   1) Перезапустить агента ОТ ИМЕНИ АДМИНИСТРАТОРА — тогда elevated-скрипты работают без UAC'
        Write-Output '      (повторно запустить тот же проход, состояние сохранено в session_state.md).'
        Write-Output '   2) Или выполнить elevated-команду вручную из админ-консоли (правая кнопка → "Запуск от имени'
        Write-Output '      администратора"), затем вернуться к агенту.'
        Write-Output ('     Команда: powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"')
        exit 3
    } else {
        Write-Output ('VERIFY-WARN: не смог оценить права по логу (' + $ElevLog + '), доверяю exit-коду.')
    }
} elseif ($ElevLog) {
    Write-Output ('VERIFY-WARN: ожидаемый лог elevated-скрипта не найден (' + $ElevLog + ') — доверяю exit-коду.')
}

if ($p.ExitCode -eq 0) { Write-Output 'OK: elevated-скрипт завершился без ошибок (смотри его лог).' }
else { Write-Output ('Замечание: exit=' + $p.ExitCode + ' — вероятны ошибки внутри (смотри лог скрипта).') }
exit 0
