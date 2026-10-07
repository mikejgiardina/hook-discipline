#!/bin/bash
# Behavioral tests for hooks/skip-ci-guard.sh — keeps the CI-skip marker off
# feature-branch commits.
#
# === What this guards ===
# The convention says "put the skip marker on the commit subject". Applied while
# committing on a FEATURE BRANCH it suppresses the pull_request trigger, and
# because merges to the default branch also carry the marker, such a PR gets no
# CI anywhere. A retrospective check found most branches in a sample had no CI
# runs at all; one change reached the default branch completely untested.
#
# The cases that carry the weight:
#   * marker on a feature-branch commit is DENIED
#   * marker on a default-branch commit is ALLOWED (the churn case the
#     convention exists for — denying it would just move the damage)
#   * a commit that merely QUOTES the marker is denied too, because GitHub
#     matches tokens anywhere in the message and such a commit really does skip
#     itself. That is the property that made the original incident hard to see.
#
# Run: bash tests/test-skip-ci-guard.sh
# Exits non-zero on any failure.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
HOOK="$HOOK_DIR/skip-ci-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK not found"; exit 1; }

PY="$(command -v python3 || command -v python || echo python)"
# An ambient HOOK_PYTHON pin is honoured by resolve_python BEFORE any PATH
# lookup, which silently defeats both the python-free-PATH cases below and any
# interposed interpreter. Unset so this suite measures what it claims to.
unset HOOK_PYTHON

pass=0; fail=0; skip=0

# PRECONDITION_HOOK_PYTHON — enforcement, not a request.
# The `unset` above is a line a future edit can quietly drop, and nothing would
# fail if it did; every interposition below would silently measure the pin
# instead of its subject, and still pass. A comment asking for it is a request.
# This is the assertion.
if [ -z "${HOOK_PYTHON:-}" ]; then
  echo "  PASS  precondition: HOOK_PYTHON unset (a pin would outrank PATH)"; pass=$((pass+1))
else
  echo "  FAIL  precondition: HOOK_PYTHON is set ([${HOOK_PYTHON}]) — the pin outranks"
  echo "        PATH, so interposed interpreters below are not what is measured"; fail=$((fail+1))
fi


# Real throwaway git repos — the hook resolves the branch with `git -C <cwd>`,
# so a fake cwd would make every case take the fail-open path and pass
# vacuously. That is the standing mistake this repo keeps making: a suite that
# is green because the branch under test never executed.
#
# The shared helper rather than a bare `mktemp -d`, because the fixture root has
# to be consumable by BOTH bash and a native Windows python — the hook hands the
# payload cwd to python, which shells back out to git. `mktemp -d` alone returns
# a mount-point path that the native side cannot resolve, so every case would
# silently take the fail-open branch. See tests/lib/fixture-root.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/fixture-root.sh"
fixture_root_init skipci

mkrepo() {   # $1=name $2=branch
  local d="$FIX/$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t.io; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m "root" 2>/dev/null
  git -C "$d" checkout -q -B "$2" 2>/dev/null
  printf '%s' "$d"
}
FEATURE="$(mkrepo feat  fix/123-thing)"
MAIN="$(mkrepo   mainr  main)"
MASTER="$(mkrepo mastr  master)"

payload() {  # $1=command $2=cwd
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$("$PY" -X utf8 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1")" \
    "$("$PY" -X utf8 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$2")"
}

check() {    # $1=label $2=cmd $3=cwd $4=DENY|ALLOW
  local label="$1" cmd="$2" cwd="$3" want="$4" out got
  out="$(payload "$cmd" "$cwd" | bash "$HOOK" 2>/dev/null)"
  if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then got=DENY; else got=ALLOW; fi
  if [ "$got" = "$want" ]; then echo "  PASS  $label"; pass=$((pass+1))
  else echo "  FAIL  $label — wanted $want, got $got"; fail=$((fail+1)); fi
}

# The literal tokens are assembled at runtime. Written inline, this test file
# would be fine (files are not commit messages) but the COMMIT that adds it
# would carry them and skip its own CI — the very trap under test.
B="["; E="]"
SKIP="${B}skip ci${E}"; CISKIP="${B}ci skip${E}"; NOCI="${B}no ci${E}"
SKIPACT="${B}skip actions${E}"; DASH="${B}skip-ci${E}"

echo "skip-ci-guard.sh"

echo
echo "the case the guard exists for"
check "marker on a FEATURE-branch commit is denied" \
  "git commit -m \"fix(x): thing $SKIP\"" "$FEATURE" DENY
