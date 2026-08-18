# run-elevated.ps1 — единый запуск elevated-скрипта через UAC.
# Особенности:
#   * ПЕРЕД промптом UAC делает parse-check целевого скрипта ([Parser]::ParseFile) —
#     чтобы не жечь UAC-промпты впустую из-за синтаксической ошибки.
#   * Печатает понятную фразу «сейчас появится окно UAC — подтверди» перед запуском.
#   * Ждёт завершения (-Wait) и печатает exit-код elevated-процесса.
# Использование:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File run-elevated.ps1 -Script "D:\...\elevated-cleanup.ps1" [-Args @('/dism')]
# ВАЖНО про -Args: синтаксис @(...) — это PowerShell. Из git-bash/Hermes он НЕ работает
# (bash воспринимает '@(' как свой синтаксис: 'syntax error near unexpected token (`').
# Из bash передавай -Args словами раздельно:  -Args '-Work' 'D:\путь'  -Dism
# или вовсе без -Args: делай параметры elevated-скрипта со значениями по умолчанию (U5).
# Exit: 0 успех (см. exit-код elevated), 1 целевой скрипт не найден, 2 parse-ошибка.
param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$Args = @()
)
$ErrorActionPreference = 'Stop'

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
