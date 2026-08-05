#!/usr/bin/env bash
# fixture-root.sh — shared fixture-root allocation for the hook test suites.
# SOURCE it, don't run it.
#
# === Why this exists ===
# Several suites independently wrote `FIX="$HOOK_DIR/.<name>_test_fixtures"`,
# which puts the fixture tree INSIDE the checkout under test.
#
# In one suite that turned into a live defect. The hook it tested resolves a
# candidate repository from its payload, one of those candidates is the payload's
# `cwd`, and with the fixture root inside the checkout that resolved to the
# developer's REAL repository. The case went on to evaluate the developer's
# actual unpushed commit range.
#
# The half that matters more: when that case passed, it passed because the
# ambient range happened to be empty. It had never once exercised its own
# subject. A test that cannot reach a verdict and reports success is the same
# silent no-op these hooks are written against, one level up — and fixing only
# the visible red would have left a permanently green test checking nothing.
#
# In the other suites the leak was shielded, but shielded by ACCIDENT rather than
# design. Their targets are spoofed repositories, so the hooks' candidate loops
# match and stop before reaching `cwd`. Nothing enforced that. The next case whose
# target was not a spoofed repo would make the leak live again with no warning,
# because nobody had ever chosen the shielding.
#
# So this file exists to make the safe thing the DEFAULT rather than a per-suite
# act of discipline. Every hand-copied block is another chance to get it wrong,
# and the suite written next month starts from whichever neighbour its author
# happens to read.
#
# === Contract ===
#   fixture_root_init [slug]
#       Sets FIX in the CALLER's shell to a fresh directory outside any checkout,
#       and installs an EXIT trap that removes it. Call it once, near the top.
#
#       It sets `FIX` rather than echoing a path on purpose. `FIX="$(fixture_root)"`
#       would run the function in a subshell, where the EXIT trap it installs dies
#       with that subshell and the directory is never cleaned up. That is a real
#       trap in both senses, and the reason the API is shaped this way.
#
#   fixture_root_scope <dir_inside_repo> <fixture_root>
#       Echoes "outside" or "INSIDE-repo-under-test". Feed it to your assertion
#       helper to pin the property structurally. A comment saying "keep this
#       outside the repo" is a request; an assertion is enforcement.
#
# === Whitespace ===
# Fixture paths get embedded UNQUOTED into payload command strings in several
# suites, and hooks extract them with patterns like `-C\s+(\S+)`, so whitespace
# anywhere in the root silently truncates the path and every case misreports.
# Failing loudly beats a confusing environment-dependent red.

_hd_fixture_roots=""

_hd_fixture_cleanup() {
  local d
  for d in $_hd_fixture_roots; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fixture_root_init() { # [slug]
  local slug="${1:-fixtures}"
  FIX="$(mktemp -d 2>/dev/null || true)"
  # mktemp is absent or refuses on some minimal environments; $$ keeps concurrent
  # suites from colliding, which matters because the runner may be invoked twice.
  [ -n "$FIX" ] || FIX="${TMPDIR:-/tmp}/hookdisc_${slug}.$$"
  case "$FIX" in
    *[[:space:]]*)
      echo "FATAL: fixture root contains whitespace ('$FIX')." >&2
      echo "       Set TMPDIR to a path without spaces — unquoted fixture paths in" >&2
      echo "       payload command strings would truncate silently." >&2
      exit 1 ;;
  esac

  # === Windows: `mktemp -d` returns a path HALF the toolchain cannot use ===
  # On Git Bash, `mktemp -d` gives `/tmp/tmp.XXXX`. That form has two consumers in
  # a suite like this one, and it fails one of them:
  #
  #   * Windows Python — reached by any hook that resolves a payload path through
  #     an interpreter — typically goes through a path translation step that
  #     rewrites `/x/...` and `/cygdrive/x/...` and NOTHING ELSE. `/tmp/...`
  #     passes through untouched, `os.path.isfile()` answers False for a file
  #     that plainly exists, and the hook reports clean / no-finding on a fixture
  #     it could not see.
  #
  # The obvious fix — `cygpath -m`, giving `C:/Users/.../tmp.XXXX` — trades one
  # failure for another, and this was measured rather than guessed:
  #
  #   * bash's own PATH lookup cannot use a native-form entry. Suites that
  #     interpose executables via `PATH="$FIX/bin:$PATH"` find that with `C:/...`
  #     the shim is simply not found. In at least one suite that is not a cosmetic
  #     failure: the interposed CLI shim disappears, the REAL CLI runs, and the
  #     test issues a live mutation against a real production project board.
  #     Twelve assertions passed while doing it.
  #
  # The form that satisfies both is drive-lettered MSYS — `/C/Users/.../tmp.XXXX`.
  # bash resolves it for cd/PATH/exec, and the usual translation step converts it
  # back to `C:/...` for python. Verified in both directions.
  #
  # No-op on macOS and Linux, where cygpath is absent and the MSYS form never
  # arises. Centralised here precisely so every suite does not rediscover it —
  # the first two conversions each hit one half of it.
  if command -v cygpath >/dev/null 2>&1; then
    local _native _drive
    _native="$(cygpath -m "$FIX" 2>/dev/null || true)"
    case "$_native" in
      [A-Za-z]:/*)
        _drive="$(printf '%s' "$_native" | sed -E 's|^([A-Za-z]):/|/\1/|')"
        [ -n "$_drive" ] && FIX="$_drive" ;;
    esac
  fi

  case "$FIX" in
    *[[:space:]]*)
      echo "FATAL: fixture root contains whitespace after path normalisation ('$FIX')." >&2
      exit 1 ;;
  esac
  rm -rf "$FIX"
  mkdir -p "$FIX" || { echo "FATAL: cannot create fixture root $FIX" >&2; exit 1; }
  _hd_fixture_roots="$_hd_fixture_roots $FIX"
  trap _hd_fixture_cleanup EXIT
}

fixture_root_scope() { # <dir-inside-the-repo-under-test> <fixture-root>
  local probe="${1:-}" fix="${2:-}" top real self
  # rev-parse, not a `.git` directory test: in a worktree `.git` is a FILE, so a
  # `[ -d .git ]` walk answers "not a repo" and the assertion passes vacuously —
  # in a worktree, which is exactly where this class of bug gets found.
  top="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  if [ -z "$top" ]; then
    printf 'outside'   # not a checkout at all — nothing to leak into
    return 0
  fi
  self="$( cd "$top" 2>/dev/null && pwd -P || printf '%s' "$top" )"
  real="$( cd "$fix" 2>/dev/null && pwd -P || printf '%s' "$fix" )"
  case "$real" in
    "$self"|"$self"/*) printf 'INSIDE-repo-under-test' ;;
    *)                 printf 'outside' ;;
  esac
}
