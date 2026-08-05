"""cmdparse.py — shared shell-command parsing for PreToolUse(Bash) guards.
IMPORT it, don't run it.

=== Why this exists ===
One guard in this layer strips heredoc bodies before matching, and anchors its
verbs to command position. Its header documents why: pull-request bodies,
changelog entries and commit messages get written with
`--body "$(cat <<'EOF' ... EOF)"`, and they are full of the very commands the
guards watch for — as prose, not as commands.

A sibling guard never got either treatment. It eventually blocked a tool call
whose heredoc body contained a destructive verb **as a string being written into
a permission deny-list**. Data, not a command. It failed closed, correctly by its
own logic, on a command that did nothing of the kind.

That is a shape worth naming, because it recurs: two sibling checks, one
hardened, the other carrying a hand-copy that drifted. The fix is to derive both
from one source rather than trusting hand-sync — which is what this module is.

If you are tempted to inline these functions into a hook "to keep it
self-contained", note that you would be recreating the exact duplication this
module was written to end. Two copies is where drift starts.

=== Why a guard firing on prose is worse than it sounds ===
The false-positive rate of a prose-matching guard is driven by how often you
write *about* dangerous commands — which, in a repo whose purpose is governing
dangerous commands, is constantly.

The operator learns the guard cries wolf and reaches for the override reflexively.
At that point the guard is worse than absent, because it still *appears* to
protect the operation. A deny channel tolerates imprecision better than a
periodic report does — denials get read by construction — but not indefinitely.

=== Contract ===
    strip_heredocs(text)              -> text with heredoc BODIES removed
    CMD_START                         -> regex prefix matching command position
    at_command_position(text, verb)   -> bool; verb is a regex fragment
    scannable(cmd)                    -> strip_heredocs; the one call most guards want
    to_native_path(p)                 -> MSYS/Cygwin path -> Windows form; no-op elsewhere
"""
from __future__ import annotations

import os
import re

__all__ = [
    "strip_heredocs",
    "CMD_START",
    "at_command_position",
    "scannable",
    "to_native_path",
]


def strip_heredocs(text):
    """Drop heredoc bodies, keep the lines that open them.

    Handles `<<TAG`, `<<-TAG`, `<<'TAG'`, `<<"TAG"`. The opening line is kept
    because the command *invoking* the heredoc is real and may itself be the
    thing being guarded.
    """
    out, lines, i = [], (text or "").split("\n"), 0
    while i < len(lines):
        line = lines[i]
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        out.append(line)
        if m:
            tag = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != tag:
                i += 1      # drop the body
        i += 1
    return "\n".join(out)


# Command position only.
#
# Backtick is deliberately NOT a valid prefix. A verb following a backtick is
# overwhelmingly a markdown code span in prose, and treating it as a command
# position is a reliable source of false positives in any repo whose
# documentation discusses shell commands.
CMD_START = r"(?:^|[;|&\n(]|\$\(|\bdo\b|\bthen\b|\belse\b|\{)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"


def at_command_position(text, verb_regex):
    """True when `verb_regex` appears where a command can actually start.

    Anchoring matters independently of heredoc stripping: a verb inside a quoted
    argument on a single line survives strip_heredocs but is still not a command.
    """
    return bool(re.search(CMD_START + verb_regex, text))


def scannable(cmd):
    """The text a guard should match against: heredoc bodies removed."""
    return strip_heredocs(cmd or "")


# === MSYS path normalisation ================================================
# A guard that pulls a repository path out of COMMAND TEXT and hands it to a
# native Windows interpreter must convert it first. `git -C /d/proj/x` fails with
# `rc=128, cannot change to`; `git -C D:/proj/x` succeeds.
#
# Why this bites one guard and not its siblings is a precise boundary, worth
# stating so the next author does not have to rediscover it:
#
#   * A path-shaped value passed as a STANDALONE environment variable is
#     auto-converted by MSYS on the way to a native binary. `FOO="$SCRIPT_DIR"`
#     arrives in python already as `D:/...`, which is why an env-var-based
#     sys.path bootstrap works and needs nothing from this function.
#   * A path EMBEDDED IN A STRING is not converted. The hook payload is JSON, so
#     `/d/proj/x` sitting inside `tool_input.command` arrives verbatim.
#
# So: env-var paths are already fine; paths parsed out of the command text are
# not. Three separate guards hit this independently before it was centralised
# here, which is the argument for it living in one place.
_MSYS_DRIVE = re.compile(r"^/([A-Za-z])/(.*)$")
_CYGDRIVE = re.compile(r"^/cygdrive/([A-Za-z])/(.*)$")


def to_native_path(p):
    """Convert an MSYS/Cygwin path to Windows form. No-op off Windows.

    The platform guard is load-bearing, not defensive padding: `/d/foo` is a
    perfectly ordinary absolute path on macOS and Linux, and rewriting it to
    `D:/foo` there would invent a bug on the platforms this code is expected to
    run on. Already-native paths pass through untouched, so callers can apply
    this unconditionally.
    """
    if not p or os.name != "nt":
        return p
    m = _CYGDRIVE.match(p) or _MSYS_DRIVE.match(p)
    if m:
        return "%s:/%s" % (m.group(1).upper(), m.group(2))
    return p
