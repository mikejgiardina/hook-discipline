#!/usr/bin/env bash
# worktree-guard.sh — PreToolUse(Bash) hook. Two jobs:
#
#   1. TOUCH the live-session registry with this session's per-repo activity, so
#      another session's SessionStart warning can say *which* repos are contended.
#   2. GUARD tree-mutating git ops on a DIRTY working tree. `git pull` / `git
#      merge` / `git rebase` / `gh pr merge` onto uncommitted work is the
#      clobber/conflict risk this pair of hooks exists for. On a dirty tree it asks
#      the agent to commit-to-a-branch (or stash) and retry — "surface +
#      resolve-then-retry," not a dumb forbid. The op passes automatically once the
#      tree is clean.
#
# === State file ===
# Shares one registry with session-registry.sh:  hooks/.session-registry.json
# (override with HOOK_SESSION_REGISTRY). It is machine-local runtime state, not
# source — GITIGNORE IT, along with the `.session-registry.json.tmp.*` files the
# atomic write leaves behind if a write is interrupted.
#
# === Posture: ADVISORY, FAIL-OPEN ===
# This is a safety convenience, not a security gate (the opposite of
# secrets-scan.sh, which fails closed). Any "can't evaluate" branch — no python,
# unparseable payload, target isn't a git work tree, `git status` errors — ALLOWS
# the command. A worktree guard that blocked pulls on a degraded toolchain would be
# worse than the problem it solves.
#
#   Default decision on a dirty mutating op = "ask" (warn-first, user confirms).
#   Set HOOK_WORKTREE_HARDBLOCK=1 to escalate it to "deny". Off by default on
#   purpose: during the incident this guard was written for, a hard block would
#   have made the hand-reconciliation that followed strictly worse.
#
# jq-free (python for JSON), matching the rest of the hooks, so the same file works
# on a Windows box with only Git-Bash. Reads the command at .tool_input.command on
# stdin (PreToolUse does NOT set $CLAUDE_TOOL_INPUT — verified, see secrets-scan.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REG="${HOOK_SESSION_REGISTRY:-$SCRIPT_DIR/.session-registry.json}"
STALE="${HOOK_SESSION_STALE_SECS:-1800}"

# Read stdin; `timeout` if present (Git-Bash/Linux), plain cat on macOS (no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
  # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
  # continuing with an empty payload, which every guard would read as "allow".
  PAYLOAD="$(timeout 2 cat 2>/dev/null)" || { _trc=$?; [ "$_trc" -eq 124 ] || PAYLOAD="$(cat 2>/dev/null || echo "")"; }
else
  PAYLOAD="$(cat 2>/dev/null || echo "")"
fi

# Fast pre-filter: nothing to do unless the command mentions git or gh.
case "$PAYLOAD" in
  *git*|*gh*) ;;
  *) exit 0 ;;
esac

# Advisory: no python -> fail open (never block a pull on a degraded toolchain).
# Interpreter via lib/resolve-python.sh: `command -v` proves a name resolves, not
# that it RUNS (Windows ships a dead python3 alias stub).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh"
PY="$(resolve_python || true)"; [ -n "$PY" ] || exit 0

WG_PAYLOAD="$PAYLOAD" WG_REG="$REG" WG_STALE="$STALE" WG_LIB="$LIB_DIR" \
WG_HARDBLOCK="${HOOK_WORKTREE_HARDBLOCK:-}" "$PY" -X utf8 - <<'PY'
import os, sys, json, re, time, subprocess

# --- shared command/path parsing ---------------------------------------------
# `to_native_path` comes from lib/cmdparse.py rather than being copied in here.
# The module's own header makes the argument: two hooks each carrying their own
# copy is where drift starts, and a drifted hand-copy between sibling guards is
# the exact defect that module was written to end. Duplicating it to make this
# file "self-contained" would recreate the problem.
#
# Why the path arrives via an env var: MSYS auto-converts a path-shaped value
# passed as a STANDALONE environment variable on its way to a native binary, so
# WG_LIB lands here already in native form. A path EMBEDDED IN A STRING is not
# converted — the hook payload is JSON, so `/d/x` inside tool_input.command
# arrives verbatim, which is precisely why to_native_path is needed at all.
#
# Without that conversion this hook is blind exactly where it matters. It keeps
# working via the payload cwd, because the runtime supplies a native path there,
# and goes silent whenever a command names a repository explicitly — the
# cross-repo form, which is when parallel sessions actually collide. It would
# also skip the registry touch on that path, making such a session invisible to
# every peer's warning.
#
# === The import failure branch is LOUD, and that distinction is the point ===
# An earlier version imported this and degraded to a no-op when the import
# failed. That is fail-SILENT, not fail-open: no verdict changes, nothing errors,
# the guard simply stops seeing half its traffic and nothing says so. Fail-open
# is a decision about what to do without a verdict; fail-silent is a decision to
# hide that you had no verdict. They are separable, and only one is acceptable.
sys.path.insert(0, os.environ.get("WG_LIB", ""))
try:
    from cmdparse import to_native_path
