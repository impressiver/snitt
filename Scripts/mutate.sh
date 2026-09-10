#!/bin/bash
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

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  filter="$(printf '%s' "$line" | awk -F ' *:: *' '{print $1}')"
  file="$(printf '%s' "$line" | awk -F ' *:: *' '{print $2}')"
  find="$(printf '%s' "$line" | awk -F ' *:: *' '{print $3}')"
  replace="$(printf '%s' "$line" | awk -F ' *:: *' '{print $4}')"

  if [ ! -f "$file" ]; then
    echo "SKIP  (no such file: $file)"
    continue
  fi
  total=$((total + 1))

  backup="$(mktemp)"
  cp "$file" "$backup"
  # Python rather than sed: the find/replace text is literal, and sed would
  # treat it as a regex.
  if ! FIND="$find" REPLACE="$replace" FILE="$file" python3 -c '
import os, sys
path, find, replace = os.environ["FILE"], os.environ["FIND"], os.environ["REPLACE"]
s = open(path).read()
if find not in s:
    sys.exit(3)
open(path, "w").write(s.replace(find, replace, 1))
'; then
    cp "$backup" "$file"; rm -f "$backup"
    echo "SKIP  anchor not found: ${find:0:50}"
    total=$((total - 1))
    continue
  fi

  log="$(mktemp)"
  swift test --filter "$filter" > "$log" 2>&1
  # A crashed bundle is a KILL, not a pass: `swift test` exits 0 on a
  # segfault and prints no summary, which is the trap Scripts/run-tests.sh
  # exists for.
  if grep -q "signal code\|Fatal error" "$log"; then
    echo "killed (crash)  ${find:0:60}"
  elif grep -q "Test run with .* passed" "$log"; then
    echo "SURVIVED        ${find:0:60}"
    survived=$((survived + 1))
  elif grep -q "Test run with .* failed" "$log"; then
    echo "killed          ${find:0:60}"
  else
    echo "SKIP  (build failed)  ${find:0:50}"
    total=$((total - 1))
  fi

  cp "$backup" "$file"
  rm -f "$backup" "$log"
done < "$spec"

echo
echo "$((total - survived))/$total mutants killed."
if [ "$survived" -gt 0 ]; then
  echo "Investigate every survivor: it is either missing coverage or dead code."
  exit 1
fi