# Positive control: identical command, identical repo shape, marker removed. If
# this ever reports DENY the case above proves nothing — it would mean the hook
# denies every commit rather than marker-bearing ones.
check "  control: same commit WITHOUT the marker allowed" \
  'git commit -m "fix(x): thing"' "$FEATURE" ALLOW

echo
echo "default-branch commits keep the marker — the churn case the convention exists for"
check "marker on main is allowed"                   "git commit -m \"chore: update $SKIP\"" "$MAIN"   ALLOW
check "marker on master is allowed"                 "git commit -m \"chore: update $SKIP\"" "$MASTER" ALLOW

echo
echo "every GitHub skip token, not just the common one"
check "ci skip"                                     "git commit -m \"x $CISKIP\""  "$FEATURE" DENY
check "no ci"                                       "git commit -m \"x $NOCI\""    "$FEATURE" DENY
check "skip actions"                                "git commit -m \"x $SKIPACT\"" "$FEATURE" DENY
check "hyphenated skip-ci"                          "git commit -m \"x $DASH\""    "$FEATURE" DENY
check "case-insensitive"                            "git commit -m \"x ${B}Skip CI${E}\"" "$FEATURE" DENY

echo
echo "the body case — GitHub matches anywhere, so a commit that QUOTES the marker skips itself"
# The original incident's first two pushes produced no run: clean subject, marker
# quoted twice in the body while explaining the problem. Removing the literal
# token made CI fire on the same diff.
check "marker in the BODY of a -F heredoc is denied" \
  "git commit -F - <<'EOF'
fix(ci): explain the convention

The marker is $SKIP and it is applied at merge time.
EOF" "$FEATURE" DENY
check "marker in a second -m body paragraph"        "git commit -m \"subject\" -m \"body mentions $SKIP\"" "$FEATURE" DENY

echo
echo "escape hatch"
check "HOOK_ALLOW_SKIP_CI=1 permits it"             "HOOK_ALLOW_SKIP_CI=1 git commit -m \"x $SKIP\"" "$FEATURE" ALLOW

echo
echo "no false positives"
check "commit with no marker"                       'git commit -m "fix(x): ordinary work"' "$FEATURE" ALLOW
check "marker in prose, NOT a git commit"           "echo \"the marker is $SKIP\"" "$FEATURE" ALLOW
# The command below is never executed — the hook is PreToolUse and only inspects
# the string. Merge is the RIGHT place for the marker, so this must not deny.
check "a merge command carrying the marker is allowed" \
  "gh pr merge 5 --squash --subject \"t $SKIP (#5)\"" "$FEATURE" ALLOW
check "unrelated git command"                       'git status' "$FEATURE" ALLOW
check "commit-ish word in prose"                    "echo 'commit the marker $SKIP later'" "$FEATURE" ALLOW

echo
echo "git global options before the subcommand are still a commit (#2)"
# A global that takes a separate argument (-C <dir>, -c <k=v>, --git-dir <dir>)
# used to stop the match: the argument is not a flag, so the scan never reached
# `commit` and the call was allowed without being checked.
check "-C <feature repo> commit, from a main-branch cwd, is denied" \
  "git -C $FEATURE commit -m \"x $SKIP\"" "$MAIN" DENY
check "-c <key=value> commit on a feature branch is denied" \
  "git -c user.name=t commit -m \"x $SKIP\"" "$FEATURE" DENY
check "  control: -c <key=value> commit on main is allowed" \
  "git -c user.name=t commit -m \"x $SKIP\"" "$MAIN" ALLOW
check "--git-dir <feature .git> (separate argument) is denied from a main cwd" \
  "git --git-dir $FEATURE/.git --work-tree $FEATURE commit -m \"x $SKIP\"" "$MAIN" DENY
check "--git-dir=<feature .git> (attached form) is denied from a main cwd" \
  "git --git-dir=$FEATURE/.git --work-tree=$FEATURE commit -m \"x $SKIP\"" "$MAIN" DENY
check "a plain flag before -C does not hide it" \
  "git --no-pager -C $FEATURE commit -m \"x $SKIP\"" "$MAIN" DENY

echo
echo "the branch is read from the repo the commit acts on, not the session cwd (#2)"
check "-C <main repo> from a feature-branch cwd is allowed" \
  "git -C $MAIN commit -m \"chore: update $SKIP\"" "$FEATURE" ALLOW
check "quoted -C <feature repo> from a main cwd is denied" \
  "git -C \"$FEATURE\" commit -m \"x $SKIP\"" "$MAIN" DENY
# git applies each later -C relative to the one before it; an absolute one
# replaces what came before.
check "chained -C <root> -C feat resolves to the feature repo" \
  "git -C $FIX -C feat commit -m \"x $SKIP\"" "$MAIN" DENY
