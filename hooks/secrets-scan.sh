#!/usr/bin/env bash
# secrets-scan.sh — PreToolUse(Bash) hook. BLOCKS `git commit` when a staged file
# matches a secrets pattern (.env.local / *.key / secrets.json).
#
# === Why this is jq-free ===
# An earlier version of this hook depended on `jq` for BOTH its input read (`jq -r
# '.tool_input.command'`) and its decision emit (`jq -n '{...}'`). `jq` is not
# installed on every machine this runs on, and this hook layer is deliberately
# jq-free so the same files work on a Windows box with only Git-Bash as well as on
# macOS and Linux. Every jq call errored; with the usual settings wiring
# (`... || true`) the errors were swallowed and the hook FAILED OPEN — silently
# allowing every commit, including ones staging secrets. That is the failure this
# file is shaped around, and it is why the posture below is inverted.
#
# === Empirically verified on a real build, not assumed ===
#   * PreToolUse(Bash) delivers its payload as JSON on STDIN, command at the NESTED
#     key  .tool_input.command .  ($CLAUDE_TOOL_INPUT is UNSET for PreToolUse here,
#     though set for PostToolUse — so this hook reads stdin, not the env var.)
#   * The hook's cwd is whatever the session was started in. That may be a
#     workspace root holding several checkouts and not itself a git repo, in which
#     case a bare `git diff --cached` sees nothing. We resolve the target repo from
#     the command's `-C <dir>` / leading `cd <dir>` and fall back to the payload cwd.
#   * Blocking goes through stdout JSON  permissionDecision:deny  (exit 0). Exit
#     code 2 would also block, but `|| true` swallows exit codes, so stdout JSON is
#     the only channel that survives the wiring.
#
# === Posture: FAIL CLOSED ===
# A security gate must fail closed: if it cannot PROVE a commit is safe, it blocks.
# The original jq failure failed OPEN silently; that direction is now inverted.
#   * python-free fast pre-filter: if the RAW payload contains no "commit" substring
#     the command cannot be a git commit -> allow without touching the toolchain
#     (so a degraded toolchain never blocks unrelated Bash commands).
#   * For any COMMIT-SHAPED command, every "can't evaluate" branch EMITS DENY:
#     python missing, python crash (nonzero exit), or an unresolved target. The
#     deny on those branches is printed by a python-free printf, so the block fires
#     even when python itself is the broken dependency.
#   * Wire THIS hook without `2>/dev/null` (keep `|| true`) so an unexpected crash
#     before a deny is emitted is at least VISIBLE rather than silent — the single
#     change that would have made the jq breakage loud on day one.
set -uo pipefail

# python-free deny emitter — works even if python is unavailable. The reason MUST
# be plain text (no double-quote / backslash / newline) so it is valid JSON as-is.
emit_deny_plain() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
}

# Read stdin; `timeout` if present (Git-Bash/Linux), plain cat on macOS (no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  PAYLOAD=$(timeout 2 cat 2>/dev/null || echo "")
else
  PAYLOAD=$(cat 2>/dev/null || echo "")
fi

# Fast pre-filter on the RAW payload. No "commit" anywhere -> cannot be a git commit
# -> allow (and don't burden unrelated commands with the toolchain checks below).
case "$PAYLOAD" in
  *commit*) ;;
  *) exit 0 ;;
esac

# --- Commit-shaped from here. FAIL CLOSED on any inability to verify. ----------

# python unavailable while git present is the exact dangerous case the original
# hook failed open on. Block; the operator can fix the toolchain or unstage by hand.
# Interpreter via lib/resolve-python.sh: `command -v` proves a name resolves, not
# that it RUNS (Windows ships a dead python3 alias stub). The full narrative lives
# in that file.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh"
PY="$(resolve_python || true)"
if [ -z "$PY" ]; then
  emit_deny_plain "secrets-scan cannot run (python3/python not found) on a commit-shaped command; blocking fail-closed. Restore python on PATH, or unstage any .env.local/*.key/secrets.json and retry."
  exit 0
fi

