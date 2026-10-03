# autostart.ps1 — полный отчёт по автозапускам (Фаза 7): Run/RunOnce, Startup, задачи, службы Auto,
# Winlogon, StartupApproved (состояние вкл/выкл из Диспетчера задач) + сироты StartupApproved.
# По каждой записи — цель (исполняемый файл) и статус LIVE / BROKEN / (спец.).
# Выход: -Work\autostart.txt + сводка в консоль. Только отчёт (ничего не удаляет).
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File autostart.ps1 -Work "рабочая папка"
param([Parameter(Mandatory=$true)][string]$Work)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$out = Join-Path $Work 'autostart.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
$script:L  = 0
$script:B  = 0
$script:Sp  = 0
function Log-Line([string]$m) { Add-Content -Path $out -Value $m -Encoding UTF8 }
function StatusOf([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { $script:Sp++; return '(пусто)' }
    $t = [regex]::Replace($target.Trim('"'), '\\{2,}', { param($m) if ($m.Index -eq 0) { '\\' } else { '\' } })
    if ($t -match '^(shell|appx|ms-settings|ms-resource|folder|::\{|\$)') { $script:Sp++; return '(спец.)' }
    if ($t -match '^%') { $script:Sp++; return '(env-переменная)' }
    # Голое имя исполняемого (без пути) — резолвится через %PATH%: не считаем битым
    if ($t -notmatch '[\\/:]' -and $t -match '\.(exe|com|bat|cmd|dll|ps1|vbs)$') { $script:Sp++; return 'PATH-live' }
    if (Test-Path -LiteralPath $t) { $script:L++; return 'LIVE' }
    $script:B++; return 'BROKEN'
}
# Значения Run/RunOnce, которые реально существуют (нужно для поиска сирот StartupApproved).
$script:knownRun = New-Object 'System.Collections.Generic.HashSet[string]'

Log-Line ('=== АВТОЗАПУСКИ ('+$(Get-Date -Format 'yyyy-MM-dd HH:mm')+') ===')
Log-Line ''
Log-Line '=== RUN / RUNONCE ==='
foreach ($rk in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
)) {
    $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    Log-Line ('-- ' + $rk)
    foreach ($pr in $props.PSObject.Properties) {
        if ($pr.Name -match '^PS') { continue }
        [void]$script:knownRun.Add($pr.Name.ToUpperInvariant())
        $exe = Get-ExePath ([string]$pr.Value)
        Log-Line ('   {0} = {1}  [{2}]' -f $pr.Name, $pr.Value, (StatusOf $exe))
    }
}

Log-Line ''
Log-Line '=== STARTUP-папки (user + ProgramData) ==='
foreach ($sf in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")) {
    if (-not (Test-Path -LiteralPath $sf)) { Log-Line ('-- ' + $sf + ' (нет)'); continue }
    Log-Line ('-- ' + $sf)
    # Один COM-объект на папку (создание внутри цикла по файлам — утечка RCW),
    # и освобождаем явно в finally.
    $sh = $null
    try {
        $sh = New-Object -ComObject WScript.Shell
        foreach ($f in (Get-ChildItem -LiteralPath $sf -File -Force)) {
            [void]$script:knownRun.Add($f.Name.ToUpperInvariant())
            if ($f.Extension -eq '.lnk') {
                $sc = $null
                $tgt = ''
                try { $sc = $sh.CreateShortcut($f.FullName); $tgt = $sc.TargetPath } catch { }
                finally { if ($sc) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc) } }
                Log-Line ('   ' + $f.Name + ' -> ' + $tgt + ' [' + (StatusOf $tgt) + ']')
            } else { Log-Line ('   ' + $f.Name + ' [не-lnk]') }
        }
    } finally { if ($sh) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) } }
}

Log-Line ''
Log-Line '=== ЗАДАЧИ (не Microsoft\Windows) ==='
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' })) {
    $acts = @()
    foreach ($a in $t.Actions) { $exe = Get-ExePath ([string]$a.Execute + ' ' + [string]$a.Arguments); $acts += ($a.Execute + ' ' + $a.Arguments + '  [' + (StatusOf $exe) + ']') }
    Log-Line ('{0}{1} [{2}]  {3}' -f $t.TaskPath, $t.TaskName, $t.State, ($acts -join ' || '))
}

