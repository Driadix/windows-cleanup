# Параметры
param(
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$true)][string[]]$Paths
)

# Удаление заблокированных файлов/папок ПРИ ПЕРЕЗАГРУЗКЕ через PendingFileRenameOperations.
# Использование (elevated): powershell.exe -NoProfile -ExecutionPolicy Bypass -File pending-delete.ps1 "C:\Program Files (x86)\EaseUS" "C:\path\file.dat"
# Требует прав администратора (через Start-Process -Verb RunAs -Wait из скилла).
# Запускать ТОЛЬКО как финал LOCKED-процедуры (ретрай → Stop-Process → это).

$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

# Проверка прав
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) { Write-Error 'Требуются права администратора'; exit 1 }

# PendingFileRenameOperations: пары "путь\??\..." + "" (пусто = удалить). REG_MULTI_SZ (7).
$existing = (Get-ItemProperty -Path $key -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
$list = [System.Collections.Generic.List[string]]::new()
if ($existing) { $list.AddRange($existing) }
$toAdd = [System.Collections.Generic.List[string]]::new()
foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Output "already gone: $p"; continue }
    $toAdd.Add("\??\" + (Get-Item -LiteralPath $p -Force).FullName)
    $toAdd.Add('')   # пустая вторая часть = удаление
}

# Защита от переполнения: значение читается smss при загрузке, практически потолок ~32 КБ.
# Разросшаяся/битая очередь может не примениться или сломать удаление при загрузке — поэтому
# при превышении консервативного лимита НЕ пишем вообще, а сообщаем (PATH-лимита у нас нет,
# но разумно не рисковать очередью ради пары файлов).
$curLen = 0L
foreach ($s in $list) { $curLen += [int]$s.Length + 1 }
$addLen = 0L
foreach ($s in $toAdd) { $addLen += [int]$s.Length + 1 }
$maxLen = 30000
if (($curLen + $addLen) -gt $maxLen) {
    Write-Error ("Очередь PendingFileRenameOperations почти полна: ~" + ($curLen + $addLen) + " символов при потолке ~" + $maxLen + ". НЕ записываю — заблокированные файлы удали вручную или после перезагрузки.")
    exit 2
}
$list.AddRange($toAdd)
Set-ItemProperty -Path $key -Name PendingFileRenameOperations -Value $list.ToArray() -Type MultiString
Write-Output "OK: запланировано удаление при перезагрузке: $($list.Count/2) объектов"