# Parse + resolve the target repo. python prints exactly one of: NOTCOMMIT (proven
# not a git commit), the repo dir, or empty. Its exit code separates a clean run
# from a crash.
# === Why the source goes into a variable instead of straight down a pipe ===
# The obvious form is `RESULT=$("$PY" - <<'PY' ... PY)` — a heredoc feeding a
# command inside a command substitution. Every bash 4+ parses it. **Stock macOS
# ships bash 3.2, whose parser cannot handle a heredoc nested inside `$( )`.**
#
# The failure is worth describing because it does not point at itself: bash 3.2
# reports a syntax error on an EARLIER line, near whichever token it choked on
# while unwinding — here, an innocent and correctly-quoted string several lines
# above the actual heredoc. Reading that message leads you to rewrite a line that
# was never wrong.
#
# `read -r -d ''` takes the heredoc on a SIMPLE command, which every bash parses,
# and `-c` then hands the source to python. `read -d ''` returns non-zero when it
# hits EOF without the delimiter — which is always, here — so `|| true` is
# required and is not defensive clutter.
IFS='' read -r -d '' PY_RESOLVE_TARGET <<'PY' || true
import os, re, json
raw = os.environ.get("SECRETS_PAYLOAD", "")
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    d = {}
ti = d.get("tool_input") or {}
cmd = ti.get("command", "") if isinstance(ti, dict) else ""
if not ("git" in cmd and "commit" in cmd):
    print("NOTCOMMIT"); raise SystemExit(0)
target = ""
m = re.search(r'-C\s+("[^"]+"|\'[^\']+\'|\S+)', cmd)            # git -C <dir>
if m:
    target = m.group(1).strip("\"'")
else:
    m = re.search(r'(?:^|&&|;|\|\|)\s*cd\s+("[^"]+"|\'[^\']+\'|[^&;|]+)', cmd)  # cd <dir> && git commit
    if m:
        target = m.group(1).strip().strip("\"'")
if not target:
    target = d.get("cwd", "") or "."
print(target)
PY

RESULT=$(SECRETS_PAYLOAD="$PAYLOAD" "$PY" -X utf8 -c "$PY_RESOLVE_TARGET" 2>/dev/null)
PYRC=$?
RESULT=$(printf '%s' "$RESULT" | tr -d '\r\n')   # defend against Windows CRLF on python stdout

# python crashed on a commit-shaped command -> can't verify -> block.
if [ "$PYRC" -ne 0 ]; then
  emit_deny_plain "secrets-scan internal error parsing a commit-shaped command; blocking fail-closed."
  exit 0
fi

case "$RESULT" in
  NOTCOMMIT) exit 0 ;;                                                                 # proven not a git commit -> allow
  "") emit_deny_plain "secrets-scan could not resolve the target repo for a commit-shaped command; blocking fail-closed." ; exit 0 ;;
  *) TARGET="$RESULT" ;;
esac

# If the target isn't a git work tree, no commit can land there (git itself rejects),
# so there's nothing to scan -> allow.
git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- staged-file secrets scan -------------------------------------------------
SECRETS=$(git -C "$TARGET" diff --cached --name-only 2>/dev/null \
  | grep -E '\.env\.local|\.key|secrets\.json' | head -5 || true)

if [ -n "$SECRETS" ]; then
  LIST=$(printf '%s' "$SECRETS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  REASON="[SECRETS SCAN] blocked this commit. Staged file(s) match a forbidden secrets pattern (.env.local / *.key / secrets.json): ${LIST}. Move them out of the repository, add to .gitignore, and unstage them (git -C \"${TARGET}\" restore --staged <file>) before committing."
  # python is guaranteed present here (it answered --version above) -> json.dumps
  # for safe escaping of the file list + path. If it somehow yields nothing, fall
  # back to a plain deny so a detected secret is NEVER allowed through (fail closed).
  # Same bash 3.2 constraint as above: no heredoc inside $( ).
  IFS='' read -r -d '' PY_DENY <<'PY' || true
import os, json
reason = os.environ.get("SECRETS_REASON", "Secrets detected in staged files.")
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason
  }
}))
PY

  DENY=$(SECRETS_REASON="$REASON" "$PY" -X utf8 -c "$PY_DENY" 2>/dev/null)
  if [ -n "$DENY" ]; then
    printf '%s\n' "$DENY"
  else
    emit_deny_plain "secrets-scan detected staged secret file(s) but could not format the detail; blocking fail-closed."
  fi
  exit 0
fi

# No secrets staged -> allow.
exit 0
