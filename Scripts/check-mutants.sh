#!/usr/bin/env bash
# Validates Tests/mutants.txt against the sources it points at.
#
# WHY THIS EXISTS. `Scripts/mutate.sh` prints `SKIP anchor not found` and
# carries on when a mutant's find-text is no longer in the file, and it
# subtracts that mutant from its own total — so the run still ends "N/N
# mutants killed" and the rot is invisible unless somebody reads the log.
# Twenty-four of them had gone that way before this check existed, against
# code that had been renamed, reworked or deleted underneath them. A mutant
# that cannot be applied is not a passing mutant; it is a test that silently
# stopped existing.
#
# Checked here rather than in a Swift test because it is pure text matching:
# it needs no compiler, so it runs in the Hygiene job on Ubuntu in seconds
# instead of behind a macOS build. It is also why `mutants.txt` entries for
# `Scripts/*.sh` are covered as well as Swift ones.
#
# NOT checked: whether the test filter names a suite that exists, which needs
# the test binary and so belongs with the build. A filter naming nothing runs
# zero tests and reports the mutant as survived, which is loud on its own.
set -uo pipefail
cd "$(dirname "$0")/.."

spec="${1:-Tests/mutants.txt}"
[ -f "$spec" ] || { echo "::error::no such spec file: $spec" >&2; exit 1; }

SPEC="$spec" python3 - <<'PY'
import os, re, sys

spec = os.environ["SPEC"]
problems = []
checked = 0
cache = {}

def contents(path):
    if path not in cache:
        try:
            cache[path] = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            cache[path] = None
    return cache[path]

for number, raw in enumerate(open(spec, encoding="utf-8"), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    fields = [f.strip() for f in line.split("::")]
    if len(fields) != 4:
        problems.append((number, f"expected 4 ::-separated fields, found {len(fields)}"))
        continue
    _filter, path, find, replace = fields
    checked += 1
    if not find:
        problems.append((number, "empty find text"))
        continue
    # An optional leading [n] picks which occurrence to mutate. Matched the
    # same way `mutate.sh` matches it, so the two cannot disagree about what
    # counts as a selector.
    wanted = None
    selector = re.match(r"^\[(\d+)\](.*)$", find, re.S)
    if selector:
        wanted, find = int(selector.group(1)), selector.group(2)
        if wanted < 1:
            problems.append((number, "occurrence selector must be 1 or greater"))
            continue
    if find == replace:
        # Applies cleanly, changes nothing, and is reported as killed or
        # survived on the strength of an unmodified tree either way.
        problems.append((number, "find and replace are identical, so the mutant is a no-op"))
        continue
    body = contents(path)
    if body is None:
        problems.append((number, f"no such file: {path}"))
        continue
    hits = body.count(find)
    if hits == 0:
        problems.append((number, f"anchor not found in {path}: {find[:60]}"))
    elif wanted is None and hits > 1:
        # `mutate.sh` replaces the FIRST occurrence when nothing says
        # otherwise, so the mutant may well be mutating a line nobody meant.
        problems.append((number,
                         f"anchor appears {hits}x in {path} and has no [n] selector "
                         f"saying which: {find[:46]}"))
    elif wanted is not None and wanted > hits:
        problems.append((number,
                         f"selector [{wanted}] but only {hits} match(es) in {path}"))

print(f"checked {checked} mutants in {spec}")
for number, message in problems:
    print(f"::error file={spec},line={number}::{message}")
if problems:
    print(f"{len(problems)} broken mutant(s). A mutant that cannot be applied tests nothing:")
    print("re-anchor it to the code that replaced it, or delete it and say why.")
    sys.exit(1)
print("every mutant anchors to exactly one place")
PY
