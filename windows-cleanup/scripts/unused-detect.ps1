# unused-detect.ps1 — артефакт Фазы 2: `unused_hints.txt` (кандидаты «возможно не используется»).
# Только кандидаты — удаление НИКОГДА не выполняется, решает пользователь (ADR 0004).
# Сигналы (по отдельности слабые, вместе — надёжнее): MuiCache/UserAssist (запускалась ли вообще),
# дата LastWriteTime каталога установки, не в автозапуске, не запущен процесс.
# Оговорки (это уже зашито в фильтры, но помни): CLI-тулы и игры через чужие лаунчеры НЕ дают
# следа в MuiCache/UserAssist; Prefetch может быть выключен (0 файлов) — тогда сигнал недоступен.
# Использование: powershell.exe -NoProfile -ExecutionPolicy Bypass -File unused-detect.ps1 -Work "рабочая папка"
param([Parameter(Mandatory=$true)][string]$Work)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cleanup-common.ps1')
$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }
$out = Join-Path $Work 'unused_hints.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
function L([string]$m) { Add-Content -Path $out -Value $m -Encoding UTF8 }

# --- следы запуска (MuiCache + UserAssist, ROT13 для UserAssist) ---
$runPaths = New-Object 'System.Collections.Generic.HashSet[string]'
$mc = Get-ItemProperty 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
if ($mc) { foreach ($pr in $mc.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { $p = ($pr.Name -split '\.FriendlyAppName')[0].TrimStart('@'); if ($p -match '^[A-Za-z]:\\') { [void]$runPaths.Add($p.ToUpperInvariant()) } } } }
function Un13([string]$s) { $sb = New-Object System.Text.StringBuilder; foreach ($ch in $s.ToCharArray()) { $c = $ch; if ($c -ge 'A' -and $c -le 'Z') { $c = [char](([int][char]$c - 65 + 13) % 26 + 65) } elseif ($c -ge 'a' -and $c -le 'z') { $c = [char](([int][char]$c - 97 + 13) % 26 + 97) }; [void]$sb.Append($c) }; return $sb.ToString() }
foreach ($ua in (Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist' -ErrorAction SilentlyContinue)) {
    $c = Get-ItemProperty $ua.PSPath -ErrorAction SilentlyContinue
    if ($c) { foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { $d = (Un13 $pr.Name).TrimStart('@'); if ($d -match '^[A-Za-z]:\\') { [void]$runPaths.Add($d.ToUpperInvariant()) } } } }
}
L ('# Следов запуска (MuiCache+UserAssist): {0}' -f $runPaths.Count)

# --- автозапуск/задачи (негативный фильтр: не кандидаты) ---
$autoTokens = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($rk in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
    $rp = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
    if ($rp) { foreach ($pr in $rp.PSObject.Properties) { if ($pr.Name -notmatch '^PS') { $e = [IO.Path]::GetFileNameWithoutExtension((Get-ExePath ([string]$pr.Value))); if ($e) { [void]$autoTokens.Add(($e -replace '[^a-z0-9]','').ToUpperInvariant()) } } } }
}
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    foreach ($a in $t.Actions) { $e = [IO.Path]::GetFileNameWithoutExtension((Get-ExePath ([string]$a.Execute))); if ($e) { [void]$autoTokens.Add(($e -replace '[^a-z0-9]','').ToUpperInvariant()) } }
}
$procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique | ForEach-Object { ($_ -replace '[^a-z0-9]','').ToUpperInvariant() })

# --- компоненты/рантаймы — не кандидаты ---
$skipRe = '(\.NET|Visual C\+\+|vcredist|XNA|ClickOnce|Launcher Prerequisites|UE4 Prerequisites|Microsoft Windows Desktop|Microsoft\.NET|Office 16|Update for x64|vcpp_crt|Visual C\+\+ Library|DiagnosticsHub|IntelliTrace|IIS|Microsoft Update Health|Web Deploy|NetStandard|Python Launcher|Java\(|Chocolatey|Go Programming|Node\.js|NVIDIA|AMD|Steam\b|Riot|Paradox|AMDAutoUpdate|WSL|LocalDB|SQL Server)'
$rows = Import-Csv -LiteralPath (Join-Path $Work 'installed.csv') -Encoding UTF8
$now = Get-Date

$cands = @()
foreach ($r in $rows) {
    if ($r.LocExists -ne 'True') { continue }
    if ($r.Name -match $skipRe) { continue }
    $loc = ($r.Loc -replace '\\$','')
    if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { continue }
    # Steam-игры/библиотеки — НЕ кандидаты: удаление только через клиент Steam, след запуска
    # недостоверен (игры через чужие лаунчеры не пишут MuiCache/UserAssist) — см. U4.
    if ($loc -match '\\Steam( Library)?\\steamapps\\|\\steamapps\\common\\') { continue }
    $sz = Get-SizeBytes -Path $loc
    if ($sz -lt 50MB) { continue }
    $exes = @(Get-ChildItem -LiteralPath $loc -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 5 | Select-Object -ExpandProperty FullName)
    $run = $false
    foreach ($e in $exes) { $up = $e.ToUpperInvariant(); if ($runPaths.Contains($up)) { $run = $true; break } }
    if (-not $run) { foreach ($p in $runPaths) { foreach ($e in $exes) { $b = [IO.Path]::GetFileName($e).ToUpperInvariant(); if ($p.EndsWith('\' + $b)) { $run = $true; break } }; if ($run) { break } } }
    if ($run) { continue }
    # негативные фильтры: в автозапуске / процесс запущен -> совсем не кандидат
    $autoHit = $false
    foreach ($e in $exes) { $name = ([IO.Path]::GetFileNameWithoutExtension($e) -replace '[^a-z0-9]','').ToUpperInvariant(); if ($name -and $autoTokens.Contains($name) -or $procs -contains $name) { $autoHit = $true; break } }
    if ($autoHit) { continue }
    $lst = (Get-Item -LiteralPath $loc -Force).LastWriteTime
    if (($now - $lst).TotalDays -gt 180) {
        $cands += [pscustomobject]@{ Name=$r.Name; MB=[math]::Round($sz/1MB); LastWrite=$lst.ToString('yyyy-MM-dd'); AgeDays=[math]::Round(($now-$lst).TotalDays); Exe=($exes | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ',' }
    }
}
$cands | Sort-Object MB -Descending | ForEach-Object {
    L ("{0}`t{1} МБ`tпосл.запись {2} ({3} дн)  [КАНДИДАТ — решает пользователь]" -f $_.Name, $_.MB, $_.LastWrite, $_.AgeDays)
}
L ('# Кандидатов: {0}  (негативные фильтры: автозапуск/задачи/процессы; CLI-тулы и игры через чужие лаунчеры могут не иметь следа — учитываться не будут автоматически)' -f $cands.Count)
Write-Output ("unused-hints: кандидатов=" + $cands.Count + "  =>  " + $out)
