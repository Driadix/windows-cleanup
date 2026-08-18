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
# Exit: 0 успех (см. exit-код elevated), 1 целевой скрипт не найден, 2 parse-ошибка.
param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$Args = @()
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
if ($p.ExitCode -eq 0) { Write-Output 'OK: elevated-скрипт завершился без ошибок (смотри его лог).' }
else { Write-Output ('Замечание: exit=' + $p.ExitCode + ' — вероятны ошибки внутри (смотри лог скрипта).') }
exit 0
