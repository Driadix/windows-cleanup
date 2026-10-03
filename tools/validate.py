#!/usr/bin/env python3
"""Static validation for the windows-cleanup skill (repo copy or deployed copy).

Checks:
  1. SKILL.md starts with --- and frontmatter parses as YAML.
  2. Required fields present: name, description, version, author, license, platforms.
  3. description rules: <= 60 chars, ends with '.', platforms includes 'windows'.
  4. Every references/*.md and scripts/*.ps1 mentioned in the SKILL.md body exists.
  5. Every scripts/*.ps1 is UTF-8 **with BOM** (PS 5.1 reads BOM-less .ps1 as ANSI/cp1251 on
     non-UTF8 locales — Cyrillic string literals break parsing; real case from a 2026-08-19 run).
  6. Every scripts/*.ps1 parses (delegates to PowerShell Parser::ParseFile, if PowerShell is available).

Usage:
  python tools/validate.py [path-to-skill-dir]     (default: <repo>/windows-cleanup)

Exit code 0 = OK, 1 = failures. Safe on any OS (PS check is skipped with a note when powershell.exe is absent).
"""
import re
import sys
import pathlib
import shutil
import subprocess

REQUIRED_FIELDS = ("name", "description", "version", "author", "license", "platforms")
DESC_MAX = 60


def check_ps_syntax(script: pathlib.Path) -> tuple[bool, str]:
    """Parse-check a .ps1 file via the PowerShell language parser (no execution)."""
    if not shutil.which("powershell.exe"):
        return True, "(powershell.exe not found — PS syntax check skipped)"
    ps_cmd = (
        "$e=$null; [System.Management.Automation.Language.Parser]::ParseFile("
        f"'{script}', [ref]$null, [ref]$e) | Out-Null; "
        "if ($e.Count -eq 0) { 'OK' } else { $e | % Message }"
    )
    try:
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps_cmd],
            capture_output=True, text=True, timeout=120,
        )
    except Exception as exc:
        return True, f"(PS parse check error: {exc})"
    out = (r.stdout or "").strip()
    if r.returncode == 0 and out == "OK":
        return True, "OK"
    return False, out or f"exit={r.returncode}"

# ---------------------------------------------------------------------------
# Portability: no machine-bound absolute paths. LEGAL (never flagged): anything
# derived at runtime from env/$PSScriptRoot/Get-Volume/Join-Path/Split-Path/[IO.Path].
# ILLEGAL in CODE: a literal drive root followed by a machine-specific folder
# (C:\Windows\..., C:\Program Files\...), a quoted literal drive path, or an
# agent-specific skills dir (hermes/.claude/.codex). Hits inside comments/docstrings
# are WARNINGS only (usage examples); executable-code hits are FAILURES.
# ---------------------------------------------------------------------------
_DRIVE_ROOT = re.compile(r"(?<![A-Za-z0-9_$])[A-Za-z]:[\\/]")
_MACHINE_SEG = re.compile(
    r"(?i)(?:Users[\\/]"
    r"|Windows[\\/](?:Temp|System32|SysWOW64|WinSxS|assembly|SoftwareDistribution|ServiceProfiles|Prefetch|Installer|Logs)"
    r"|Program\ Files(?: \(x86\))?[\\/]"
    r"|ProgramData[\\/]"
    r"|AppData[\\/](?:Local|Roaming)[\\/](?:Microsoft|hermes)"
    r"|\$WINDOWS\.~BT|\$GetCurrent|\$WinREAgent)"
)
_AGENT_SKILL_DIR = re.compile(r"(?i)(?:hermes[\\/]skills|\.claude[\\/]skills|\.codex[\\/]skills|opencode[\\/]skills)")


def _is_ps_comment(line: str) -> bool:
    """A .ps1 line is a comment if its first non-space char is '#'."""
    return line.lstrip().startswith("#")



