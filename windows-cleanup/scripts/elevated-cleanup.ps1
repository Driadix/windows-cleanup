# elevated-cleanup.ps1 — системный ELEVATED-проход (запускать через run-elevated.ps1 или Start-Process -Verb RunAs).
# Чистит: Windows\Temp (+SystemTemp на Win11), SoftwareDistribution (Download+DataStore),
#          DeliveryOptimization, FontCache, Logs\CBS, WER (ProgramData), Minidump/LiveKernelReports,
#          MEMORY.DMP, $WINDOWS.~BT/$GetCurrent/$WinREAgent/$SysReset (+ Windows.old по флагу -WindowsOld),
#          ретраит -Extra (LOCKED из user-прохода), замер vssadmin shadowstorage, DISM (флаг -Dism).
# Требует администратора. Логи/лидгер пишет в -Work.
# Использование (elevated):
#   run-elevated.ps1 -Script "<skill_dir>\scripts\elevated-cleanup.ps1" -Args @('-Work',"<рабочая папка>",'-Dism')
# Ретрай LOCKED: -Extra "<путь1>|<путь2>" (одна строка; '|' — запрещённый в именах Windows символ,
# поэтому разделитель однозначен; см. комментарий у param).
param(
    [Parameter(Mandatory=$true)][string]$Work,
    [switch]$Dism,
    [switch]$WindowsOld,
    [string]$Extra = ''   # ретрай LOCKED из user-прохода; пути через '|' (символ запрещён в именах Windows,
                          # поэтому разделитель однозначен; [string[]] из командной строки -File в PS 5.1
                          # НЕ собирает несколько кавычек-токенов — реальный кейс прогона 2026-10-03)
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$log = Join-Path $Work 'elevated_cleanup.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
# Первая строка лога — фактический уровень прав ПРОЦЕССА (в сессиях агентов UAC-подъём может молча не
# сработать: процесс остаётся Medium integrity даже после подтверждения — реальный кейс 2026-08-19).
# run-elevated.ps1 читает эту строку после -Wait и, если False, честно сообщает, что elevated-проход
# НЕ выполнялся, и советует перезапустить агента от админа (см. run-elevated.ps1).
Add-Content -Path $log -Value ("elevated: " + (Test-Elevated)) -Encoding UTF8
$ledger = Init-Ledger -Work $Work
$script:totalMB = 0.0
$win = $env:SystemRoot
$sys = $env:SystemDrive
# Ранний выход, если UAC молча не повысил права (реальный кейс 2026-08-19): не жжём время на
# заведомо LOCKED-удаления системных целей. Первая строка лога (elevated: False) уже записана —
# run-elevated.ps1 -ElevLog прочитает её и вернёт VERIFY-FAIL. Службы ещё не остановлены.
if (-not (Test-Elevated)) {
    Add-Content -Path $log -Value 'SKIP: процесс не админ — системные цели не трогаю.' -Encoding UTF8
    Write-Output 'ELEVATED-FALSE: elevated-проход пропущен (нет прав администратора).'
    exit 4
}

function Write-LogAndLedger($Object, $Path, $Status, $BeforeMB, $AfterMB, $RemovedMB) {
    $line = "{0}`t{1}`t{2} МБ`tбыло {3} МБ`tосталось {4} МБ" -f $Object, $Status, [math]::Round($RemovedMB,1), [math]::Round($BeforeMB,1), [math]::Round($AfterMB,1)
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Ledger -Path $ledger -Phase 'elevated' -Object $Object -TargetPath $Path -SizeBeforeMB ([math]::Round($BeforeMB,1)) -SizeAfterMB ([math]::Round($AfterMB,1)) -Status $Status -RemovedMB ([math]::Round($RemovedMB,1))
    $script:totalMB += $RemovedMB
}

# Запоминаем исходное состояние служб, чтобы вернуть их после прохода (иначе Windows Update /
# BITS / Delivery Optimization останутся остановленными до ручной перезагрузки).
$svcStates = @{}
foreach ($svc in @('wuauserv','DoSvc','BITS','FontCache')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) { $svcStates[$svc] = $s.Status }
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}

