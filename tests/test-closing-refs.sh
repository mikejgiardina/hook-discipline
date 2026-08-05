#!/bin/bash
# Tests for tools/closing-refs.py -- the issue-closing-directive extractor.
#
# === The bug this guards ===
# A pull request merged cleanly with a description reading
# `Closes core#101. Closes core#102. Closes core#103.` All three issues stayed
# OPEN. The control is a pull request in the same repo an hour earlier: it wrote
# `Closes #110. Closes #111.` and both closed on merge.
#
# GitHub resolves `#N` and `owner/repo#N`. A bare `core#101` is neither -- it is
# a project's own prose shorthand. Where that shorthand is recommended practice,
# the natural way to write a PR body is the broken way. It reads perfectly to a
# human and is invisible to GitHub's linker, which makes it the worst kind of
# defect to catch: a plausible-looking success rather than an error.
#
# === Why block C is the load-bearing one ===
# A retrospective sweep of several hundred merged pull requests measured a naive
# proximity regex at roughly a 75% false-positive rate, and its false positives
# were not near-misses -- several sat on issues an author had written a sentence
# to keep OPEN. So "the matcher fires on the known defect" is only half a result.
# "The matcher stays silent on the known non-defects" is the half that decides
# whether this is safe to ship, and block C is that half.
#
# === Why the R block exists on top of C ===
# Mutation-testing the corpus is what tells you whether a rule is actually being
# tested or merely being described. Every rule below has at least one corpus case
# that goes red when that rule alone is removed -- but three of the four are
# reached by only one or two cases, and rule 4 is shadowed entirely for the
# prefix form. Block R probes those directly, so a future loosening of one rule
# cannot silently strip the coverage of another.
#
# Run: bash tests/test-closing-refs.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CR="$ROOT/tools/closing-refs.py"
[ -f "$CR" ] || { echo "FATAL: $CR not found"; exit 1; }

# Interpreter resolution. Prefer the shared helper; fall back to an inline probe
# so this suite still runs if it is copied out on its own.
#
# The fallback is python3-first, which is what keeps stock macOS (no bare
# `python`) working, and it PROBES each candidate rather than trusting that a
# name resolving means it runs. On Windows those two come apart: the OS ships an
# App-Execution-Alias stub at %LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe
# that prints a Store advertisement and exits 49, so `command -v python3`
# succeeds, the `|| command -v python` never fires, and the caller ends up with a
# non-empty, non-functional interpreter.
if [ -f "$ROOT/lib/resolve-python.sh" ]; then
  . "$ROOT/lib/resolve-python.sh"
  PY="$(resolve_python || true)"
else
  PY=""
  for _c in python3 python; do
    _p="$(command -v "$_c" 2>/dev/null)" || continue
    [ -n "$_p" ] || continue
    case "$("$_p" --version 2>&1)" in
      "Python 3"*) PY="$_p"; break ;;
    esac
  done
fi
[ -n "$PY" ] || { echo "FATAL: no usable Python (the detector is a python module)"; exit 1; }

pass=0; fail=0; skip=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 -- expected [$2], got [$3]"; fail=$((fail+1)); fi
}

echo "closing-refs.py -- issue-closing-directive extraction"
echo

echo "S. syntax"
"$PY" -X utf8 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$CR" 2>/dev/null \
  && { echo "  PASS  S1 closing-refs.py parses"; pass=$((pass+1)); } \
  || { echo "  FAIL  S1 closing-refs.py does not parse"; fail=$((fail+1)); }
# Standard library only. A tool that runs inside a hook, inside CI and inside a
# test with no credentials present must not acquire a dependency by accident,
# and must never reach the network or shell out to a GitHub client.
if grep -nE "^[[:space:]]*(import|from)[[:space:]]" "$CR" \
     | grep -vE "(import|from)[[:space:]]+(re|sys|os|json|importlib)([[:space:]]|\.|$)" >/dev/null; then
  echo "  FAIL  S2 a non-stdlib import appeared"; fail=$((fail+1))
else
  echo "  PASS  S2 stdlib-only imports"; pass=$((pass+1))
fi
if grep -nE "subprocess|urllib|socket|http\.client|[^a-z]gh " "$CR" >/dev/null; then
  echo "  FAIL  S3 the extractor reaches outside the process"; fail=$((fail+1))
