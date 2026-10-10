#!/usr/bin/env bash
# secrets-scan.sh — PreToolUse(Bash) hook. BLOCKS `git commit` when the commit
# would include a file whose NAME matches a secrets pattern: env files (.env,
# .env.*, but not .env.example/.sample/.template), *.key, *.pem, *.p12, *.pfx,
# *.jks, SSH private keys (id_rsa, id_dsa, id_ecdsa, id_ed25519; never *.pub),
# credentials.json and secrets.json. Matching is case-insensitive. This is a
# filename check only; it does not read file contents.
#
# === Why this is jq-free ===
# `jq` is not installed on every machine this runs on, and this hook layer is
# deliberately jq-free so the same files work on a Windows box with only Git-Bash
# as well as on macOS and Linux. A jq-based version errored and, with wiring that
# swallowed errors (`... || true`), FAILED OPEN.
#
# === Verified on a real build ===
#   * PreToolUse(Bash) delivers its payload as JSON on STDIN, command at the NESTED
#     key  .tool_input.command .  No environment variable carries it.
#   * The hook's cwd may be a workspace root that is not itself a git repo, where
#     a bare `git diff --cached` sees nothing. We resolve the target repo from
#     the command's `cd <dir>` / `git -C <dir>` and the payload cwd.
#   * Blocking goes through stdout JSON  permissionDecision:deny  (exit 0). Exit
#     code 2 would also block, but a `|| true` in the wiring swallows exit codes,
#     so stdout JSON is the channel that survives any wiring.
#
# === Posture: FAIL CLOSED ===
# A security gate must fail closed: if it cannot PROVE a commit is safe, it blocks.
#   * python-free fast pre-filter: if the RAW payload contains no "commit" substring
#     the command cannot be a git commit -> allow without touching the toolchain
#     (so a degraded toolchain never blocks unrelated Bash commands). An EMPTY
#     payload is also allowed, but says so on stderr, because "nothing to check"
#     must not look the same as "checked and clean".
#   * For any COMMIT-SHAPED payload, every "can't evaluate" branch EMITS DENY:
#     python missing, python crash (nonzero exit), a payload that is not readable
#     JSON, an unresolved target, or a `git add` in the same command that cannot
#     be parsed or simulated. The deny on those branches is printed by a
#     python-free printf, so the block fires even when python itself is the
#     broken dependency.
#   * Wiring: examples/settings.json runs this hook bare, with no `2>/dev/null`
#     and no `|| true`, so that a crash before a deny is emitted is VISIBLE.
#
# === What "the files the commit would include" means ===
# The hook is evaluated BEFORE the command runs. For `git add X && git commit`,
# the add has not happened yet, so the current index alone never shows X (#3).
# The hook therefore judges a SCRATCH COPY of the index into which it replays:
#   * every `git add` that precedes the commit in the same command, run from the
#     directory that add would run in;
#   * `git commit -a` / `--all`, as `git add -u` (tracked files only, as git does);
#   * `git commit <pathspec>` (with or without -o / -i), as `git add -u -- <paths>`.
# The scratch index is selected with GIT_INDEX_FILE, so the real index is never
# written. Replaying through git itself means the decision follows git's own
# pathspec, ignore and tracked-file rules instead of an approximation of them.
set -uo pipefail

# python-free deny emitter — works even if python is unavailable. The reason MUST
# be plain text (no double-quote / backslash / newline) so it is valid JSON as-is.
emit_deny_plain() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
}

# Read stdin; `timeout` if present (Git-Bash/Linux), plain cat on macOS (no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
  # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
  # continuing with an empty payload, which every guard would read as "allow".
  PAYLOAD=$(timeout 2 cat 2>/dev/null) || { _trc=$?; [ "$_trc" -eq 124 ] || PAYLOAD=$(cat 2>/dev/null || echo ""); }
else
  PAYLOAD=$(cat 2>/dev/null || echo "")