Log-Line ''
Log-Line '=== СЛУЖБЫ Auto ==='
foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName })) {
    $exe = Get-ExePath ([string]$s.PathName)
    Log-Line ('{0} [{1}] path~{2}  [{3}]' -f $s.Name, $s.State, $exe, (StatusOf $exe))
}

Log-Line ''
Log-Line '=== WINLOGON ==='
$wl = Get-ItemProperty -LiteralPath 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
if ($wl) {
    foreach ($n in @('Shell','Userinit','AppSetup','VmApplet')) {
        $v = [string]$wl.$n
        if (-not $v) { continue }
        # Shell/Userinit могут содержать несколько путей через запятую — проверяем каждый.
        $stat = @()
        foreach ($part in ($v -split ',')) {
            $pt = $part.Trim()
            if ($pt) { $stat += (StatusOf (Get-ExePath $pt)) }
        }
        Log-Line ('{0,-9}= {1}  [{2}]' -f $n, $v, ($stat -join ', '))
    }
} else { Log-Line 'Winlogon: ключ не найден' }

Log-Line ''
Log-Line '=== STARTUPAPPROVED (вкл/выкл в Диспетчере задач) ==='
# Первый байт 12-байтового значения: 0x02 = ВЫКЛ, 0x03 = ВКЛ (остальное — не гарантируем, помечаем).
# Остальные байты — FILETIME последнего изменения. Сирота = записано состояние, но самого значения
# Run/файла Startup уже нет (реальный кейс прогона: RazerCortex снят с HKLM Run, состояние осталось).
$saStates = @{}
foreach ($rk in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
)) {
    $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    Log-Line ('-- ' + $rk)
    foreach ($pr in $props.PSObject.Properties) {
        if ($pr.Name -match '^PS') { continue }
        # Имя НЕ должно быть $b/$l/$sp: переменные PowerShell регистронезависимы, а $script:B/$script:L/
        # $script:Sp — наши счётчики; $b = ... затирал BROKEN (реальный кейс прогона 2026-10-03:
        # в сводку попал byte[] вместо числа).
        $saBytes = $pr.Value
        $state = 'неизв.'
        $when = ''
        if ($saBytes -is [byte[]] -and $saBytes.Length -ge 12) {
            switch ($saBytes[0]) {
                2 { $state = 'ВЫКЛ' }
                3 { $state = 'ВКЛ' }
                default { $state = ('спец. 0x{0:x2}' -f $saBytes[0]) }
            }
            # Нулевой FILETIME (все байты 0) = время не сохранено; печатать его как дату нельзя —
            # получается бессмысленное «изм. 1601-01-01 03:00» (реальный кейс прогона 2026-10-03).
            try {
                $ft = [BitConverter]::ToInt64($saBytes, 4)
                if ($ft -gt 0) { $when = [DateTime]::FromFileTime($ft).ToString('yyyy-MM-dd HH:mm') }
            } catch { }
        } elseif ($saBytes -is [byte[]]) {
            $state = ('битое значение, {0} байт' -f $saBytes.Length)
        }
        $saStates[$pr.Name.ToUpperInvariant()] = $state
        $orphan = if ($script:knownRun.Contains($pr.Name.ToUpperInvariant())) { '' } else { '  [СИРОТА: значения Run/файла Startup нет]' }
        Log-Line ('   {0,-40} {1}{2}{3}' -f $pr.Name, $state, $(if ($when) { '  (изм. ' + $when + ')' } else { '' }), $orphan)
    }
}
if (-not $saStates) { Log-Line '(StartupApproved пуст или недоступен)' }
Log-Line ("ИТОГО: LIVE=$script:L BROKEN=$script:B спец/прочее=$script:Sp записей StartupApproved=$($saStates.Count)  =>  отчёт: " + $out)
Write-Output ("autostart: live=$script:L broken=$script:B special=$script:Sp")