check "chained -C <root> -C mainr resolves to the main repo" \
  "git -C $FIX -C mainr commit -m \"x $SKIP\"" "$FEATURE" ALLOW
check "a later absolute -C replaces an earlier one" \
  "git -C $MAIN -C $FEATURE commit -m \"x $SKIP\"" "$MAIN" DENY
check "-C naming a directory that is not a repo fails open" \
  "git -C $FIX/not-a-repo commit -m \"x $SKIP\"" "$FEATURE" ALLOW
# A -C argument that only the shell can expand cannot be resolved here. The
# hook then checks the session cwd, which is what it did before -C was read.
check "-C with a shell variable falls back to the session cwd" \
  "git -C \"\$REPO_DIR\" commit -m \"x $SKIP\"" "$FEATURE" DENY
check "the opt-out still applies with -C" \
  "HOOK_ALLOW_SKIP_CI=1 git -C $FEATURE commit -m \"x $SKIP\"" "$MAIN" ALLOW

echo
echo "quoted data is not a command; a quoted MESSAGE is still read (#2)"
# Separators inside a quoted argument used to anchor a command, so a string that
# merely contains a commit command (a printf argument, a JSON blob) was denied.
check "a commit command inside a single-quoted printf argument is allowed" \
  "printf '%s\\n' 'cd x && git commit -m \"fix $SKIP\"'" "$FEATURE" ALLOW
check "a commit command inside a double-quoted echo argument is allowed" \
  "echo \"next: cd x; git commit -m fix-$SKIP\"" "$FEATURE" ALLOW
check "a commit command inside a quoted JSON string is allowed" \
  "printf '%s' '{\"command\":\"cd x && git commit -m \\\"$SKIP\\\"\"}'" "$FEATURE" ALLOW
check "  control: the same commit run for real after cd && is denied" \
  "cd $FEATURE && git commit -m \"fix $SKIP\"" "$FEATURE" DENY
check "marker inside a single-quoted -m message is denied" \
  "git commit -m 'subject $SKIP'" "$FEATURE" DENY
check "command substitution inside double quotes still runs, so it is denied" \
  "echo \"\$(git commit -m 'x $SKIP')\"" "$FEATURE" DENY
check "marker in a -F - heredoc after a quoted global is denied" \
  "git -C \"$FEATURE\" commit -F - <<'EOF'
subject

body mentions $SKIP
EOF" "$MAIN" DENY

echo
echo "lib/cmdparse.py helpers used by this hook"
# Direct checks on the helpers, so a regression in one shows up by name rather
# than only as a changed verdict above. Output goes to a file, not through a
# pipeline: a while-loop on the right of a pipe runs in a subshell under
# bash 3.2 and would lose the counters.
UNIT_OUT="$FIX/cmdparse-unit.out"
CP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)" "$PY" -X utf8 - > "$UNIT_OUT" 2>&1 <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("CP_LIB", ""))
from cmdparse import mask_quoted, search_cmd, git_global_args, git_invocation

def check(label, ok):
    print(("PASS " if ok else "FAIL ") + label)

s = "printf '%s' 'cd x && git commit' \"a; b\""
m = mask_quoted(s)
check("U1 mask_quoted keeps the length", len(m) == len(s))
check("U2 mask_quoted blanks separators inside quotes", "&&" not in m and ";" not in m)
check("U3 mask_quoted keeps the quote characters", m.count("'") == s.count("'") and m.count('"') == s.count('"'))
check("U4 mask_quoted leaves $( ) inside double quotes live",
      "git" in mask_quoted('echo "$(git commit -m x)"'))
check("U5 search_cmd ignores a verb anchored inside quotes",
      search_cmd(r"git\s+commit\b", "printf '%s' 'cd x && git commit'") is None)
check("U6 search_cmd finds a verb at command position",
      search_cmd(r"git\s+commit\b", "cd x && git commit -m 'y'") is not None)
inv = search_cmd(git_invocation("commit"), 'git -C a -c k=v -C "b c" --git-dir=d --work-tree e commit -m x')
check("U7 git_invocation captures the globals before the subcommand", inv is not None)
args = git_global_args(inv.group(1)) if inv else None
check("U8 git_global_args keeps -C / --git-dir / --work-tree in order, drops -c",
      args == ["-C", "a", "-C", "b c", "--git-dir", "d", "--work-tree", "e"])
inv2 = search_cmd(git_invocation("commit"), 'git -C "$X" commit -m x')
check("U9 git_global_args refuses an argument the shell would expand",
      inv2 is not None and git_global_args(inv2.group(1)) is None)