fi

if [ -z "$PAYLOAD" ]; then
  echo "secrets-scan: received an empty payload; nothing was checked." >&2
  exit 0
fi

# Fast pre-filter on the RAW payload. No "commit" anywhere -> cannot be a git commit
# -> allow.
case "$PAYLOAD" in
  *commit*) ;;
  *) exit 0 ;;
esac

# --- Commit-shaped from here. FAIL CLOSED on any inability to verify. ----------

# python unavailable -> block; the operator can fix the toolchain or unstage by hand.
# Interpreter via lib/resolve-python.sh: `command -v` proves a name resolves, not
# that it RUNS (Windows ships a dead python3 alias stub).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh"
PY="$(resolve_python || true)"
if [ -z "$PY" ]; then
  emit_deny_plain "secrets-scan cannot run (python3/python not found) on a commit-shaped command; blocking fail-closed. Restore python on PATH, or unstage any secret-named file (.env*, *.key, *.pem, *.p12, *.pfx, *.jks, SSH private key, credentials.json, secrets.json) and retry."
  exit 0
fi

# Parse the payload and the command. python prints one HEAD line, then zero or
# more ADD lines. Fields are separated by the ASCII unit separator (0x1f), which
# cannot appear in a shell word typed into a command.
#
#   NOTCOMMIT                    proven not a git commit -> allow
#   BADJSON                      payload is not parseable JSON -> deny
#   BADSHAPE                     JSON, but no string at .tool_input.command -> deny
#   PARSEFAIL                    a same-call add / commit pathspec could not be
#                                parsed -> deny
#   UNRESOLVED                   a commit was found but its directory depends on
#                                something only the shell can expand -> deny
#   TARGET <dir>...              directory chain the commit runs in; each later
#                                entry is relative to the one before, exactly as
#                                repeated `git -C` options are
#   ADD <n> <dir>... <argv>...   a git invocation to replay into the scratch
#                                index: n directories, then `add ...`
#
# Its exit code separates a clean run from a crash.
#
# === Why the source goes into a variable instead of straight down a pipe ===
# Stock macOS bash 3.2 cannot parse a heredoc nested inside `$( )`, and reports
# the syntax error on an EARLIER, innocent line.
#
# `read -r -d ''` takes the heredoc on a SIMPLE command, which every bash parses,
# and `-c` then hands the source to python. `read -d ''` returns non-zero when it
# hits EOF without the delimiter — which is always, here — so `|| true` is
# required.
IFS='' read -r -d '' PY_RESOLVE_TARGET <<'PY' || true
import os, re, json, shlex

SEP = "\x1f"
raw = os.environ.get("SECRETS_PAYLOAD", "")

# A payload that mentions "commit" but cannot be read might be a commit. Nothing
# can show otherwise, so it is reported for a deny rather than treated as
# "not a commit".
try:
    d = json.loads(raw)
except Exception:
    print("BADJSON"); raise SystemExit(0)
ti = d.get("tool_input") if isinstance(d, dict) else None
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str):
    print("BADSHAPE"); raise SystemExit(0)
if not ("git" in cmd and "commit" in cmd):
    print("NOTCOMMIT"); raise SystemExit(0)

cwd = d.get("cwd")
if not isinstance(cwd, str) or not cwd:
    cwd = "."


def legacy_target():
    # Used when no commit invocation can be located by the tokenizer below (for
    # example a commit inside a quoted `bash -c` string). It scans the existing
    # index of the best-guess repo, which is what this hook has always done.
    m = re.search(r'-C\s+("[^"]+"|\'[^\']+\'|\S+)', cmd)            # git -C <dir>
    if m:
        return m.group(1).strip("\"'")
    m = re.search(r'(?:^|&&|;|\|\|)\s*cd\s+("[^"]+"|\'[^\']+\'|[^&;|]+)', cmd)
    if m:
        t = m.group(1).strip().strip("\"'")
        if t:
            return t
    return cwd


