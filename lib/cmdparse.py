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
    heredoc_spans(text)               -> [(start_line, end_line_exclusive)] of heredoc bodies
    heredoc_char_spans(text)          -> the same, as character offsets
    CMD_START                         -> regex prefix matching command position
    mask_quoted(text)                 -> text with quoted CONTENTS blanked, same length
    search_cmd(verb, text)            -> re.Match for CMD_START + verb, anchored outside quotes
    at_command_position(text, verb)   -> bool; verb is a regex fragment
    scannable(cmd)                    -> strip_heredocs; the one call most guards want
    to_native_path(p)                 -> MSYS/Cygwin path -> Windows form; no-op elsewhere
    GIT_GLOBAL_WITH_ARG               -> regex: one git global option with its separate argument
    git_invocation(verb)              -> regex: `git <globals> <verb>`, globals in group 1
    git_global_args(globals_text)     -> the -C / --git-dir / --work-tree args, or None
"""
from __future__ import annotations

import os
import re

__all__ = [
    "strip_heredocs",
    "heredoc_spans",
    "heredoc_char_spans",
    "CMD_START",
    "mask_quoted",
    "search_cmd",
    "at_command_position",
    "scannable",
    "to_native_path",
    "GIT_GLOBAL_WITH_ARG",
    "git_invocation",
    "git_global_args",
]


_HEREDOC_OPEN = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def heredoc_spans(text):
    """Heredoc bodies as (start_line, end_line_exclusive) pairs.

    A span covers the body and its terminator line. The line that opens the
    heredoc is never inside a span: the command on it is real. An opener whose
    terminator never arrives runs to the end of the text.
    """
    lines = (text or "").split("\n")
    spans, i = [], 0
    while i < len(lines):
        m = _HEREDOC_OPEN.search(lines[i])
        if not m:
            i += 1
            continue
        tag = m.group(2)
        j = i + 1
        while j < len(lines) and lines[j].strip() != tag:
            j += 1
        end = min(j + 1, len(lines))
        spans.append((i + 1, end))
        i = end
    return spans


def heredoc_char_spans(text):
    """heredoc_spans as (start, end) character offsets into `text`.

    For callers that walk the text one character at a time and so cannot use
    line numbers.
    """
    text = text or ""
    starts, pos = [], 0
    for line in text.split("\n"):
        starts.append(pos)
        pos += len(line) + 1
    n = len(text)
    out = []
    for s, e in heredoc_spans(text):
        cs = starts[s] if s < len(starts) else n
        ce = starts[e] if e < len(starts) else n
        out.append((min(cs, n), min(ce, n)))
    return out


def strip_heredocs(text):
    """Drop heredoc bodies, keep the lines that open them.

    Handles `<<TAG`, `<<-TAG`, `<<'TAG'`, `<<"TAG"`. The opening line is kept
    because the command *invoking* the heredoc is real and may itself be the
    thing being guarded. Built on heredoc_spans so there is one heredoc parser
    in this module, not two.
    """
    drop = set()
    for s, e in heredoc_spans(text):
        drop.update(range(s, e))
    return "\n".join(l for i, l in enumerate((text or "").split("\n")) if i not in drop)


# Command position only.
#
# Backtick is deliberately NOT a valid prefix. A verb following a backtick is
# overwhelmingly a markdown code span in prose, and treating it as a command
# position is a reliable source of false positives in any repo whose
# documentation discusses shell commands.
CMD_START = r"(?:^|[;|&\n(]|\$\(|\bdo\b|\bthen\b|\belse\b|\{)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"


def mask_quoted(text):
    """Return `text` with the contents of quoted spans replaced by spaces.

    CMD_START is a plain regex and cannot tell whether a `;`, `&&` or `|` sits
    inside quotes. Without this, `printf '%s' 'cd x && git commit'` looks like a
    commit at command position, though it only prints a string. Searching for
    the anchor in a masked copy removes that false match.

    What is masked and what is not:
      * '...'           contents blanked; nothing in them runs.
      * "..."           contents blanked, EXCEPT $( ... ), which does run:
                        `echo "$(git commit -m x)"` makes a commit.
      * heredoc bodies  copied unchanged and not scanned for quotes, because a
                        body may contain an apostrophe, and for `git commit -F -`
                        the body is the commit message a caller wants to read.
    The quote characters themselves are kept, so argument patterns such as
    `"[^"]*"` still match across a blanked span. Newlines are kept. The result
    has the same length as the input, so offsets map one to one.
    """
    text = text or ""
    out = list(text)
    bodies = dict(heredoc_char_spans(text))
    stack = ["cmd"]
    i, n = 0, len(text)
    while i < n:
        top = stack[-1]
        if top == "cmd" and i in bodies and bodies[i] > i:
            i = bodies[i]
            continue
        c = text[i]
        if top == "sq":
            if c == "'":
                stack.pop()
            elif c != "\n":
                out[i] = " "
            i += 1
        elif top == "dq":
            if c == "\\" and i + 1 < n:
                out[i] = " "
                if text[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
            elif c == '"':
                stack.pop()
                i += 1
            elif text.startswith("$(", i):
                stack.append("cmd")
                i += 2
            else:
                if c != "\n":
                    out[i] = " "
                i += 1
        else:
            if c == "\\":
                i += 2
            elif c == "'":
                stack.append("sq")
                i += 1
            elif c == '"':
                stack.append("dq")
                i += 1
            elif c == "(":
                stack.append("cmd")
                i += 1
            elif c == ")" and len(stack) > 1:
                stack.pop()
                i += 1
            else:
                i += 1
    return "".join(out)


def search_cmd(verb_regex, text):
    """re.search(CMD_START + verb_regex, text), ignoring anchors inside quotes.

    The anchor is located in mask_quoted(text). The match returned is then taken
    from the original text at the same offset, so capture groups hold the real
    argument values rather than blanks.
    """
    text = text or ""
    pat = re.compile(CMD_START + verb_regex)
    m = pat.search(mask_quoted(text))
    if not m:
        return None
    return pat.match(text, m.start()) or m


def at_command_position(text, verb_regex):
    """True when `verb_regex` appears where a command can actually start.

    Anchoring matters independently of heredoc stripping: a verb inside a quoted
    argument on a single line survives strip_heredocs but is still not a command.
    The anchor is therefore searched for outside quotes (see search_cmd).
    """
    return search_cmd(verb_regex, text) is not None


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


# === Git global options =====================================================
# `git` accepts options between its own name and the subcommand. Some of them
# take a SEPARATE argument (`-C <path>`, `-c <name>=<value>`), and a matcher
# that only skips tokens beginning with `-` stops at that argument and never
# reaches the subcommand. So `git -C repo commit` is not seen as a commit.
#
# The list is explicit rather than "any flag plus the next token", which would
# swallow a subcommand: in `git --no-pager log`, `log` is not an argument.
_GIT_ARG = r"""(?:"[^"]*"|'[^']*'|\S+)"""
GIT_GLOBAL_WITH_ARG = (
    r"(?:-[Cc]|--(?:git-dir|work-tree|namespace|super-prefix|config-env|attr-source))"
    r"\s+" + _GIT_ARG
)
_GIT_GLOBAL_ASSIGN = r"--[A-Za-z][A-Za-z-]*=" + _GIT_ARG
_GIT_GLOBALS = (r"(?:\s+" + GIT_GLOBAL_WITH_ARG
                + r"|\s+" + _GIT_GLOBAL_ASSIGN
                + r"|\s+-[^\s]+)*")


