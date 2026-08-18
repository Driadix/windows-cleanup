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
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -eq 0) { Write-Output 'ALL SMOKE TESTS PASSED' }
else { Write-Output "$fail FAILED"; exit 1 }