PUNCT = "();<>|&\n"


def is_sep(t):
    return bool(t) and set(t) <= set(PUNCT)


def is_redirect(t):
    return bool(t) and set(t) <= set("<>&") and bool(set(t) & set("<>"))


def is_git(t):
    t = t.replace("\\", "/")
    return t == "git" or t.endswith("/git") or t.lower().endswith("git.exe")


def is_abs(p):
    return (p.startswith(("/", "\\", "~"))
            or re.match(r"^[A-Za-z]:[\\/]", p) is not None)


def extend(chain, dirs):
    # An absolute directory discards everything before it, as `cd /x` does.
    for x in dirs:
        chain = [x] if is_abs(x) else chain + [x]
    return chain


def unresolvable(chain):
    # Only the shell can expand these, and guessing would scan the wrong repo.
    for x in chain:
        if "$" in x or "`" in x or x == "-":
            return True
        if x.startswith("~") and x != "~" and not x.startswith("~/"):
            return True
    return False


# Shell keywords that may sit in front of a command in a segment.
LEADERS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "time"}


def cd_dirs(seg):
    k = 0
    while k < len(seg) and seg[k] in LEADERS:
        k += 1
    if k >= len(seg) or seg[k] not in ("cd", "pushd"):
        return None
    rest = [t for t in seg[k + 1:] if not (t.startswith("-") and t != "-")]
    return [rest[0] if rest else "~"]


def git_call(seg):
    # (dirs from -C, subcommand, args) for the first git invocation, or None.
    i = next((k for k, t in enumerate(seg) if is_git(t)), None)
    if i is None:
        return None
    dirs, j = [], i + 1
    while j < len(seg) and seg[j].startswith("-"):
        t = seg[j]
        if t == "-C":
            if j + 1 < len(seg):
                dirs.append(seg[j + 1])
            j += 2
        elif t in ("-c", "--git-dir", "--work-tree", "--namespace",
                   "--super-prefix", "--config-env"):
            j += 2
        else:
            j += 1
    if j >= len(seg):
        return None
    return dirs, seg[j], seg[j + 1:]


# Options of `git commit` whose value may be the NEXT word.
COMMIT_VALUE_SHORT = "mFCct"
COMMIT_VALUE_LONG = {"--message", "--file", "--reuse-message", "--reedit-message",
                     "--template", "--author", "--date", "--cleanup", "--fixup",
                     "--squash", "--trailer"}


def commit_stages(argv):
    # The `git add` argv lists equivalent to what the commit stages by itself,
    # or None when that cannot be determined (pathspec read from stdin).
    all_, paths, extra, k = False, [], [], 0
    while k < len(argv):
        t = argv[k]; k += 1
        if t == "--":
            paths += argv[k:]
            break
        if t == "--all":
            all_ = True
        elif t in COMMIT_VALUE_LONG:
            k += 1
        elif t.startswith("--pathspec-from-file"):
            if "=" in t:
                v = t.split("=", 1)[1]
            else:
                v = argv[k] if k < len(argv) else "-"
                k += 1
            if v == "-":
                return None
            extra.append("--pathspec-from-file=" + v)
        elif t == "--pathspec-file-nul":
            extra.append(t)
        elif t.startswith("--"):
            pass
        elif t.startswith("-") and len(t) > 1:
            for n, ch in enumerate(t[1:]):
                if ch == "a":
                    all_ = True
                if ch in COMMIT_VALUE_SHORT:
                    if not t[n + 2:]:
                        k += 1          # value is the next word
                    break               # else the rest of the cluster is the value
        else:
            paths.append(t)
    out = [["add", "-u"]] if all_ else []
    if paths or extra:
        out.append(["add", "-u"] + extra + ["--"] + paths)
    return out


