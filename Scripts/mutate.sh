#!/usr/bin/env bash
# Runs a mutation pass: applies each mutant in a spec file, runs a test
# filter, and reports which mutants SURVIVED.
#
# A surviving mutant means one of two things, and both are worth knowing:
# the tests do not cover that behaviour, or the code is dead. Roughly half
# the survivors found in this project were the second — defensive guards
# whose stated justification turned out to be false, and branches that could
# never execute. Neither is visible to a green test run.
#
# Usage:  Scripts/mutate.sh <spec-file>
#
# A spec file is one mutant per line:
#   <test-filter> :: <file> :: <find> :: <replace>
# Blank lines and lines starting with # are ignored. `::` separates fields,
# so none of them may contain it.
#
# <find> may begin with an occurrence selector, `[2]` for the second match
# and so on, when the text it anchors to is not unique in the file. Without
# one the FIRST match is replaced, which is silently the wrong line whenever
# the anchor repeats — eleven identical `guard policy().allowsAgentAccess`
# lines in AutomationHost.swift are why this exists. `Scripts/check-mutants.sh`
# rejects a repeated anchor that carries no selector, and a selector that
# points past the last match.
set -uo pipefail
cd "$(dirname "$0")/.."

spec="${1:-}"
if [ -z "$spec" ] || [ ! -f "$spec" ]; then
  echo "usage: $(basename "$0") <spec-file>" >&2
  echo "  each line: <test-filter> :: <file> :: <find> :: <replace>" >&2
  exit 1
fi

survived=0
total=0
# Counted and reported, never quietly subtracted. A mutant that could not be
# applied or did not compile tests exactly as much as one that was never
# written, and the old code decremented `total` for both — so a run with a
# dead mutant in it still printed "N of N killed" and looked perfect.
skipped=0

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  filter="$(printf '%s' "$line" | awk -F ' *:: *' '{print $1}')"
  file="$(printf '%s' "$line" | awk -F ' *:: *' '{print $2}')"
  find="$(printf '%s' "$line" | awk -F ' *:: *' '{print $3}')"
  replace="$(printf '%s' "$line" | awk -F ' *:: *' '{print $4}')"

  if [ ! -f "$file" ]; then
    echo "SKIP  (no such file: $file)"
    skipped=$((skipped + 1))
    continue
  fi
  total=$((total + 1))

  backup="$(mktemp)"
  cp "$file" "$backup"
  # Python rather than sed: the find/replace text is literal, and sed would
  # treat it as a regex.
  if ! FIND="$find" REPLACE="$replace" FILE="$file" python3 -c '
import os, re, sys
path, find, replace = os.environ["FILE"], os.environ["FIND"], os.environ["REPLACE"]
# An optional leading [n] selects WHICH match to replace. Matched strictly so
# a find that legitimately opens with a bracket — a Swift array literal, say —
# is not mistaken for a selector.
which = 1
m = re.match(r"^\[(\d+)\](.*)$", find, re.S)
if m:
    which, find = int(m.group(1)), m.group(2)
s = open(path).read()
if s.count(find) < which or which < 1:
    sys.exit(3)
# Walk to the nth occurrence, then splice.
index = -1
for _ in range(which):
    index = s.find(find, index + 1)
open(path, "w").write(s[:index] + replace + s[index + len(find):])
'; then
    cp "$backup" "$file"; rm -f "$backup"
    echo "SKIP  anchor not found: ${find:0:50}"
    skipped=$((skipped + 1))
    total=$((total - 1))
    continue
  fi

  log="$(mktemp)"
  swift test --filter "$filter" > "$log" 2>&1
  # The LAST summary line, matched with its leading marker — not the first
  # thing in the log that looks like one.
  #
  # `grep -q "Test run with .* passed"` used to decide this, and it reported a
  # mutant SURVIVED that the tests had killed. A failing expectation prints its
  # receiver, the receiver was the whole of CONTRIBUTING.md, and that file
  # contains the sentence "Only the `Test run with N tests ... passed` line is
  # trustworthy" — the project's own warning about this exact trap, echoed into
  # a failure message, springing the trap it describes.
  #
  # Anything a test prints can contain anything. The marker and the tail are
  # what make this a summary rather than a substring: `run-tests.sh` already
  # took the last match for the same reason.
  summary="$(grep -E '^[✔✘] Test run with .* (passed|failed)' "$log" | tail -1 || true)"
  # A crashed bundle is a KILL, not a pass: `swift test` exits 0 on a
  # segfault and prints no summary, which is the trap Scripts/run-tests.sh
  # exists for.
  if grep -q "signal code\|Fatal error" "$log"; then
    echo "killed (crash)  ${find:0:60}"
  elif [ -z "$summary" ]; then
    # Almost always a replacement that does not type-check — `selector: nil`
    # against a non-optional `Selector`, say. The mutant is invalid, not the
    # code, and it must not pass for a kill.
    echo "SKIP  (build failed)  ${find:0:50}"
    skipped=$((skipped + 1))
    total=$((total - 1))
  elif [[ "$summary" == *failed* ]]; then
    echo "killed          ${find:0:60}"
  else
    echo "SURVIVED        ${find:0:60}"
    survived=$((survived + 1))
  fi

  cp "$backup" "$file"
  rm -f "$backup" "$log"
done < "$spec"

echo
echo "$((total - survived))/$total mutants killed."
if [ "$skipped" -gt 0 ]; then
  echo "$skipped mutant(s) SKIPPED and not counted above. A skipped mutant is"
  echo "not a passing one: re-anchor it, or fix a replacement that will not"
  echo "compile. Scripts/check-mutants.sh catches the anchor kind before CI."
fi
if [ "$survived" -gt 0 ]; then
  echo "Investigate every survivor: it is either missing coverage or dead code."
fi
if [ "$survived" -gt 0 ] || [ "$skipped" -gt 0 ]; then
  exit 1
fi
