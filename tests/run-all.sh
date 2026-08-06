#!/usr/bin/env bash
# Runs every hook test in this directory and reports wiring coverage.
#
# === Why a runner, and why it reports coverage ===
# A pile of test files existed before this runner did, and there was no single
# command that ran them. So a test could rot — a fixture path drifting, a hook
# renamed — and nothing would say so until someone happened to invoke that one
# file. That is the same failure the tests themselves are written against, one
# level up: an unrun test and a passing test produce the same silence.
#
# The coverage line is the second half. The issue that prompted this was opened
# on a hand-counted measurement of how many wired hooks lacked a regression test
# — a number that had to be recomputed by hand and was already stale by the time
# anyone picked it up. Deriving it from the wiring on every run means it is never
# quoted from memory.
#
# Coverage here means ONE thing and should not be read as more: a wired hook has
# a test FILE named after it. It says nothing about whether that file asserts
# anything useful. A hook with a good test can still carry a defect — that has
# happened here. Treat it as a floor, not a score.
#
# GAP lines are expected output, not failures: a case that pins a known defect's
# current behaviour so the suite stays green while the issue is open, and goes
# red when it is fixed. They are summarised at the end so an accumulating pile
# stays visible instead of scrolling past.
#
# === SKIP lines are counted, and that is not bookkeeping ===
# A case that skips is a case that did not run. If a skip increments no counter
# and prints nothing the runner notices, then a suite whose subject is absent on
# this platform reports the same "ok" as a suite that exercised everything — with
# a quietly lower assertion count and no signal that anything was missed.
#
# That is this repository's entire thesis applied to its own runner, so it gets
# enforced rather than described. Several suites here legitimately skip on some
# platforms (a Windows-only path form, a python-free PATH that cannot be built on
# this box). Those skips are correct. Being unable to SEE them is not.
#
# Concretely: the MSYS path-form cases skip on Linux and macOS, which is two of
# the three CI legs. Before skips were counted, the only visible difference was
# the assertion total moving — which nobody reads.
#
# Run: bash tests/run-all.sh
#      bash tests/run-all.sh --quiet     (summary + failures only)

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WIRING="$ROOT/examples/settings.json"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

ran=0; failed=0; gaps=0; skips=0
FAILED_FILES=""
SKIPPED_FILES=""
FLOORS="$TESTS_DIR/suite-floors.tsv"
SHORTFALL=""

# Read a suite's declared floor. Absent floor -> empty, and that is reported
# rather than treated as zero: a suite with no floor is unguarded, which is a
# different thing from a suite whose floor is satisfied.
floor_for() { # <suite basename>
  [ -f "$FLOORS" ] || return 0
  while IFS="$(printf '\t')" read -r name value; do
    case "$name" in ''|\#*) continue ;; esac
    [ "$name" = "$1" ] && { printf '%s' "$value"; return 0; }
  done < "$FLOORS"
}

for t in "$TESTS_DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t")"
  ran=$((ran+1))
  out="$(bash "$t" 2>&1)"; rc=$?
  # No `|| echo 0` here. `grep -c` already prints 0 on no-match and merely EXITS
  # 1, so the fallback would append a SECOND line and the arithmetic below would
  # see "0\n0". That is a real defect shape, reproduced while writing this
  # runner — which is a fair indication of how easy it is to write.
  g=$(printf '%s\n' "$out" | grep -c '^  GAP ')
  gaps=$((gaps + g))
  s=$(printf '%s\n' "$out" | grep -c '^  SKIP ')
  skips=$((skips + s))
  [ "$s" -gt 0 ] && SKIPPED_FILES="$SKIPPED_FILES $name:$s"
  if [ "$rc" -eq 0 ]; then
    # Two assertion formats are in use across this directory — `  PASS x` and
    # `  [PASS] x` — so both are counted. Getting this wrong is not cosmetic: a
    # file whose format goes unrecognised reports "0 passed" beside "ok", which
    # reads as a green run that asserted nothing. That is the same
    # indistinguishability the tests exist to break, so an exit-0 file with zero
    # recognised assertions is reported as UNCOUNTED, not as 0.
    p=$(printf '%s\n' "$out" | grep -cE '^  (PASS|\[PASS\])')
    if [ "$p" -eq 0 ]; then
      printf '?ok   %-34s  UNCOUNTED (exit 0, no recognized assertion lines)' "$name"
    else
      printf 'ok    %-34s %3s passed' "$name" "$p"
    fi
    [ "$g" -gt 0 ] && printf '  (%s known gap(s))' "$g"
    [ "$s" -gt 0 ] && printf '  [%s SKIPPED]' "$s"

    # --- the floor invariant -------------------------------------------------
    # assertions + explicit skips >= the measured floor.
    #
    # An exit-0 suite that quietly stopped running half its cases is otherwise
    # indistinguishable from one that ran them all, because the only difference
    # is a number with nothing to compare it to. This gives it something.
    fl="$(floor_for "$name")"
    acct=$((p + s))
    if [ -z "$fl" ]; then
      printf '  {NO FLOOR}'
      SHORTFALL="$SHORTFALL $name:unguarded"
    elif [ "$acct" -lt "$fl" ]; then
      printf '  ** ACCOUNTED %s < FLOOR %s **' "$acct" "$fl"
      failed=$((failed+1))
      FAILED_FILES="$FAILED_FILES $name"
      SHORTFALL="$SHORTFALL $name:$acct/$fl"
    fi
    printf '\n'
    if [ "$QUIET" -eq 0 ]; then
      printf '%s\n' "$out" | grep '^  GAP '  | sed 's/^/      /'
      printf '%s\n' "$out" | grep '^  SKIP ' | sed 's/^/      /'
    fi
  else
    failed=$((failed+1))
    FAILED_FILES="$FAILED_FILES $name"
    printf 'FAIL  %s\n' "$name"
    # Always show a failing file's output in full, in both modes. A runner that
    # hides the reason for a failure is a runner people stop running.
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
done

