# autostart.ps1 — полный отчёт по автозапускам (Фаза 7): Run/RunOnce, Startup, задачи, службы Auto, Winlogon.
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
    $t = $target.Trim('"').Replace('\\','\')
    if ($t -match '^(shell|appx|ms-settings|ms-resource|folder|::\{|\$)') { $script:Sp++; return '(спец.)' }
    if ($t -match '^%') { $script:Sp++; return '(env-переменная)' }
    # Голое имя исполняемого (без пути) — резолвится через %PATH%: не считаем битым
    if ($t -notmatch '[\\/:]' -and $t -match '\.(exe|com|bat|cmd|dll|ps1|vbs)$') { $script:Sp++; return 'PATH-live' }
    if (Test-Path -LiteralPath $t) { $script:L++; return 'LIVE' }
    $script:B++; return 'BROKEN'
}

Log-Line ('=== АВТОЗАПУСКИ ('+$(Get-Date -Format 'yyyy-MM-dd HH:mm')+') ===')
Log-Line ''
Log-Line '=== RUN / RUNONCE ==='
foreach ($rk in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)) {
    $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    Log-Line ('-- ' + $rk)
    foreach ($pr in $props.PSObject.Properties) {
        if ($pr.Name -match '^PS') { continue }
        $exe = Get-ExePath ([string]$pr.Value)
        Log-Line ('   {0} = {1}  [{2}]' -f $pr.Name, $pr.Value, (StatusOf $exe))
    }
}

Log-Line ''
Log-Line '=== STARTUP-папки (user + ProgramData) ==='
foreach ($sf in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")) {
    if (-not (Test-Path -LiteralPath $sf)) { Log-Line ('-- ' + $sf + ' (нет)'); continue }
    Log-Line ('-- ' + $sf)
    foreach ($f in (Get-ChildItem -LiteralPath $sf -File -Force)) {
        if ($f.Extension -eq '.lnk') {
            $sh = New-Object -ComObject WScript.Shell
            $tgt = ''
            try { $tgt = $sh.CreateShortcut($f.FullName).TargetPath } catch { }
            Log-Line ('   ' + $f.Name + ' -> ' + $tgt + ' [' + (StatusOf $tgt) + ']')
        } else { Log-Line ('   ' + $f.Name + ' [не-lnk]') }
    }
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
$wl = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
Log-Line ('Shell    = ' + $wl.Shell)
Log-Line ('Userinit = ' + $wl.Userinit)
Log-Line ''
Log-Line ("ИТОГО: LIVE=$script:L BROKEN=$script:B спец/прочее=$script:Sp  =>  отчёт: " + $out)
Write-Output ("autostart: live=$script:L broken=$script:B special=$script:Sp")