# Tokenize like a shell, closely enough to find the segments. Tokens are pulled
# lazily and reading stops at the end of the commit's own segment, so text after
# it (a heredoc body, say, with an unbalanced apostrophe) is never parsed.
lex = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCT)
lex.whitespace = " \t\r"
lex.whitespace_split = True    # else `C:/x` splits at `:`

chain = [cwd]
adds = []        # (dir chain, add argv) for each `git add` seen so far
seg = []
skip = False
commit = None    # (dir chain, commit args)
parse_failed = False


def close_segment(seg):
    # Returns the commit tuple if this segment is the commit, else records any
    # cd / git add it contains and returns None.
    global chain
    call = git_call(seg)
    if call and call[1] == "commit":
        return (extend(chain, call[0]), call[2])
    cdd = cd_dirs(seg)
    if cdd is not None:
        chain = extend(chain, cdd)
    elif call and call[1] == "add":
        adds.append((extend(chain, call[0]), ["add"] + call[2]))
    return None


try:
    while True:
        tok = lex.get_token()
        if is_redirect(tok):            # drop the redirect, its fd and its target
            if seg and seg[-1].isdigit():
                seg.pop()
            skip = True
            continue
        if skip and tok is not None and not is_sep(tok):
            skip = False
            continue
        skip = False
        if tok is None or is_sep(tok):
            if seg:
                commit = close_segment(seg)
                seg = []
                if commit:
                    break
            if tok is None:
                break
            continue
        seg.append(tok)
except ValueError:
    # Unbalanced quoting. If the commit segment was already being read, judge
    # what was read of it; a command that does not parse cannot run either.
    call = git_call(seg) if seg else None
    if call and call[1] == "commit":
        commit = (extend(chain, call[0]), call[2])
    elif re.search(r"\badd\b", cmd.split("commit", 1)[0]):
        parse_failed = True

if parse_failed:
    print("PARSEFAIL"); raise SystemExit(0)

if commit is None:
    print(SEP.join(["TARGET", legacy_target()]))
    raise SystemExit(0)

target_chain, commit_args = commit
own = commit_stages(commit_args)
if own is None:
    print("PARSEFAIL"); raise SystemExit(0)
replays = adds + [(target_chain, a) for a in own]
if unresolvable(target_chain) or any(unresolvable(c) for c, _ in replays):
    print("UNRESOLVED"); raise SystemExit(0)

print(SEP.join(["TARGET"] + target_chain))
for c, argv in replays:
    print(SEP.join(["ADD", str(len(c))] + c + argv))
PY

RESULT=$(SECRETS_PAYLOAD="$PAYLOAD" "$PY" -X utf8 -c "$PY_RESOLVE_TARGET" 2>/dev/null)
PYRC=$?
RESULT=$(printf '%s' "$RESULT" | tr -d '\r')   # defend against Windows CRLF on python stdout

# python crashed on a commit-shaped command -> can't verify -> block.
if [ "$PYRC" -ne 0 ]; then
  emit_deny_plain "secrets-scan internal error parsing a commit-shaped command; blocking fail-closed."
  exit 0
fi

US=$(printf '\037')
HEAD_LINE=$(printf '%s\n' "$RESULT" | sed -n '1p')
ADD_LINES=$(printf '%s\n' "$RESULT" | sed -n '2,$p')

case "$HEAD_LINE" in
  NOTCOMMIT) exit 0 ;;                                                                 # proven not a git commit -> allow
  BADJSON)
    emit_deny_plain "secrets-scan received a payload that mentions commit but is not valid JSON, so the command cannot be checked; blocking fail-closed."
    exit 0 ;;
  BADSHAPE)
    emit_deny_plain "secrets-scan received a payload that mentions commit but has no string at tool_input.command, so the command cannot be checked; blocking fail-closed."
    exit 0 ;;
  PARSEFAIL)
    emit_deny_plain "secrets-scan could not parse what this commit-shaped command stages (a git add before the commit, or a commit pathspec read from stdin), so it cannot be scanned; blocking fail-closed. Run the git add as a separate command first."
    exit 0 ;;
  UNRESOLVED)
    emit_deny_plain "secrets-scan could not determine which directory this commit or its git add runs in (it depends on a variable, command substitution or cd -), so it cannot be scanned; blocking fail-closed. Use a literal path."
    exit 0 ;;
  "TARGET$US"*) ;;
  *)
    emit_deny_plain "secrets-scan could not resolve the target repo for a commit-shaped command; blocking fail-closed."
    exit 0 ;;
