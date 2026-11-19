#!/usr/bin/env python3
"""What unit coverage leaves out, kept in one place: codecov.yml's `ignore:`.

  check-coverage.py            check the rules below; exit 1 on a problem
  check-coverage.py --regex    print the llvm-cov `-ignore-filename-regex`
                               CI uses, generated from codecov.yml

Rules:
  1. Every `ignore:` entry still matches a file, so a stale line can't
     quietly hide a new one that reuses its path.
  2. A file in an `Internal/System/` folder (or a `System/` folder deeper
     inside `Internal/`) is at most MAX_LINES lines —
     the irreducible call to the outside world and nothing else. A file
     that needs more is deciding something, and that part is measured.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CODECOV = ROOT / "codecov.yml"
MAX_LINES = 100
# Build products and generated mocks never count, whatever codecov says.
ALWAYS = [r"\.build/", r"Mock"]


def ignored_globs():
    globs, inside = [], False
    for line in CODECOV.read_text().splitlines():
        if re.match(r"^ignore:\s*$", line):
            inside = True
            continue
        if inside:
            if re.match(r"^\S", line):
                break
            m = re.match(r'^\s*-\s*"([^"]+)"', line)
            if m:
                globs.append(m.group(1))
    return globs


def to_regex(glob: str) -> str:
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(.*/)?"
            i += 3
        elif glob.startswith("**", i):
            out += ".*"
            i += 2
        elif glob[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return out


def main() -> int:
    globs = ignored_globs()
    if "--regex" in sys.argv:
        print("|".join(ALWAYS + [to_regex(g) for g in globs]))
        return 0

    problems = []
    files = [p.relative_to(ROOT).as_posix() for p in ROOT.glob("Sources/**/*") if p.is_file()]
    files += [p.relative_to(ROOT).as_posix() for p in ROOT.glob("Tests/**/*") if p.is_file()]
    for glob in globs:
        pattern = re.compile("^" + to_regex(glob) + "$")
        if not any(pattern.match(f) for f in files):
            problems.append(f"codecov.yml: `{glob}` matches no file")

    for path in sorted(ROOT.glob("Sources/**/Internal/**/System/*.swift")):
        lines = len(path.read_text().splitlines())
        if lines > MAX_LINES:
            rel = path.relative_to(ROOT)
            problems.append(f"{rel}: {lines} lines; a System file holds only the call "
                            f"to the outside (≤ {MAX_LINES}) — split what it decides out")

    for line in problems:
        print(line)
    print(f"{len(problems)} coverage problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
