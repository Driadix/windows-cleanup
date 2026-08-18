#!/usr/bin/env python3
"""Static validation for the windows-cleanup skill (repo copy or deployed copy).

Checks:
  1. SKILL.md starts with --- and frontmatter parses as YAML.
  2. Required fields present: name, description, version, author, license, platforms.
  3. description rules: <= 60 chars, ends with '.', platforms includes 'windows'.
  4. Every references/*.md and scripts/*.ps1 mentioned in the SKILL.md body exists.
  5. Every scripts/*.ps1 parses (delegates to PowerShell Parser::ParseFile, if PowerShell is available).

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

    # References / scripts mentioned in the body must exist on disk
    if body:
        for ref in sorted(set(re.findall(r"references/[\w.\-]+\.md", body))):
            p = skill_dir / ref
            if not p.exists():
                errors.append(f"body references missing file: {ref}")
        for s in sorted(set(re.findall(r"scripts/[\w.\-]+\.ps1", body))):
            p = skill_dir / s
            if not p.exists():
                errors.append(f"body references missing script: {s}")
        print("  referenced files/scripts: all present" if not errors or all("missing file" not in e and "missing script" not in e for e in errors) else "")

    # PS syntax check on every shipped script
    scripts = sorted((skill_dir / "scripts").glob("*.ps1")) if (skill_dir / "scripts").exists() else []
    for s in scripts:
        ok, note = check_ps_syntax(s)
        print(f"  ps-syntax {s.name}: {note}")
        if not ok:
            errors.append(f"PS syntax error in {s.name}: {note}")

    if errors:
        print("\nFAILURES:")
        for e in errors:
            print("  -", e)
        return 1
    print("\nVALIDATE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