# --- содержимое папок ---
foreach ($t in @(
    @{ O='Windows\Temp'; P=(Join-Path $win 'Temp') },
    # SystemTemp есть только на Win11 24H2+; на Win10 Remove-Contents вернёт 'already gone' —
    # отдельный guard не нужен, цель просто не найдётся.
    @{ O='Windows\SystemTemp (Win11+)'; P=(Join-Path $win 'SystemTemp') },
    @{ O='SoftwareDistribution\Download'; P=(Join-Path $win 'SoftwareDistribution\Download') },
    @{ O='SoftwareDistribution\DataStore'; P=(Join-Path $win 'SoftwareDistribution\DataStore') },
    @{ O='DeliveryOptimization (NetworkSvc)'; P=(Join-Path $win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization') },
    @{ O='FontCache (LocalService)'; P=(Join-Path $win 'ServiceProfiles\LocalService\AppData\Local\FontCache') },
    @{ O='Logs\CBS'; P=(Join-Path $win 'Logs\CBS') },
    @{ O='WER (ProgramData)'; P=(Join-Path $env:ProgramData 'Microsoft\Windows\WER') },
    @{ O='Minidump'; P=(Join-Path $win 'Minidump') },
    @{ O='LiveKernelReports'; P=(Join-Path $win 'LiveKernelReports') }
)) {
    $r = Remove-Contents -Path $t.P
    $afterMB = $r.RemainsBytes / 1MB
    $remMB = $r.RemovedBytes / 1MB
    $beforeMB = $afterMB + $remMB   # до = удалено + осталось (лишний обход Get-SizeBytes не нужен)
    Write-LogAndLedger $t.O $t.P $r.Status $beforeMB $afterMB $remMB
}

# --- системные остатки (папки целиком) ---
$leftovers = @((Join-Path $sys '$WINDOWS.~BT'),(Join-Path $sys '$GetCurrent'),(Join-Path $sys '$WinREAgent'),(Join-Path $sys '$SysReset'))
if ($WindowsOld) { $leftovers += (Join-Path $sys 'Windows.old') }   # только по явному согласию (убирает откат ОС)
foreach ($p in $leftovers) {
    $r = Remove-Target -Path $p
    Write-LogAndLedger $p $p $r.Status (($r.RemovedBytes + $r.RemainsBytes)/1MB) ($r.RemainsBytes/1MB) ($r.RemovedBytes/1MB)
}

# --- одиночные системные дампы (файлы целиком) ---
foreach ($p in @((Join-Path $win 'MEMORY.DMP'))) {
    $r = Remove-Target -Path $p
    Write-LogAndLedger $p $p $r.Status (($r.RemovedBytes + $r.RemainsBytes)/1MB) ($r.RemainsBytes/1MB) ($r.RemovedBytes/1MB)
}

# --- ретрай LOCKED из user-прохода (-Extra) ---
foreach ($p in @($Extra -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $r = Remove-Target -Path $p
    Write-LogAndLedger ('EXTRA ' + $p) $p $r.Status (($r.RemovedBytes + $r.RemainsBytes)/1MB) ($r.RemainsBytes/1MB) ($r.RemovedBytes/1MB)
}

# --- Замер теневого хранилища (нужен для опции Фазы 9 «Ограничить тени») ---
# SKILL.md/final-options.md обещают замер vssadmin уже в Фазе 2/elevated-проходе, но до этого
# его не было нигде. Команда требует админа — отсюда и берём (user-проход вернул бы отказ в правах).
$vssOut = Join-Path $Work 'shadowstorage.txt'
$vss = (& vssadmin.exe list shadowstorage 2>&1 | Out-String).Trim()
$vss | Set-Content -LiteralPath $vssOut -Encoding UTF8
Add-Content -Path $log -Value ('SHADOWSTORAGE: ' + ($vss -replace '\r?\n', ' | ')) -Encoding UTF8

# --- DISM ---
if ($Dism) {
    Add-Content -Path $log -Value ("DISM /StartComponentCleanup started " + (Get-Date -Format 'HH:mm:ss')) -Encoding UTF8
    $dismOut = Join-Path $Work 'dism_startcomponentcleanup.txt'
    dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>$null | Out-File -FilePath $dismOut -Encoding UTF8
    Add-Content -Path $log -Value ("DISM done exit=" + $LASTEXITCODE) -Encoding UTF8
}

# --- возвращаем службы, которые были запущены до прохода ---
foreach ($svc in @($svcStates.Keys)) {
    if ($svcStates[$svc] -eq 'Running') {
        try { Start-Service -Name $svc -ErrorAction Stop }
        catch { Add-Content -Path $log -Value ('WARN: не удалось запустить ' + $svc + ': ' + $_.Exception.Message) -Encoding UTF8 }
    }
}

Add-Content -Path $log -Value ("ИТОГО elevated: {0} МБ" -f [math]::Round($script:totalMB,1)) -Encoding UTF8
Write-Output ("DONE totalMB=" + [math]::Round($script:totalMB,1) + " log=$log")
