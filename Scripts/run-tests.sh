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

# WARNINGS ARE ERRORS, the way CI builds.
#
# The gate and CI used to build with different strictness, so a deprecation
# was a note here and a build failure there — and on the day Actions came back
# after a billing block it failed three times in a row while this script passed
# throughout. Two of those were deprecations only the newer toolchain flags;
# one was a real concurrency violation that had been on `main` for weeks
# because CI never compiled the commit that introduced it.
#
# SOURCES AND TESTS, which is more than CI's own step covers.
#
# It took two wrong answers to get here, both recorded because the next person
# will meet the same wall. Swift propagates a deprecated callee's annotation to
# every caller, and `ShareMenu.services()` carries a deliberate one — the
# modern picker needs the finished export before the menu can open, which is
# the ten-second wait that design removes. Annotating the callers works until
# it reaches the tests, where swift-testing REFUSES `@Suite` on a deprecated
# type. From that single failure this was declared impossible.
#
# It is not: `@available` is accepted on an individual `@Test`, the warning
# goes, and the test still runs. The suite is the one place it cannot go.
#
# So the whole package builds warning-free and the gate checks all of it.
# Measure with a FORCED rebuild if you ever doubt that — an incremental build
# recompiles nothing and reports nothing, which is how a stale count survives
# in a comment, and how this one was twice confirmed wrong.
#
# Run FIRST, and fatal. `swift test` rebuilds without this flag, so a warning
# here would otherwise be discovered after two thousand tests had run and
# passed.
printf '\n=== build (warnings are errors) ===\n'
if swift build --build-tests -Xswiftc -warnings-as-errors > "$LOG_DIR/build.log" 2>&1; then
  echo "clean"
else
  echo "FAILED: the package does not build warning-free"
  grep -E 'error:' "$LOG_DIR/build.log" | head -20
  echo "  see $LOG_DIR/build.log"
  echo
  echo "TEST GATE: FAILED"
  exit 1
fi

run_pass() {
  local name="$1" filter="$2" log="$LOG_DIR/$1.log"

  printf '\n=== %s ===\n' "$name"
  # `|| true`: a non-zero exit is reported through the summary check below, so
  # `set -e` must not abort before the log is inspected. The exit status is the
  # thing we do not trust; the log is.
  swift test --filter "$filter" > "$log" 2>&1 || true

  # EVERY summary line, not the last one.
  #
  # Swift 6.4 (Xcode 27) prints one summary PER TARGET where earlier
  # toolchains printed one for the whole invocation. `tail -1` therefore
  # started reading a single target's result as the pass's result, and it
  # broke this script in both directions at once:
  #
  #   - the count shrank to the last target's, so the reconciliation below
  #     reported 1291 of 2002 and looked like 711 missing tests;
  #   - and the pass/fail check only saw the last target, so a pass whose
  #     FIRST five targets failed would have reported green as long as the
  #     last one passed. That is the silent-green this whole script exists
  #     to prevent, arriving by a route it did not know about.
  local summary
  summary="$(grep -E 'Test run with .* (passed|failed)' "$log" || true)"

  if [ -z "$summary" ]; then
    echo "FAILED: no summary line — the bundle probably crashed. Last 20 lines:"
    tail -20 "$log"
    grep -n 'signal code' "$log" | head -3 || true
    failed=1
    return
  fi

  echo "$summary"

  # Accumulate what actually RAN, SUMMED across every target in the pass. A
  # filter that matches nothing reports "Test run with 0 tests ... passed" —
  # green, having tested nothing — so a typo in one of these filters would
  # silently skip a target. The reconciliation after both passes is what
  # catches that, and it can only do so if this total is the real one.
  local ran
  ran="$(printf '%s\n' "$summary" | sed -E 's/.*with ([0-9]+) tests.*/\1/' \
         | awk '{ total += $1 } END { print total + 0 }')"
  counted=$(( counted + ran ))

  # ANY failing target fails the pass. Asking whether "the summary" passed
  # stopped being a single question the moment there was more than one.
  if printf '%s\n' "$summary" | grep -q 'failed'; then
    echo "  see $log"
    grep -E '^✘ Test "' "$log" | head -20
    failed=1
  fi
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
