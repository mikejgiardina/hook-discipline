#!/usr/bin/env bash
# term-scan.sh — warn when an edited file in an outward-facing path contains a
# term from a private registry.
#
# PostToolUse hook on Edit|Write. Non-blocking: prints to STDOUT only, always
# exits 0. Reads the edited path from the stdin payload via lib/payload.sh.
#
# === What ships and what does not ===
# The scanner ships. The registry does not, and that separation is the point.
# This file contains no terms; it reads them from a JSON file you supply and
# never commit. `examples/terms.example.json` shows the schema with obviously
# fictional entries so the hook and its test are runnable out of the box.
#
# Point it at your real registry with:
#   HOOK_TERM_REGISTRY=/path/to/private/terms.json
#
# === Why this is a WARNING and not a gate ===
# "Will this file be published" is a fact about a remote and a deploy pipeline.
# A write-time hook only knows a path, so a clean run is not clearance: a scoping
# filter that matches nothing is indistinguishable from a scan that found
# nothing. Put the real gate at the push or the merge that deploys, where the
# remote can actually be resolved.
#
# === Ordering: exclusions come FIRST, deliberately ===
# The `case` below excludes internal paths before it tests the outward-facing
# patterns. An internal dashboard that renders your own private vocabulary will
# hit every term in the registry, every time; warning on it is the cry-wolf
# failure that gets a check switched off entirely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$(cd "$SCRIPT_DIR/../lib" && pwd)/payload.sh"

FILE="$(hook_file_path "$(hook_payload)")"
[ -z "${FILE}" ] && exit 0
[ ! -f "${FILE}" ] && exit 0

# No interpreter is resolved anywhere in this file, and that is intentional:
# resolving one costs roughly 470ms on every write. If you ever genuinely need
# an interpreter here, resolve it BELOW the scope `case`, not above it.

# Normalise separators and case for matching.
PATH_LC="$(printf '%s' "${FILE}" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')"

case "${PATH_LC}" in
  # --- exclusions first (see header) ---------------------------------------
  */internal/*|*/private/*)
    exit 0
    ;;
  # --- outward-facing directory segments -----------------------------------
  # EDIT THIS LIST. It is a starting point, not a specification. Note that both
  # `grant/` and `grants/` are present: a singular-only pattern misses the plural.
  */public/*|*/showcase/*|*/investor/*|*/grant/*|*/grants/*|*sanitized*)
    ;;
  # --- outward-facing FILENAME markers -------------------------------------
  # Not just directory segments: covers an outward-facing `*_showcase.html`
  # written anywhere else, which carries the marker in the filename.
  *showcase*.html|*investor*.html|*public*.html)
    ;;
  *)
    exit 0
    ;;
esac

# --- registry --------------------------------------------------------------
TERMS_FILE="${HOOK_TERM_REGISTRY:-$ROOT/examples/terms.example.json}"
[ -f "${TERMS_FILE}" ] || exit 0

# Extract terms with grep/sed rather than jq — jq is not present everywhere these
# hooks run. `tr -d '\r'` defends against a registry checked out with Windows
# line endings.
#
# ALIASES ARE READ TOO: aliases are frequently the MORE likely phrasing in prose.
#
# If you run a second gate against the same registry, keep the two extractions
# byte-identical so they can never disagree about what a term is.
TERMS=$(grep -oE '"term"[[:space:]]*:[[:space:]]*"[^"]+"' "${TERMS_FILE}" \
  | sed -E 's/.*"term"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
  | tr -d '\r')
ALIASES=$(sed -n 's/.*"aliases"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "${TERMS_FILE}" \
  | grep -oE '"[^"]+"' | tr -d '"' | tr -d '\r')
TERMS=$(printf '%s\n%s\n' "${TERMS}" "${ALIASES}" | sed '/^[[:space:]]*$/d' | sort -u)

# NOTE on grep: GNU grep 3.0 as shipped with Git for Windows ABORTS (SIGABRT)
# when `-i` and `-F` are combined. The workaround is to case-fold the haystack
# and the needle separately with `tr`, then use `-F` without `-i`.
#
# "Found nothing" is only a clean result if the scan could see. A registry that
# parses but yields no terms, a file `tr` cannot read, and a term scan that
# cannot run are all announced rather than passed as clean.
cannot_scan() {
  echo ""
  echo "TERM-SCAN could not scan ${FILE} ($1). NOT a clean result."
  echo ""
  exit 0
}
[ -n "${TERMS}" ] || cannot_scan "the term registry yielded 0 terms"
FILE_LC=$(tr '[:upper:]' '[:lower:]' < "${FILE}" 2>/dev/null) \
  || cannot_scan "the file could not be read"

# ONE awk pass, not a loop per term: a per-term loop forks several processes per
# term, which on a loaded Windows box piles up into fork exhaustion. For each
# term in sorted order, the FIRST matching line of the case-folded file, as a
# fixed string, reported as `  - <term>  <n>:<line>`.
#   * Terms are case-folded with the SAME `tr` as the file, in one call, so
#     the two sides cannot fold differently.
#   * index() is a fixed-string match, which is what `grep -F` was; LC_ALL=C
#     keeps it byte-wise.
#   * Terms travel through ENVIRON, which (unlike `awk -v`) does not interpret
#     backslashes.
TERMS_LC=$(printf '%s\n' "${TERMS}" | tr '[:upper:]' '[:lower:]')
SCAN=$(printf '%s\n' "${FILE_LC}" | TS_T="${TERMS}" TS_TL="${TERMS_LC}" LC_ALL=C awk '
  BEGIN { nt = split(ENVIRON["TS_T"], t, "\n"); split(ENVIRON["TS_TL"], tl, "\n") }
  { line[NR] = $0 }
  END {
    hits = 0; out = ""
    for (i = 1; i <= nt; i++) {
      o = t[i]; l = tl[i]
      sub(/\r$/, "", o); sub(/\r$/, "", l)
      sub(/^ /, "", o);  sub(/^ /, "", l)
      sub(/ $/, "", o);  sub(/ $/, "", l)
      if (o == "") continue
      for (n = 1; n <= NR; n++) {
        if (index(line[n], l)) { out = out "\n  - " o "  " n ":" line[n]; hits++; break }
      }
    }
    printf "%d%s", hits, out
  }' 2>/dev/null)
HITS="${SCAN%%$'\n'*}"
case "${HITS}" in ''|*[!0-9]*) cannot_scan "the term scan failed to run" ;; esac
HITLIST=""
[ "${HITS}" -gt 0 ] && HITLIST=$'\n'"${SCAN#*$'\n'}"

if [ "${HITS}" -gt 0 ]; then
  # STDOUT, not stderr. A common wiring pattern sends hook stderr to /dev/null to
  # suppress noise.
  echo ""
  echo "TERM-SCAN WARNING — outward-facing file contains registry terms:"
  echo "    file: ${FILE}"
  echo "    hits: ${HITS}${HITLIST}"
  echo ""
  echo "    This is an early warning, not clearance. Review before publishing."
  echo ""
fi

exit 0
