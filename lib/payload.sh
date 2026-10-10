#!/usr/bin/env bash
# payload.sh — shared payload reader for Write/Edit-bound hooks. SOURCE it, don't run it.
#
# Command hooks receive their input ONLY as JSON on stdin. $CLAUDE_TOOL_INPUT is
# not part of the hook contract, so a hook reading it sees an empty string.
#
# === Contract ===
#   hook_payload            -> echoes the raw stdin JSON (empty string if none)
#   hook_file_path <json>   -> echoes .tool_input.file_path, unescaped, or ""
#
# jq-free (grep/sed only) on purpose: jq is not present everywhere these hooks run.

# Read stdin. Use `timeout` where it exists (Git Bash, Linux); fall back to plain
# `cat` on stock macOS, which does not ship a `timeout` binary.
#
# The $CLAUDE_TOOL_INPUT fallback below is a courtesy; stdin is the contract.
hook_payload() {
  local p=""
  if command -v timeout >/dev/null 2>&1; then
    # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
    # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
    # continuing with an empty payload, which every guard would read as "allow".
    p="$(timeout 2 cat 2>/dev/null)" || { _trc=$?; [ "$_trc" -eq 124 ] || p="$(cat 2>/dev/null || echo "")"; }
  else
    p="$(cat 2>/dev/null || echo "")"
  fi
  [ -n "$p" ] || p="${CLAUDE_TOOL_INPUT:-}"
  printf '%s' "$p"
}

# Extract the edited path. Matches "file_path" wherever it appears, so this works
# for the real nested payload ({"tool_input":{"file_path":...}}) and for a flat
# {"file_path":...} object alike.
#
# A Windows payload carries "C:\\project\\src\\x.py" with DOUBLED backslashes, so
# \\ -> \ , \/ -> / and \" -> " are unescaped before returning. The doubled form
# survives both `[ -f ]` and `tr '\\' '/'`, so this is not a load-bearing fix.
#
# The `([^"\\]|\\.)*` capture IS load-bearing: it stops the match from truncating
# at an escaped quote inside the value.
#
# This is not a general JSON unescaper — \uXXXX, \t, and a literal \\ immediately
# before an escaped quote are not handled. Filenames needing those are
# pathological, and Windows forbids `"` in a path outright.
hook_file_path() {
  printf '%s' "${1:-}" \
    | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
    | head -1 \
    | sed -E 's/^"file_path"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' \
    | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\\//\//g' || true
}
# The trailing `|| true` is not cosmetic. Under `set -euo pipefail` a no-match
# `grep` returns 1, `pipefail` promotes that to the pipeline's status, and
# `errexit` kills the caller ON THE ASSIGNMENT LINE, into a wrapper that discards
# exit codes. A payload with no file_path is NORMAL, so it must return empty and
# exit 0.