esac

# Turn a list of directories into repeated `-C` options. git applies them in
# order, each relative one relative to the one before, which is how the shell
# would have walked them. `~` is expanded here because git does not expand it.
chain_args() {
  CHAIN_ARGS=()
  local d
  for d in "$@"; do
    case "$d" in
      "~") d="$HOME" ;;
      "~/"*) d="$HOME/${d#"~/"}" ;;
    esac
    CHAIN_ARGS+=(-C "$d")
  done
}

IFS="$US" read -r -a HEAD_F <<< "$HEAD_LINE"
if [ "${#HEAD_F[@]}" -lt 2 ]; then
  emit_deny_plain "secrets-scan could not resolve the target repo for a commit-shaped command; blocking fail-closed."
  exit 0
fi
chain_args "${HEAD_F[@]:1}"

# If the target isn't a git work tree, no commit can land there (git itself rejects),
# so there's nothing to scan -> allow.
git "${CHAIN_ARGS[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Normalise to the repository root. Everything below is judged from there, and
# the add replays compare against it to tell this repo from any other.
TOP=$(git "${CHAIN_ARGS[@]}" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
if [ -z "$TOP" ]; then
  emit_deny_plain "secrets-scan could not resolve the top of the target repo for a commit-shaped command; blocking fail-closed."
  exit 0
fi

# --- replay same-call staging into a scratch index ----------------------------
SIM_INDEX=""
if [ -n "$ADD_LINES" ]; then
  REAL_INDEX=$(git -C "$TOP" rev-parse --git-path index 2>/dev/null | tr -d '\r')
  case "$REAL_INDEX" in
    ""|/*|[A-Za-z]:*) ;;                       # empty, or already absolute
    *) REAL_INDEX="$TOP/$REAL_INDEX" ;;        # relative to the -C directory
  esac
  SIM_INDEX=$(mktemp 2>/dev/null || printf '')
  if [ -z "$REAL_INDEX" ] || [ -z "$SIM_INDEX" ]; then
    [ -n "$SIM_INDEX" ] && rm -f "$SIM_INDEX"
    emit_deny_plain "secrets-scan could not create a scratch index to simulate what this command stages; blocking fail-closed. Run the git add as a separate command first."
    exit 0
  fi
  trap 'rm -f "$SIM_INDEX" "$SIM_INDEX.lock"' EXIT
  # `cp -p`, not `cp`: the copy must keep the index's mtime. git trusts a cached
  # file stat only when the file is OLDER than the index file itself; anything
  # as new or newer is "racily clean" and gets its content re-read. A plain copy
  # stamps the scratch index with the current time, which makes every entry look
  # older than it, so a same-size edit made in the same timestamp tick as the
  # last index write reads as unchanged and `add -u` skips it. If -p ever loses
  # precision, the copy gets an OLDER stamp, which only makes git re-check more.
  if [ -f "$REAL_INDEX" ]; then
    if ! cp -p "$REAL_INDEX" "$SIM_INDEX" 2>/dev/null; then
      emit_deny_plain "secrets-scan could not copy the index to simulate what this command stages; blocking fail-closed. Run the git add as a separate command first."
      exit 0
    fi
  else
    rm -f "$SIM_INDEX"        # no index yet (fresh repo): let git create one there
  fi

  while IFS="$US" read -r -a A; do
    [ "${A[0]:-}" = "ADD" ] || continue
    n="${A[1]:-0}"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt 1 ] || [ "${#A[@]}" -le $((2 + n)) ]; then
      emit_deny_plain "secrets-scan could not read a simulated git add for this commit-shaped command; blocking fail-closed."
      exit 0
    fi
    chain_args "${A[@]:2:$n}"
    ADD_TOP=$(git "${CHAIN_ARGS[@]}" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
    if [ -z "$ADD_TOP" ]; then
      emit_deny_plain "secrets-scan could not resolve the repo of a git add in this commit-shaped command; blocking fail-closed. Run the git add as a separate command first."
      exit 0
    fi
    # An add into a different repository stages nothing this commit can include.
    [ "$ADD_TOP" = "$TOP" ] || continue
    if ! GIT_INDEX_FILE="$SIM_INDEX" git "${CHAIN_ARGS[@]}" "${A[@]:$((2 + n))}" </dev/null >/dev/null 2>&1; then
      emit_deny_plain "secrets-scan could not simulate a git add in this commit-shaped command against a scratch index, so what it stages cannot be scanned; blocking fail-closed. Run the git add as a separate command first."
      exit 0
    fi
  done <<EOF
${ADD_LINES}
EOF
fi

# --- secrets scan of the files the commit would include -------------------------
# -z: names unquoted, so a path with unusual characters is matched as itself
# rather than as git's C-quoted rendering of it.
staged_names() {
  if [ -n "$SIM_INDEX" ]; then
    GIT_INDEX_FILE="$SIM_INDEX" git -C "$TOP" diff --cached --name-only -z
  else
    git -C "$TOP" diff --cached --name-only -z
  fi
}
if ! NAMES=$(staged_names 2>/dev/null | tr '\000' '\n'); then
  emit_deny_plain "secrets-scan could not list the files this commit would include; blocking fail-closed."
  exit 0
fi

# Filename patterns, matched case-insensitively against the repo-relative path.
# The first line is the original set, kept as-is so that nothing it used to catch
# is lost. The rest anchor to the file name.
SECRET_RE='\.env\.local|\.key|secrets\.json'
SECRET_RE="$SECRET_RE"'|(^|/)\.env(\.[^/]*)?$'                       # .env, .env.<anything>
SECRET_RE="$SECRET_RE"'|\.(pem|key|p12|pfx|jks)(\.[^/]*)?$'          # key and certificate stores
SECRET_RE="$SECRET_RE"'|(^|/)id_(rsa|dsa|ecdsa|ed25519)[^/]*$'       # SSH private keys
SECRET_RE="$SECRET_RE"'|credentials\.json$'
# Excluded: committed env templates, and public keys. A gate that blocks files
# people legitimately commit gets switched off.
EXCLUDE_RE='(^|/)\.env(\.[^/]*)?\.(example|sample|template)$|\.pub$'

SECRETS=$(printf '%s\n' "$NAMES" | grep -Ei "$SECRET_RE" | grep -Evi "$EXCLUDE_RE" | head -5 || true)

if [ -n "$SECRETS" ]; then
  LIST=$(printf '%s' "$SECRETS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  REASON="[SECRETS SCAN] blocked this commit. It would include file(s) whose name matches a secrets pattern (env files, *.key, *.pem, *.p12, *.pfx, *.jks, SSH private keys, credentials.json, secrets.json): ${LIST}. Move them out of the repository, add them to .gitignore, and make sure they are not staged (git -C \"${TOP}\" restore --staged <file>) before committing."
  # json.dumps for safe escaping of the file list + path. If it yields nothing,
  # fall back to a plain deny so a detected secret is NEVER allowed through.
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
    emit_deny_plain "secrets-scan detected secret-named file(s) in this commit but could not format the detail; blocking fail-closed."
  fi
  exit 0
fi

# Nothing secret-named in the commit -> allow.
exit 0