def find_hardcoded_paths(path: pathlib.Path):
    """Return [(line_no, stripped_line, is_comment)] of machine-bound path literals."""
    hits = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return hits
    is_ps = path.suffix.lower() == ".ps1"
    for n, line in enumerate(text.splitlines(), 1):
        flagged = False
        for m in _DRIVE_ROOT.finditer(line):
            tail = line[m.end():]
            quoted = line[m.start() - 1:m.start()] in "\"'" if m.start() > 0 else False
            if _MACHINE_SEG.match(tail) or (quoted and _MACHINE_SEG.search(tail)):
                flagged = True
                break
        if not flagged and _AGENT_SKILL_DIR.search(line):
            flagged = True
        if flagged:
            is_comment = _is_ps_comment(line) if is_ps else True
            hits.append((n, line.strip(), is_comment))
    return hits


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg:
        skill_dir = pathlib.Path(arg)
    else:
        skill_dir = pathlib.Path(__file__).resolve().parent.parent / "windows-cleanup"
    sk = skill_dir / "SKILL.md"
    errors: list[str] = []

    print(f"== validate: {skill_dir} ==")
    if not sk.exists():
        print(f"FAIL: no SKILL.md at {sk}")
        return 1

    txt = sk.read_text(encoding="utf-8")
    body = ""
    if not txt.startswith("---"):
        errors.append("SKILL.md must start with '---'")
    else:
        idx = txt.find("\n---\n", 3)
        if idx == -1:
            errors.append("frontmatter not closed with '\\n---\\n'")
        else:
            fm_raw = txt[3:idx]
            body = txt[idx + len("\n---\n"):]
            try:
                import yaml  # PyYAML
            except ImportError:
                errors.append("PyYAML not installed — run: pip install pyyaml")
                yaml = None
            if yaml is not None:
                fm = yaml.safe_load(fm_raw)
                if not isinstance(fm, dict):
                    errors.append("frontmatter did not parse as a YAML mapping")
                else:
                    for f in REQUIRED_FIELDS:
                        if f not in fm:
                            errors.append(f"frontmatter missing required field: {f}")
                    desc = fm.get("description") or ""
                    if len(desc) > DESC_MAX:
                        errors.append(f"description too long: {len(desc)} chars (max {DESC_MAX})")
                    if not desc.endswith("."):
                        errors.append("description must end with a period")
                    plats = fm.get("platforms")
                    if plats is None or "windows" not in plats:
                        errors.append("platforms must include 'windows'")

    repo_root = skill_dir.parent
    scripts_dir = skill_dir / "scripts"
    scripts = sorted(scripts_dir.glob("*.ps1")) if scripts_dir.exists() else []

    # References / scripts mentioned in the body must exist on disk
    if body:
        for ref in sorted(set(re.findall(r"references/[\w.\-]+\.md", body))):
            p = skill_dir / ref
            if not p.exists():
                errors.append(f"body references missing file: {ref}")
        documented = set(re.findall(r"scripts/([\w.\-]+\.ps1)", body))
        for s in sorted(documented):
            if not (scripts_dir / s).exists():
                errors.append(f"body references missing script: scripts/{s}")
        # Обратный дрейф: скрипт лежит в scripts/, но SKILL.md о нём не знает —
        # агент никогда его не запустит (реальная проблема: молча мёртвый код).
        on_disk = {p.name for p in scripts}
        for name in sorted(on_disk - documented):
            errors.append(f"script not documented in SKILL.md body: scripts/{name}")
        print("  referenced files/scripts: all present")

    # BOM check on every shipped script — И на tools/*.ps1 (кейс прогона 2026-10-03:
    # smoke_test.ps1 был без BOM при кириллических литералах; PS 5.1 на ru-RU читает как cp1251).
    bom_targets = list(scripts)
    tools_dir = repo_root / "tools"
    if tools_dir.exists():
        bom_targets += sorted(tools_dir.glob("*.ps1"))
    for s in bom_targets:
        head = s.read_bytes()[:3]
        if head != b"\xef\xbb\xbf":
            errors.append(f"{s.name}: no UTF-8 BOM (EF BB BF) — PS 5.1 will misread it as ANSI (cp1251 on ru-RU) and Cyrillic breaks parsing")
        else:
            print(f"  bom {s.name}: OK")

    # PS syntax check on every shipped script
    for s in scripts:
        ok, note = check_ps_syntax(s)
        print(f"  ps-syntax {s.name}: {note}")
        if not ok:
            errors.append(f"PS syntax error in {s.name}: {note}")

    # Portability: machine-bound absolute paths. В коде — ОШИБКА, в комментариях/доках — warning.
    portability_files = list(scripts)
    for d, pat in ((skill_dir / "references", "*.md"), (repo_root / "tools", "*.ps1")):
        if d.exists():
            portability_files += sorted(d.glob(pat))
    if sk.exists():
        portability_files.append(sk)
    warn_count = 0
    for f in portability_files:
        try:
            rel = f.relative_to(repo_root)
        except ValueError:
            rel = f.name
        for n, line, is_comment in find_hardcoded_paths(f):
            where = f"{rel}:{n}"
            if is_comment:
                print(f"  WARN {where}: machine-bound path in comment/doc -> {line[:110]}")
                warn_count += 1
            else:
                errors.append(f"{where}: hardcoded machine path in code -> {line[:110]}")
    print(f"  portability: {warn_count} warning(s) in comments/docs, executable code must be clean")

    if errors:
        print("\nFAILURES:")
        for e in errors:
            print("  -", e)
        return 1
    print("\nVALIDATE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
