#!/bin/bash
#
# The full local test gate.
#
# Two things this does that a bare `swift test` does not.
#
# 1. It SPLITS the run. `SnittExportTests` costs 8.4s on its own, but adds ~34s
#    when run alongside `SnittAppTests` — both are the AVFoundation-heavy
#    targets and they contend. Measured 2026-09-09: one invocation 88.5s, two
#    invocations 66s, identical 1151 tests. Adding the other five targets to
#    the app pass is free (they parallelise perfectly), so the split is exactly
#    one cut, not a general partitioning.
#
# 2. It CHECKS THE SUMMARY LINE. `swift test` exits 0 when the test bundle
#    segfaults — it prints an inline "signal code" and no summary, and the
#    shell sees success. Only the "Test run with N tests ... passed" line is
#    trustworthy, so this greps for it and fails when it is missing. That trap
#    has bitten this project before and a green exit status is exactly how.
# 3. It does NOT run the mutation pass. `Scripts/mutate.sh Tests/mutants.txt`
#    is a separate, slower gate for a different question: this script asks
#    "does anything fail", mutation asks "would anything fail if the code
#    were wrong". Roughly half the survivors found in this project were dead
#    code rather than missing tests, and neither shows up in a green run.
#    Run it before merging a change to geometry, hit-testing or wording.
#
set -euo pipefail

cd "$(dirname "$0")/.."

FAST='SnittDocumentTests|SnittCaptureTests|SnittAutomationTests|SnittCLITests|SnittMCPTests'
LOG_DIR="${TMPDIR:-/tmp}/snitt-test-logs"
mkdir -p "$LOG_DIR"

failed=0
counted=0

run_pass() {
  local name="$1" filter="$2" log="$LOG_DIR/$1.log"

  printf '\n=== %s ===\n' "$name"
  # `|| true`: a non-zero exit is reported through the summary check below, so
  # `set -e` must not abort before the log is inspected. The exit status is the
  # thing we do not trust; the log is.
  swift test --filter "$filter" > "$log" 2>&1 || true

  local summary
  summary="$(grep -E 'Test run with .* (passed|failed)' "$log" | tail -1 || true)"

  if [ -z "$summary" ]; then
    echo "FAILED: no summary line — the bundle probably crashed. Last 20 lines:"
    tail -20 "$log"
    grep -n 'signal code' "$log" | head -3 || true
    failed=1
    return
  fi

  echo "$summary"

  # Accumulate what actually RAN. A filter that matches nothing reports
  # "Test run with 0 tests ... passed" — green, having tested nothing — so a
  # typo in one of these filters would silently skip a whole target. The
  # reconciliation after both passes is what catches that.
  local ran
  ran="$(printf '%s' "$summary" | sed -E 's/.*with ([0-9]+) tests.*/\1/')"
  counted=$(( counted + ran ))

  case "$summary" in
    *passed*) ;;
    *) echo "  see $log"; grep -E '^✘ Test "' "$log" | head -10; failed=1 ;;
  esac
}

run_pass "app-and-fast-targets" "SnittAppTests|$FAST"
run_pass "export" "SnittExportTests"

# Every test in the package must have run in exactly one pass. This is what
# makes the split safe to change: add a target, mistype a filter, or drop one
# from the list, and the totals stop reconciling instead of quietly shrinking
# the gate.
expected="$(swift test --list-tests 2>/dev/null | grep -c . || echo 0)"
printf '\n%s of %s tests ran across both passes\n' "$counted" "$expected"
if [ "$expected" -eq 0 ] || [ "$counted" -ne "$expected" ]; then
  echo "MISMATCH: the two filters do not cover the package exactly — fix them, do not adjust this check."
  failed=1
fi

printf '\n'
if [ "$failed" -ne 0 ]; then
  echo "TEST GATE: FAILED"
  exit 1
fi
echo "TEST GATE: PASSED"