# An apostrophe in a heredoc body is text, not an opening quote. If it were
# read as one, everything after it would be masked and the real commit that
# follows would go unseen.
hd = "x=\"$(cat <<'EOF'\nit's a note\nEOF\n)\" && git commit -m y"
check("U10 an apostrophe in a heredoc body does not mask what follows",
      search_cmd(r"git\s+commit\b", hd) is not None)
PY
UNIT_EXPECT=10
unit_seen=0
while IFS= read -r line; do
  case "$line" in
    PASS\ *) echo "  PASS  ${line#PASS }"; pass=$((pass+1)); unit_seen=$((unit_seen+1)) ;;
    FAIL\ *) echo "  FAIL  ${line#FAIL }"; fail=$((fail+1)); unit_seen=$((unit_seen+1)) ;;
  esac
done < "$UNIT_OUT"
if [ "$unit_seen" -eq "$UNIT_EXPECT" ]; then
  echo "  PASS  U0 all $UNIT_EXPECT helper checks reported"; pass=$((pass+1))
else
  echo "  FAIL  U0 helper checks reported $unit_seen of $UNIT_EXPECT; output was:"; fail=$((fail+1))
  sed 's/^/        /' "$UNIT_OUT"
fi

echo
echo "degenerate input must never crash or block"
for body in '' '{"tool_input":' '{"tool_input":{}}'; do
  printf '%s' "$body" | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ $rc -eq 0 ] && { echo "  PASS  degenerate payload -> exit 0"; pass=$((pass+1)); } \
                || { echo "  FAIL  degenerate payload -> exit $rc"; fail=$((fail+1)); }
done
# Unresolvable cwd must fail OPEN — a degraded toolchain cannot stop committing.
check "unresolvable repo fails open"                "git commit -m \"x $SKIP\"" "$FIX/not-a-repo" ALLOW

echo
echo "the missing-dependency branch must be LOUD"
# This hook imports CMD_START and to_native_path from lib/cmdparse.py. If that
# import fails it allows — correct, it is fail-open — but it must SAY so.
# Otherwise the marker check is silently off and every commit sails through
# looking checked.
#
# The sibling guard got this block when its import branch was written; this one
# did not, and the asymmetry survived a review pass. Worth stating plainly: the
# newest code in a repository whose entire thesis is "an untested check is the
# failure mode" had exactly that gap, in one of the two places the branch was
# introduced. That is how ordinary it is.
#
# D0 and D3 are what stop D1 being vacuous — D0 proves the stripped mirror really
# lacks the module, D3 proves the equipped one does not warn unconditionally.
BARE="$FIX/bare"
mkdir -p "$BARE/hooks" "$BARE/lib"
cp "$HOOK" "$BARE/hooks/skip-ci-guard.sh"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh" "$BARE/lib/"
# cmdparse.py deliberately NOT copied.

if [ ! -f "$BARE/lib/cmdparse.py" ]; then
  echo "  PASS  D0 the stripped mirror genuinely lacks cmdparse (premise of D1)"; pass=$((pass+1))
else
  echo "  FAIL  D0 stripped mirror still has cmdparse — D1 would be vacuous"; fail=$((fail+1))
fi

D_ERR="$(payload "git commit -m \"x $SKIP\"" "$FEATURE" \
         | bash "$BARE/hooks/skip-ci-guard.sh" 2>&1 >/dev/null)"
D_RC=$?
if printf '%s' "$D_ERR" | grep -q 'cmdparse'; then
  echo "  PASS  D1 a missing dependency is announced on stderr, not swallowed"; pass=$((pass+1))
else
  echo "  FAIL  D1 missing cmdparse degraded SILENTLY — the marker check is off"; fail=$((fail+1))
  echo "        and every commit looks checked. stderr was: '$D_ERR'"
fi

if [ "$D_RC" -eq 0 ]; then
  echo "  PASS  D2 ...and still exits 0 (loud, not fatal — committing must not break)"; pass=$((pass+1))
else
  echo "  FAIL  D2 degraded path exited $D_RC — a fail-open guard must not block"; fail=$((fail+1))
fi

E_ERR="$(payload "git commit -m \"x $SKIP\"" "$FEATURE" | bash "$HOOK" 2>&1 >/dev/null)"
if printf '%s' "$E_ERR" | grep -q 'cmdparse'; then
  echo "  FAIL  D3 the EQUIPPED hook also warns — D1 proves nothing"; fail=$((fail+1))
else
  echo "  PASS  D3 the equipped hook stays quiet (control for D1)"; pass=$((pass+1))
fi

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
