# Smoke tests for windows-cleanup helper scripts (offline, no desktop needed).
# Uses fixtures to exercise semantic behavior: .url web links, {::}-CLSID targets,
# empty-target shortcuts, decoy non-shortcut files, duplicate detection.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\smoke_test.ps1 [-SkillDir <dir>]
# Exit code 0 = all PASS, 1 = at least one FAIL.

param(
    [string]$SkillDir = ""
)

$ErrorActionPreference = 'Stop'
if (-not $SkillDir) { $SkillDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-cleanup' }
$scanScript = Join-Path $SkillDir 'scripts\scan.ps1'
$shcScript  = Join-Path $SkillDir 'scripts\shortcuts.ps1'
if (-not (Test-Path -LiteralPath $scanScript) -or -not (Test-Path -LiteralPath $shcScript)) {
    Write-Error "scripts not found under $SkillDir"; exit 1
}

$fail = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { Write-Output "PASS  $msg" }
    else       { Write-Output "FAIL  $msg"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wc_smoke_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Write-Output "== smoke fixtures in $tmp =="

try {
    # ---------- scan.ps1 fixture ----------
    $tree = Join-Path $tmp 'tree'
    New-Item -ItemType Directory -Path "$tree\bigfold\inner", "$tree\emptyfold" -Force | Out-Null
    # Три одинаковых по (Length,Name) файла -> кандидаты в дубли (порог -MinDupBytes 1 КБ)
    'AAAA' * 300 | Set-Content -Path "$tree\bigfold\dupe.bin"  -Encoding UTF8   # ~1200 байт
    'AAAA' * 300 | Set-Content -Path "$tree\bigfold\inner\dupe.bin" -Encoding UTF8
    'BBBB' * 100 | Set-Content -Path "$tree\single.bin" -Encoding UTF8
    'not a shortcut' | Set-Content -Path "$tree\bigfold\decoy.exe" -Encoding UTF8

    $scanOut = Join-Path $tmp 'scanout'
    $r = & $scanScript -Root $tree -OutDir $scanOut -Top 5 -MinDupBytes 1024 2>&1
    $scanOk = $LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq $null
    foreach ($f in 'dirs_top.txt','files_top.txt','dupes.txt') {
        Assert (Test-Path -LiteralPath (Join-Path $scanOut $f)) "scan: report $f written"
    }
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut 'dirs_top.txt') -Raw) -match 'bigfold') "scan: dirs_top contains bigfold"
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut 'files_top.txt') -Raw) -match 'dupe\.bin') "scan: files_top contains dupe.bin"
    $dupeLines = @(Get-Content -LiteralPath (Join-Path $scanOut 'dupes.txt') | Where-Object { $_.Trim() })
    Assert ($dupeLines.Count -ge 2) "scan: dupes.txt lists dupe.bin candidates (got $($dupeLines.Count))"

    # ---------- shortcuts.ps1 fixture ----------
    $fdir = Join-Path $tmp 'links'
    New-Item -ItemType Directory -Path $fdir -Force | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $realExe = "$env:SystemRoot\System32\notepad.exe"

    # .lnk, цель не существует -> БИТАЯ
    $s = $sh.CreateShortcut((Join-Path $fdir 'broken.lnk')); $s.TargetPath = 'C:\No\Such\Path\gone.exe'; $s.Save()
    # .lnk, живая цель -> ЖИВАЯ
    $s = $sh.CreateShortcut((Join-Path $fdir 'alive.lnk')); $s.TargetPath = $realExe; $s.Save()
    # .lnk, пустая цель (как shell-объект «Этот компьютер») -> НЕ битая
    $s = $sh.CreateShortcut((Join-Path $fdir 'empty.lnk')); $s.Save()
    # .lnk, цель {::CLSID} -> НЕ битая
    $s = $sh.CreateShortcut((Join-Path $fdir 'clsid.lnk')); $s.TargetPath = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'; $s.Save()
    # .url с URL -> ЖИВАЯ
    "[InternetShortcut]`r`nURL=https://example.com`r`n" | Set-Content -Path (Join-Path $fdir 'web.url') -Encoding UTF8
    # .url без URL -> БИТАЯ
    "[InternetShortcut]`r`n" | Set-Content -Path (Join-Path $fdir 'broken.url') -Encoding UTF8
    # Сторонний exe в каталоге — не должен попасть в отчёт
    'decoy' | Set-Content -Path (Join-Path $fdir 'decoy.exe') -Encoding UTF8

    $shcOut = Join-Path $tmp 'shcout'
    $r2 = & $shcScript -OutDir $shcOut -Places @($fdir) 2>&1
    $report = Join-Path $shcOut 'broken_shortcuts.txt'
    Assert (Test-Path -LiteralPath $report) 'shortcuts: report written'
    $txt = Get-Content -LiteralPath $report -Raw
    Assert ($txt -match 'broken\.lnk')  'shortcuts: broken.lnk (missing target) detected'
    Assert ($txt -match 'broken\.url')  'shortcuts: broken.url (no URL) detected'
    Assert ($txt -notmatch 'alive\.lnk') 'shortcuts: alive.lnk NOT flagged (existing target)'
    Assert ($txt -notmatch 'empty\.lnk') 'shortcuts: empty-target .lnk NOT flagged (shell object semantics)'
    Assert ($txt -notmatch 'clsid\.lnk') 'shortcuts: {::}-CLSID .lnk NOT flagged'
    Assert ($txt -notmatch 'web\.url')   'shortcuts: .url with URL=https:// NOT flagged'
    Assert ($txt -notmatch 'decoy\.exe') 'shortcuts: non-shortcut decoy.exe NOT in report'
    $brokenCount = @($txt -split "`r?`n" | Where-Object { $_ -match '\.(lnk|url)' }).Count
    Assert ($brokenCount -eq 2) "shortcuts: exactly 2 broken reported (got $brokenCount)"

    # ---------- scan: forward-slash root; маркер "(пусто)" для дублей; самоключение OutDir ----------
    $tree2 = Join-Path $tmp 'tree2'
    New-Item -ItemType Directory -Path "$tree2\only" -Force | Out-Null
    'X' * 100 | Set-Content -Path "$tree2\only\small.txt" -Encoding UTF8     # << порога 1024 КБ
    $scanOut2 = Join-Path $tmp 'scanout2'
    & $scanScript -Root ($tree2.Replace('\','/')) -OutDir $scanOut2 -MinDupBytes 1024 | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $scanOut2 'dupes.txt')) 'scan2: dupes.txt always created'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut2 'dupes.txt') -Raw) -match '\(пусто') 'scan2: empty dupes -> "(пусто)" marker'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut2 'dirs_top.txt') -Raw) -match 'only') 'scan2: forward-slash root normalized (dir "only" found)'

    $tree3 = Join-Path $tmp 'tree3'
    New-Item -ItemType Directory -Path "$tree3\inner" -Force | Out-Null
    'Y' * 2000 | Set-Content -Path "$tree3\inner\data.bin" -Encoding UTF8
    $scanOut3 = Join-Path $tree3 'scanout'
    & $scanScript -Root $tree3 -OutDir $scanOut3 -MinDupBytes 1024 | Out-Null   # 1-й проход пишет отчёты внутрь tree3
    & $scanScript -Root $tree3 -OutDir $scanOut3 -MinDupBytes 1024 | Out-Null   # 2-й проход (не должен считать свои отчёты)
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut3 'files_top.txt') -Raw) -notmatch 'scanout') 'scan3: self-reports (OutDir) excluded from files_top'
    Assert ((Get-Content -LiteralPath (Join-Path $scanOut3 'dirs_top.txt') -Raw) -notmatch 'scanout') 'scan3: OutDir excluded from dirs_top'

    # ---------- cleanup-common: статусы удаления + лидгер ----------
    . (Join-Path $SkillDir 'scripts\cleanup-common.ps1')
    $croot = Join-Path $tmp 'common'
    New-Item -ItemType Directory -Path "$croot\sub" -Force | Out-Null
    'Z' * 5000 | Set-Content -Path "$croot\sub\file.bin" -Encoding UTF8
    $r1 = Remove-Target -Path "$croot\sub\file.bin"
    Assert ($r1.Status -eq 'removed' -and $r1.RemovedBytes -ge 5000) 'common: Remove-Target (file) -> removed'
    $r2 = Remove-Target -Path "$croot\missing\gone"
    Assert ($r2.Status -eq 'already gone') 'common: Remove-Target (missing) -> already gone'
    $r3 = Remove-Contents -Path $croot
    Assert ($r3.Status -eq 'done' -and $r3.RemovedBytes -ge 0) 'common: Remove-Contents -> done'
    $led = Join-Path $tmp 'ledger.csv'
    Init-Ledger -Work $tmp -Name 'ledger.csv' | Out-Null
    Write-Ledger -Path $led -Phase 'test' -Object 'объект' -TargetPath 'C:\x' -SizeBeforeMB 1 -SizeAfterMB 0 -Status 'removed' -RemovedMB 1
    $ledRows = @(Import-Csv -LiteralPath $led)
    $testRows = @($ledRows | Where-Object { $_.phase -eq 'test' })
    Assert ($testRows.Count -eq 1) 'common: Write-Ledger appended a row'
    Assert ($testRows[0].removed_mb -eq '1') 'common: Write-Ledger (removed_mb=1) correct'
    # Get-ExePath: двойные backslash'и в PathName + голое имя + кавычки
    $exe1 = Get-ExePath 'C:\\Program Files\\AmneziaVPN\\amneziavpn-service.exe -x'
    Assert ($exe1 -eq 'C:\Program Files\AmneziaVPN\amneziavpn-service.exe') 'common: Get-ExePath collapses double backslashes'
    $exe2 = Get-ExePath 'powershell.exe -NoProfile -Command x'
    Assert ($exe2 -eq 'powershell.exe') 'common: Get-ExePath handles bare exe name'
    $exe3 = Get-ExePath '"C:\Program Files\X\y.exe" --flag'
    Assert ($exe3 -eq 'C:\Program Files\X\y.exe') 'common: Get-ExePath handles quoted path'
    $exe4 = Get-ExePath 'C:\Program Files\X\y.exe --flag'
    Assert ($exe4 -eq 'C:\Program Files\X\y.exe') 'common: Get-ExePath handles unquoted space path (with args)'
    $exe5 = Get-ExePath 'C:\Program Files\AmneziaVPN\AmneziaVPN-service.exe'
    Assert ($exe5 -eq 'C:\Program Files\AmneziaVPN\AmneziaVPN-service.exe') 'common: Get-ExePath handles unquoted space path (no args)'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Output 'ALL SMOKE TESTS PASSED' }
else { Write-Output "$fail FAILED"; exit 1 }