except Exception as e:
    sys.stderr.write(
        "worktree-guard: cannot import cmdparse (%s) — path normalisation is "
        "DISABLED, so commands naming a repository explicitly will not be "
        "checked. Allowing, degraded.\n" % e
    )
    def to_native_path(p):
        return p

raw  = os.environ.get("WG_PAYLOAD", "")
reg  = os.environ.get("WG_REG", "")
try:
    stale = int(os.environ.get("WG_STALE", "1800") or "1800")
except Exception:
    stale = 1800
hardblock = os.environ.get("WG_HARDBLOCK", "").strip().lower() in ("1", "true", "yes", "on")

try:
    d = json.loads(raw) if raw.strip() else {}
except Exception:
    sys.exit(0)  # unparseable -> fail open
ti  = d.get("tool_input") or {}
cmd = ti.get("command", "") if isinstance(ti, dict) else ""
sid = (d.get("session_id") or "").strip()
cwd = (d.get("cwd") or "").strip()

if not cmd or not re.search(r'\b(git|gh)\b', cmd):
    sys.exit(0)

# Resolve the target repo dir: `git -C <dir>`, a leading `cd <dir>`, else cwd.
def resolve_target(cmd, cwd):
    m = re.search(r'-C\s+("[^"]+"|\'[^\']+\'|\S+)', cmd)
    if m:
        return m.group(1).strip("\"'")
    m = re.search(r'(?:^|&&|;|\|\|)\s*cd\s+("[^"]+"|\'[^\']+\'|[^&;|]+)', cmd)
    if m:
        return m.group(1).strip().strip("\"'")
    return cwd or "."

# Normalise AFTER resolution, so one call covers all three sources (-C, a leading
# cd, and the payload cwd).
target = to_native_path(resolve_target(cmd, cwd))

def git(*args):
    try:
        return subprocess.run(["git", "-C", target, *args],
                              capture_output=True, text=True, timeout=5)
    except Exception:
        return None

top_r = git("rev-parse", "--show-toplevel")
if not top_r or top_r.returncode != 0:
    sys.exit(0)  # not a git work tree -> fail open
top = top_r.stdout.strip()
if not top:
    sys.exit(0)

now = int(time.time())

# --- (1) touch this session's per-repo activity into the registry (advisory) ---
if sid and reg:
    def _load():
        try:
            with open(reg, "r", encoding="utf-8") as f:
                x = json.load(f)
            return x if isinstance(x, dict) else {}
        except Exception:
            return {}
    def _save(x):
        tmp = "%s.tmp.%d" % (reg, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(x, f)
            os.replace(tmp, reg)
        except Exception:
            try:
                os.remove(tmp)
            except Exception:
                pass
    rd = _load()
    rd = {k: v for k, v in rd.items()
          if isinstance(v, dict) and (now - int(v.get("heartbeat", 0) or 0)) <= stale}
    me = rd.get(sid) if isinstance(rd.get(sid), dict) else {}
    me.setdefault("started", now)
    me["cwd"] = cwd
    me["heartbeat"] = now
    repos = me.get("repos") if isinstance(me.get("repos"), dict) else {}
    repos[top] = now
    me["repos"] = repos
    rd[sid] = me
    _save(rd)

# --- (2) dirty-tree guard on tree-mutating ops --------------------------------
# Recovery sub-commands (--abort/--continue/--quit/--skip) are how you reach a
# clean tree, so never guard them.
if re.search(r'--(abort|continue|quit|skip)\b', cmd):
    sys.exit(0)

# Tolerate git global options between `git` and the subcommand:
# `git -C <dir> pull`, `git -c k=v merge`, `git --git-dir=… rebase`, etc.
# (The naive `git\s+(pull|merge)` misses the very common `git -C <dir> pull`.)
ml = re.search(r'\bgit\b(?:\s+(?:-[cC]\s+\S+|--\S+|-\w))*\s+(pull|merge|rebase)\b', cmd)
if ml:
    op = "git " + ml.group(1)
elif re.search(r'\bgh\s+pr\s+merge\b', cmd):
    op = "gh pr merge"
else:
    sys.exit(0)  # not a tree-mutating op -> allow (touch already recorded)

st = git("status", "--porcelain")
if not st or st.returncode != 0:
    sys.exit(0)  # can't evaluate -> fail open
dirty = [ln for ln in st.stdout.splitlines() if ln.strip()]
if not dirty:
    sys.exit(0)  # clean tree -> nothing to guard

br = git("rev-parse", "--abbrev-ref", "HEAD")
branch = br.stdout.strip() if (br and br.returncode == 0) else "?"
decision = "deny" if hardblock else "ask"
reason = (
    "[WORKTREE GUARD] %s on a DIRTY working tree: %d uncommitted change(s) in "
    "%s (branch '%s'). Pulling/merging/rebasing onto uncommitted work is the "
    "clobber/conflict risk this guard exists for. Resolve, then retry (the command passes "
    "once the tree is clean): commit to a feature branch -- git -C \"%s\" checkout -b "
    "feature/<thread> && git -C \"%s\" add -A && git -C \"%s\" commit -- or stash -- "
    "git -C \"%s\" stash. Override only if you are certain the uncommitted changes will "
    "not conflict."
    % (op, len(dirty), top, branch, top, top, top, top)
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }
}))
PY