else
  echo "  PASS  S3 no subprocess / network / gh calls"; pass=$((pass+1))
fi

echo
echo "C. the parsing corpus, run in-process"
# Delegated to the module's own --self-test rather than restated here. Restating
# would give two corpora to keep in step, and the one that drifts silently is the
# one nobody edits. The exit code is the assertion.
CORPUS_OUT="$("$PY" -X utf8 "$CR" --self-test 2>&1)"; CORPUS_RC=$?
printf '%s\n' "$CORPUS_OUT" | sed -n 's/^  \(PASS\|FAIL\)/  \1/p'
if [ "$CORPUS_RC" -eq 0 ]; then
  echo "  PASS  C-all the corpus self-test exits 0"; pass=$((pass+1))
else
  echo "  FAIL  C-all the corpus self-test exits $CORPUS_RC"; fail=$((fail+1))
fi
# The measurement that justified rejecting a proximity matcher. Asserted rather
# than merely printed, because it is the number the design decision rests on and
# a silent regression in it would remove the argument without removing the claim.
if printf '%s' "$CORPUS_OUT" | grep -q 'naive .* would hit'; then
  echo "  PASS  C-fp the self-test reports the naive-matcher comparison"; pass=$((pass+1))
else
  echo "  FAIL  C-fp the naive-matcher comparison is gone -- the false-positive"
  echo "        measurement that justified this design is no longer being made"
  fail=$((fail+1))
fi

echo
echo "E. extraction contract -- the TSV a caller parses"
# stderr is NOT discarded here, and that is deliberate.
#
# Most cases in this block assert that some input produces NO records. Piping
# stderr to /dev/null makes a crashed interpreter — a traceback, an import error,
# a syntax error introduced by an edit — produce empty stdout too, which is
# indistinguishable from "ran fine, correctly found nothing". Every negative case
# in the block would pass against a module that cannot even be imported.
#
# So: capture stderr separately and fail loudly if anything reached it. The
# distinction between "found nothing" and "could not look" is the one this whole
# repository is about, and throwing it away one helper above the assertions is
# how it gets lost.
CR_ERR=""
run_cr() {
  local _err
  _err="${TMPDIR:-/tmp}/.cr_stderr.$$"
  printf '%s' "$1" | "$PY" -X utf8 "$CR" 2>"$_err"
  CR_ERR="$(cat "$_err" 2>/dev/null)"
  rm -f "$_err"
  if [ -n "$CR_ERR" ]; then
    echo "  FAIL  closing-refs wrote to stderr — output below is NOT a clean empty result:" >&2
    printf '%s\n' "$CR_ERR" | sed 's/^/          /' >&2
    fail=$((fail+1))
  fi
}
out="$(run_cr 'Closes core#101. Closes core#102.')"
check "E1 two prefix directives on one line -> two records" 2 "$(printf '%s\n' "$out" | grep -c .)"
check "E2 kind field is 'unparseable'" unparseable "$(printf '%s' "$out" | head -1 | cut -f1)"
check "E3 ref field is preserved verbatim" "core#101" "$(printf '%s' "$out" | head -1 | cut -f2)"
check "E4 number field is bare" "101" "$(printf '%s' "$out" | head -1 | cut -f3)"
check "E5 a bare ref classifies as parseable" "parseable" \
  "$(run_cr 'Closes #110' | head -1 | cut -f1)"
check "E6 a cross-repo ref is not chopped to its second segment" \
  "example-org/example-repo#140" \
  "$(run_cr 'Closes example-org/example-repo#140' | head -1 | cut -f2)"
check "E7 a trailing ', #N' is reported as a list-continuation, not a directive" \
  "list-continuation" "$(run_cr 'Closes #120, #121.' | sed -n 2p | cut -f1)"

# Exit codes are a contract, not decoration: a caller must be able to tell "no
# directives in this body" from "the detector blew up". Collapsing those two is
# how a broken check comes to look like a clean result.
printf 'nothing to see here' | "$PY" -X utf8 "$CR" >/dev/null 2>&1
check "E8 no directives -> exit 1 (not 0)" 1 $?
printf 'Closes #1' | "$PY" -X utf8 "$CR" >/dev/null 2>&1
check "E9 directives found -> exit 0" 0 $?
"$PY" -X utf8 "$CR" a b c >/dev/null 2>&1
check "E10 usage error -> exit 2" 2 $?