def git_invocation(verb_regex):
    """Regex for `git <global options> <verb>`; the options are group 1.

    Meant to be passed to search_cmd, which adds the command-position anchor.
    """
    return r"git\b(" + _GIT_GLOBALS + r")\s+(?:" + verb_regex + r")\b"


# Options that change which repository git operates on. -C is applied relative
# to the directory before it; --git-dir and --work-tree are applied after every
# -C. Passing them back to git in their original order lets git apply those
# rules itself rather than this module re-implementing them.
_GIT_TARGET_TOKEN = re.compile(
    r"\s+(?:"
    r"(?P<c>-C)\s+(?P<cv>" + _GIT_ARG + r")"
    r"|(?P<l>--git-dir|--work-tree)(?:\s+|=)(?P<lv>" + _GIT_ARG + r")"
    r"|" + GIT_GLOBAL_WITH_ARG +
    r"|" + _GIT_GLOBAL_ASSIGN +
    r"|-[^\s]+"
    r")"
)


def _shell_word(word):
    """The value the shell would pass for one argument word, or None.

    None means the value depends on expansion that only the shell can perform
    (a variable, a command substitution, a glob, an escape), so it cannot be
    known here.
    """
    if len(word) >= 2 and word[0] == word[-1] == "'":
        return word[1:-1]
    if len(word) >= 2 and word[0] == word[-1] == '"':
        inner = word[1:-1]
        if any(ch in inner for ch in "$`\\"):
            return None
        return inner
    if any(ch in word for ch in "$`\\\"'*?["):
        return None
    if word.startswith("~"):
        word = os.path.expanduser(word)
    return word


def git_global_args(globals_text):
    """The repository-selecting options in `globals_text`, ready to pass to git.

    `globals_text` is group 1 of a git_invocation() match. Returns a flat list
    such as ["-C", "a", "-C", "b", "--git-dir", "c"] in the original order, with
    quotes removed and MSYS paths converted by to_native_path. Other global
    options (-c, --no-pager, ...) are dropped: they do not change which
    repository is used, and configuration values from a command string are not
    worth handing to a subprocess.

    Returns None when any of those options has a value the shell would expand,
    because the repository cannot then be known from the text.
    """
    out = []
    for m in _GIT_TARGET_TOKEN.finditer(globals_text or ""):
        if m.group("c"):
            opt, raw = "-C", m.group("cv")
        elif m.group("l"):
            opt, raw = m.group("l"), m.group("lv")
        else:
            continue
        val = _shell_word(raw)
        if val is None:
            return None
        out.extend([opt, to_native_path(val)])
    return out
