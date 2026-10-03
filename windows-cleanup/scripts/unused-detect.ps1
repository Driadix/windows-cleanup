# unused-detect.ps1 — артефакт Фазы 2: `unused_hints.txt` (кандидаты «возможно не используется»).
# Только кандидаты — удаление НИКОГДА не выполняется, решает пользователь (ADR 0004).
# Сигналы (по отдельности слабые, вместе — надёжнее): MuiCache + UserAssist\Count (запускалась ли
# вообще), Prefetch *.pf (последний запуск), LastWriteTime каталога установки, не в автозапуске
# (Run/RunOnce + Startup-папки + задачи + авто-службы), не запущен процесс.
# Оговорки (зашиты в фильтры, но помни): CLI-тулы и игры через чужие лаунчеры НЕ дают следа;
# Prefetch на SSD часто выключен и читается только админом → 0 файлов = сигнал НЕДОСТУПЕН,
# а не доказательство неиспользования.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File unused-detect.ps1 -Work "рабочая папка"
param([Parameter(Mandatory=$true)][string]$Work, [int]$MinMB = 100)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$out = Join-Path $Work 'unused_hints.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
function L([string]$m) { Add-Content -Path $out -Value $m -Encoding UTF8 }

# --- следы запуска (MuiCache + UserAssist\Count + Prefetch) ---
$runPaths = New-Object 'System.Collections.Generic.HashSet[string]'   # полные пути (UPPER)
$runNames = New-Object 'System.Collections.Generic.HashSet[string]'   # имена exe без расширения (UPPER)
function Add-RunTrace([string]$FullPath) {
    if ($FullPath -match '^[A-Za-z]:\\') {
        [void]$runPaths.Add($FullPath.ToUpperInvariant())
        $n = [IO.Path]::GetFileNameWithoutExtension($FullPath)
        if ($n) { [void]$runNames.Add($n.ToUpperInvariant()) }
    }
}
$mc = Get-ItemProperty -LiteralPath 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache' -ErrorAction SilentlyContinue
if ($mc) { foreach ($pr in $mc.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { Add-RunTrace (($pr.Name -split '\.FriendlyAppName')[0].TrimStart('@')) } } }
function Un13([string]$s) { $sb = New-Object System.Text.StringBuilder; foreach ($ch in $s.ToCharArray()) { $c = $ch; if ($c -ge 'A' -and $c -le 'Z') { $c = [char](([int][char]$c - 65 + 13) % 26 + 65) } elseif ($c -ge 'a' -and $c -le 'z') { $c = [char](([int][char]$c - 97 + 13) % 26 + 97) }; [void]$sb.Append($c) }; return $sb.ToString() }
# UserAssist: ROT13-имена значений лежат в подключе {GUID}\Count, а НЕ в самом {GUID}.
# Реальный кейс прогона 2026-10-03: чтение свойств {GUID} давало 8 служебных значений и 0 путей,
# тогда как в \Count на этой же машине 303+98 записей — сигнал был полностью мёртв.
$uaBase = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
foreach ($ua in (Get-ChildItem $uaBase -ErrorAction SilentlyContinue)) {
    $ck = Join-Path (Join-Path $uaBase $ua.PSChildName) 'Count'
    $c = Get-ItemProperty -LiteralPath $ck -ErrorAction SilentlyContinue   # -LiteralPath: в имени GUID есть {}
    if ($c) { foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { Add-RunTrace ((Un13 $pr.Name).TrimStart('@')) } } }
}
# Prefetch: имя вида APP.EXE-1A2B3C4D.pf → факт запуска (LastWriteTime ≈ когда).
$pfCount = 0
foreach ($pf in (Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Prefetch') -Filter '*.pf' -File -ErrorAction SilentlyContinue)) {
    $pfCount++
    $n = [IO.Path]::GetFileNameWithoutExtension($pf.Name)
    if ($n -match '^(.+)-[0-9A-F]{8}$') { [void]$runNames.Add($Matches[1].ToUpperInvariant()) }
}
L ('# Следов запуска: MuiCache+UserAssist\Count путей={0}; Prefetch файлов={1}{2}' -f $runPaths.Count, $pfCount, $(if ($pfCount -eq 0) { ' (сигнал недоступен — НЕ доказательство неиспользования)' } else { '' }))

# --- автозапуск/задачи (негативный фильтр: не кандидаты) ---
$autoTokens = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($rk in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
)) {
    $rp = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if ($rp) { foreach ($pr in $rp.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { $e = [IO.Path]::GetFileNameWithoutExtension((Get-ExePath ([string]$pr.Value))); if ($e) { [void]$autoTokens.Add(($e -replace '[^a-z0-9]','').ToUpperInvariant()) } } } }
}
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    foreach ($a in $t.Actions) { $e = [IO.Path]::GetFileNameWithoutExtension((Get-ExePath ([string]$a.Execute))); if ($e) { [void]$autoTokens.Add(($e -replace '[^a-z0-9]','').ToUpperInvariant()) } }
}
# Авто-службы: приложение, живущее ТОЛЬКО службой (типовой кейс «EaseUS UPDATE SERVICE»),
# иначе становилось ложным кандидатом «не используется».
foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName })) {
    $e = [IO.Path]::GetFileNameWithoutExtension((Get-ExePath ([string]$s.PathName)))
    if ($e) { [void]$autoTokens.Add(($e -replace '[^a-z0-9]','').ToUpperInvariant()) }
}
# Startup-папки (user + ProgramData) — имена .lnk/.url как токены автозапуска.
foreach ($sf in @((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
    if (-not (Test-Path -LiteralPath $sf)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $sf -File -Force -ErrorAction SilentlyContinue)) {
        $n = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($n) { [void]$autoTokens.Add(($n -replace '[^a-z0-9]','').ToUpperInvariant()) }
    }
}
$procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique | ForEach-Object { ($_ -replace '[^a-z0-9]','').ToUpperInvariant() })