# --- wiring coverage --------------------------------------------------------
# Derived from the settings file, never hardcoded. A hook added to the wiring
# without a test shows up here on the next run rather than in someone's memory.
#
# In this repo the wiring read is examples/settings.json. Point WIRING at your own
# .claude/settings.json to get the same report for your live layer:
#
#   WIRING=~/.claude/settings.json bash tests/run-all.sh
WIRING="${WIRING:-$ROOT/examples/settings.json}"
. "$ROOT/lib/resolve-python.sh"
PY="$(resolve_python || true)"
echo
if [ -n "$PY" ] && [ -f "$WIRING" ]; then
  ( cd "$ROOT" && WIRING="$WIRING" "$PY" -X utf8 -c "
import json, re, os, glob

hooks = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == 'command' and isinstance(v, str):
                hooks.update(re.findall(r'([A-Za-z0-9_.-]+\.(?:sh|py))', v))
            else:
                walk(v)
    elif isinstance(o, list):
        for i in o:
            walk(i)
walk(json.load(open(os.environ['WIRING'], encoding='utf-8')))

tests = {os.path.basename(p) for p in glob.glob('tests/test-*.sh')}
uncovered = sorted(h for h in hooks if 'test-%s.sh' % h.rsplit('.', 1)[0] not in tests)
covered = len(hooks) - len(uncovered)
print('wiring coverage: %d/%d wired hooks have a test file' % (covered, len(hooks)))
if uncovered:
    print('untested:')
    for h in uncovered:
        print('  - ' + h)
# Test files with no wired hook of that name are NOT a defect — shared contract
# tests and helper-script tests legitimately have no settings entry. Listed so the
# two sets can be reconciled by eye rather than assumed to be equal.
extra = sorted(t for t in tests
               if t[5:-3] + '.sh' not in hooks and t[5:-3] + '.py' not in hooks)
if extra:
    print('tests not bound to a wired hook (contract/helper tests):')
    for t in extra:
        print('  - ' + t)
" )
else
  echo "wiring coverage: SKIPPED (need a working python and $WIRING)"
fi

echo
echo "========================================"
printf 'files: %d   failed: %d   skipped: %d   known gaps: %d\n' "$ran" "$failed" "$skips" "$gaps"
if [ "$skips" -gt 0 ]; then
  # Printed on every green run, deliberately. A skipped case is a case that did
  # not run, and the platform it did not run on is usually not the one you are
  # reading this from. Silence here would make "covered" and "not applicable
  # here" identical at a glance.
  echo "skipped by file:$SKIPPED_FILES"
  echo "(a skip is an assertion that did NOT execute — check it is skipping for the reason you expect)"
fi
if [ -n "$SHORTFALL" ]; then
  echo "coverage shortfall:$SHORTFALL"
  echo "(a suite below its floor stopped accounting for cases it used to run —"
  echo " either they vanished, or a block-level skip is standing in for several."
  echo " Emit one SKIP per skipped case, or re-measure the floor deliberately.)"
fi
if [ "$failed" -gt 0 ]; then
  echo "failing:$FAILED_FILES"
  exit 1
fi
# A GAP is a defect that is open and TRACKED, so it does not fail the run — but
# it must never become invisible. Reminding on every green run is the point.
[ "$gaps" -gt 0 ] && echo "(known gaps pin current behaviour of open issues; each flips red when fixed)"
exit 0