echo
echo "T. PR titles -- reported, never honoured"
# GitHub's linker reads the PR description and the commit messages. It does not
# read the title at all, so a closing keyword there is a directive the author
# meant and the platform will silently ignore.
t_out="$(printf 'Live queue visualization for the worker pool - closes #130, #131\n' \
          | "$PY" -X utf8 "$CR" --title 2>/dev/null)"
check "T1 a closing keyword in a title is downgraded to title-only" "title-only" \
  "$(printf '%s' "$t_out" | head -1 | cut -f1)"
check "T2 ...and the trailing ref is reported too, not dropped" 2 \
  "$(printf '%s\n' "$t_out" | grep -c .)"
# Paired control: the SAME text through the body path must classify normally.
# Without it, T1 passes equally well against a version that labels everything
# title-only.
check "T3 control: the same text as a body is NOT title-only" "parseable" \
  "$(run_cr 'Live queue visualization for the worker pool - closes #130, #131' | head -1 | cut -f1)"

echo
echo "R. the four rules, probed directly"
# R1 -- adjacency. One corpus case isolates this; the probe states the rule in
# one line so a reader does not have to reconstruct it from a fixture.
check "R1 a word between keyword and ref is not a directive" "" \
  "$(run_cr 'Resolves the four items flagged in core#210')"
check "R2 ...but extra spaces still are (the {0,2} bound was too tight)" "core#101" \
  "$(run_cr 'Closes    core#101' | cut -f2)"
# R3 is rule 2, and rule 2 is the LINE LOOP, not the regex. Worth being exact:
# swapping `[ \t]*` for `\s*` in the pattern is a NO-OP mutation here, because
# extract() never hands the regex more than one line. The mutation that actually
# threatens this case is matching over the whole text at once, which is how a
# naive sweep produces the paragraph-boundary false positive in the first place.
check "R3 keyword on one line, ref on the next -> nothing" "" \
  "$(run_cr 'Neither underlying gap is closed
core#31 remains open.')"
# R4 reaches the negation guard directly. The corpus isolates it only through the
# BARE-ref case, because rule 3 rejects every natural PREFIX-form phrasing before
# the guard is consulted. If rule 3 is ever loosened, this is what stops
# "they do **not** close core#64" from closing the issue its author protected.
#
# The module is loaded by path rather than imported by name: the filename is
# hyphenated because it is a script, so `import` will not reach it. `-B` because
# exec_module() otherwise drops a __pycache__ directory into tools/, and a test
# run should not leave build artifacts in the tree it is testing.
neg_hit="$("$PY" -B -X utf8 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('closing_refs', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('HIT' if mod._NEGATION.search('these artifacts do not ') else 'MISS')
print('HIT' if mod._NEGATION.search(\"it doesn't \") else 'MISS')
print('HIT-WRONGLY' if mod._NEGATION.search('this change ') else 'MISS')
" "$CR" 2>/dev/null)"
check "R4 negation guard fires on 'do not' / \"doesn't\" and not on plain prose" \
  "HIT HIT MISS" "$(printf '%s' "$neg_hit" | tr -d '\r' | tr '\n' ' ' | sed 's/ *$//')"
# R5 -- rule 3's separator. `.` opens a new sentence; `;` and `(` do not, because
# both routinely join a directive-shaped clause to prose that is describing
# something else.
check "R5 a semicolon does not open a new sentence" "" \
  "$(run_cr 'fix(parser): idle-drive the queue; resolves core#73 flag')"
check "R6 ...but a full stop does (the three-on-one-line defect)" 3 \
  "$(run_cr 'Closes core#101. Closes core#102. Closes core#103.' | grep -c .)"
# R7 -- rule 3 is scoped to the prefix form only. A bare ref mid-line IS honoured
# by GitHub, so scoping the rule wider than the defect would make this tool
# disagree with the platform in the safe direction, which is still a disagreement
# a caller would have to work around.
check "R7 rule 3 does not apply to bare refs, which GitHub honours mid-line" \
  "parseable" \
  "$(run_cr 'This change reworks the retry path and closes #64 along the way' | head -1 | cut -f1)"

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