# --- компоненты/рантаймы — не кандидаты ---
$skipRe = '(\.NET|Visual C\+\+|vcredist|XNA|ClickOnce|Launcher Prerequisites|UE4 Prerequisites|Microsoft Windows Desktop|Microsoft\.NET|Office 16|Update for x64|vcpp_crt|Visual C\+\+ Library|DiagnosticsHub|IntelliTrace|IIS|Microsoft Update Health|Web Deploy|NetStandard|Python Launcher|Java\(|Chocolatey|Go Programming|Node\.js|NVIDIA|AMD|Steam\b|Riot|Paradox|AMDAutoUpdate|WSL|LocalDB|SQL Server)'
$csv = Join-Path $Work 'installed.csv'
if (-not (Test-Path -LiteralPath $csv)) {
    # Без installed.csv молча выдалось бы «Кандидатов: 0» — неразличимо с «реально ничего нет».
    Write-Error ('нет installed.csv — сначала запусти inventory-quick.ps1 (' + $csv + ')')
    exit 2
}
$rows = Import-Csv -LiteralPath $csv -Encoding UTF8
$now = Get-Date

$cands = New-Object 'System.Collections.Generic.List[object]'
foreach ($r in $rows) {
    if ($r.LocExists -ne 'True') { continue }
    if ($r.Name -match $skipRe) { continue }
    $loc = ($r.Loc -replace '\\$','')
    if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { continue }
    $item = Get-Item -LiteralPath $loc -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) { continue }   # InstallLocation — файл, не каталог приложения
    # Общие корни (Program Files, ProgramData, корень тома, профиль) — НЕ локация приложения:
    # Get-SizeBytes по ним обходил бы весь диск на каждую запись реестра (десятки минут).
    if (Test-SharedRoot $loc) { continue }
    # Steam-игры/библиотеки — НЕ кандидаты: удаление только через клиент Steam, след запуска
    # недостоверен (игры через чужие лаунчеры не пишут MuiCache/UserAssist) — см. U4.
    if ($loc -match '\\Steam( Library)?\\steamapps\\|\\steamapps\\common\\') { continue }
    # ОДИН проход по дереву: сразу и размер, и первые 5 exe (раньше дерево обходилось дважды —
    # Get-SizeBytes, затем Get-ChildItem -Recurse -Filter '*.exe').
    $sz = 0L
    $exes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in (Get-ChildItem -LiteralPath $loc -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        try { $sz += [long]$f.Length } catch { continue }   # PathTooLong/UnauthorizedAccess — terminating
        if ($f.Extension -ieq '.exe' -and $exes.Count -lt 5) { $exes.Add($f.FullName) }
    }
    if ($sz -lt ($MinMB * 1MB)) { continue }
    $run = $false
    foreach ($e in $exes) {
        if ($runPaths.Contains($e.ToUpperInvariant())) { $run = $true; break }
        $bn = [IO.Path]::GetFileNameWithoutExtension($e)
        if ($bn -and $runNames.Contains($bn.ToUpperInvariant())) { $run = $true; break }
    }
    if ($run) { continue }
    # негативные фильтры: в автозапуске / процесс запущен -> совсем не кандидат
    $autoHit = $false
    foreach ($e in $exes) {
        $name = ([IO.Path]::GetFileNameWithoutExtension($e) -replace '[^a-z0-9]','').ToUpperInvariant()
        # Скобки обязательны: -and связывает сильнее -or, и без них при пустом $name проверялось
        # $procs -contains '' (ложное срабатывание негативного фильтра).
        if ($name -and ($autoTokens.Contains($name) -or ($procs -contains $name))) { $autoHit = $true; break }
    }
    if ($autoHit) { continue }
    $lst = $item.LastWriteTime   # Get-Item уже получен выше — без повторного обращения и без исключения
    if (($now - $lst).TotalDays -gt 180) {
        $cands.Add([pscustomobject]@{ Name=$r.Name; MB=[math]::Round($sz/1MB); LastWrite=$lst.ToString('yyyy-MM-dd'); AgeDays=[math]::Round(($now-$lst).TotalDays); Exe=($exes | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ',' })
    }
}
$cands | Sort-Object MB -Descending | ForEach-Object {
    L ("{0}`t{1} МБ`tпосл.запись {2} ({3} дн)  [КАНДИДАТ — решает пользователь]" -f $_.Name, $_.MB, $_.LastWrite, $_.AgeDays)
}
L ('# Кандидатов: {0}  (негативные фильтры: автозапуск Run/RunOnce + Startup-папки + задачи + авто-службы + процессы; CLI-тулы и игры через чужие лаунчеры могут не иметь следа — учитываться не будут автоматически)' -f $cands.Count)
Write-Output ("unused-hints: кандидатов=" + $cands.Count + "  =>  " + $out)
