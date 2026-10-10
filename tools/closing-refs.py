#!/usr/bin/env python3
r"""closing-refs.py -- extract issue-closing directives from a PR body / commit message.

=== Why this exists ===
A pull request merged cleanly and its description read:

    Closes core#401. Closes core#402. Closes core#403.

All three issues stayed OPEN. The control is a pull request in the same repo an
hour earlier: it wrote `Closes #404. Closes #405.` and both closed on merge.

GitHub resolves `#N` in the current repo and `owner/repo#N` cross-repo. A bare
`core#401` is neither -- it is a project's own prose shorthand for disambiguating
which of several repos an issue belongs to. It reads perfectly to a human and is
invisible to GitHub's linker. Where such a convention is *recommended* practice,
the natural way to write a PR body is the broken way.

That is the failure shape worth building a tool for: it produces a
plausible-looking success rather than an error. The PR says it closes three
issues. The merge succeeds. Nothing warns. The only way to catch it is to re-read
issue state afterwards, which is exactly the step a green signal discourages.

=== Why this is EXTRACTION ONLY, and the verification lives elsewhere ===
A retrospective sweep of several hundred merged pull requests and their
default-branch commits measured what a naive matcher costs. A
`keyword\s+prefix#\d+` proximity regex ran at roughly a 75% false-positive rate,
and the false positives were not near-misses. Three representative shapes, all
reproduced synthetically in the corpus below:

  * a PR whose body says the change does **not** close an issue. A proximity
    check closes the exact issue the author wrote a sentence to protect.
  * a heading ending "Neither underlying gap is **closed**", with the next
    paragraph opening on an issue reference. `\s+` crosses the paragraph break
    and the regex reads a closure off a PR that exists to say the issue stays
    open.
  * "Resolves the six items flagged in [core#210](...)" -- description, not
    directive, on an issue deliberately left open.

So a naive matcher is worse than no check at all: it generates confident wrong
closures, and it does so most eagerly on the issues someone took the trouble to
write a protective sentence about.

This module therefore never decides that anything should be closed. It extracts
and classifies. A caller looks up real issue state AFTER the merge and reports
only what is actually stranded. Reading state has no false-positive class at all,
because it is not guessing at intent.

=== The grammar, and why it is GitHub's rather than one of our own ===
Four rules, each earning its keep against a specific corpus member:

 1. ADJACENCY. The reference must follow the keyword with nothing but spaces
    between, which is GitHub's own grammar. Kills `Resolves the six ...
    [core#210]` -- line-initial, and a looser rule would take it.

 2. SAME LINE, enforced by iterating line by line rather than by the regex.
    Kills the paragraph-boundary bleed.

 3. For the UNPARSEABLE prefix form only, STANDALONE POSITION: the directive must
    open its line (after optional whitespace and an optional `-`, `*` or `(`
    marker) OR open a new sentence on that line, i.e. follow a `.`. Kills the
    table cell, the mid-sentence aside, the parenthetical about what ANOTHER PR
    does, and the descriptive clause.

    The sentence clause is not a loosening for its own sake -- it is the defect
    case itself, which puts all three directives on one line. A pure line-initial
    rule finds one of the three, i.e. misses the defect this file exists for.

    `.` and only `.`. `;` was tried and rejected against the corpus: a
    conventional-commit subject like `fix(parser): idle-drive the queue; resolves
    core#73's stale flag` is descriptive prose, and a semicolon would license it
    as a directive on an issue that is deliberately open.

    The rule is NOT applied to bare `#N` / `owner/repo#N`, which GitHub honours
    mid-line.

 4. NEGATION guard. `do not close`, `does not close`, `never closes`,
    `doesn't close` and friends disqualify the match.

    STATED HONESTLY about its coverage: for the PREFIX form this rule is
    shadowed by rule 3 -- a negated clause is mid-sentence, so rule 3 rejects it
    first and the negation guard never gets to matter. The corpus isolates the
    rule only through the BARE form (`... do **not** close #64 ...`), which rule
    3 deliberately exempts. That single case is what keeps the guard honest here;
    it is additionally unit-tested against the pattern directly, so that a future
    loosening of rule 3 cannot silently re-open the prefix-form class. An
    untested rule that reads as load-bearing is worse than no rule; an untested
    rule that says so is fine.

=== Two further stranding shapes, found while building the corpus ===
The prefix-shorthand defect is one way a PR can read as closing and close
nothing. Checking a corpus against GitHub's issue-timeline API turns up two more.
An auto-close carries the triggering `commit_id`; a hand-close carries
`commit_id: NONE`. That is the discriminator, and it is what a sweep should use
rather than trusting the issue's closed state.

  * LIST CONTINUATION. `Closes #120, #121.` GitHub's docs require the keyword
    before EACH issue ("Closes #10, closes #123"), so the trailing `, #121` is
    not a directive. Both issues came back `commit_id: NONE` -- hand-closed,
    minutes apart, by a person.
  * TITLE-ONLY. A PR TITLE carrying `closes #130, #131` with no closing line in
    the description. GitHub's linker reads the description and the commit
    messages, not the title. Both issues again `commit_id: NONE`, closed by hand
    at the same second.

Neither is the `prefix#N` shorthand, and neither would have been caught by a
matcher built only for it. That is the argument for verifying real state
downstream rather than trying to model GitHub's linker exactly: the model will
keep being incomplete, and a state read does not care.

Usage:
    closing-refs.py [FILE]      # reads stdin when FILE is absent
    closing-refs.py [FILE] --title    # classify as a PR title, not a body
    closing-refs.py --self-test # runs the corpus, exits 1 on any miss

The filename is hyphenated because it is a script, not an import target. A test
that needs the internals loads it with `importlib.util.spec_from_file_location`.

Output: one TSV record per directive, `kind<TAB>ref<TAB>number<TAB>line`, where
kind is one of:
    parseable        -- bare `#N`; GitHub closes it in the current repo
    crossrepo        -- `owner/repo#N`; GitHub closes it in that repo
    unparseable      -- `prefix#N`; GitHub does NOTHING. The defect.
    list-continuation-- a trailing `, #N` with no repeated keyword; GitHub
                        does nothing.
    title-only       -- found in a PR title; GitHub does nothing.
Exit 0 when directives were found, 1 when none were, 2 on a usage error. The
distinction matters to the caller: "no directives" and "could not read the input"
must not look alike.

Pure standard library on purpose. It shells out to nothing, touches no network,
and never asks GitHub anything -- so it can run inside a hook, inside CI, and
inside a test with no credentials present.
"""

import re
import sys

# GitHub's documented closing keywords, all of them.
KEYWORDS = (
    "close", "closes", "closed",
    "fix", "fixes", "fixed",
    "resolve", "resolves", "resolved",
)

# Longest-first, so the alternation cannot match `close` out of `closes` and
# leave an `s` that then fails adjacency.
_KW = "|".join(sorted(KEYWORDS, key=len, reverse=True))

# Rule 1. extract() iterates LINE BY LINE, so the line loop is rule 2 and this
# clause only enforces "no words between the keyword and the ref", which is what
# rejects `Resolves the six ... core#210`.
#
# The owner/repo alternative is tried FIRST so `example-org/example-repo#101` is
# not chopped into a bare `example-repo#101`; an alternation matches left to
# right.
_REF = r"(?:(?P<owner>[A-Za-z0-9][A-Za-z0-9._-]*)/(?P<repo>[A-Za-z0-9][A-Za-z0-9._-]*)|(?P<prefix>[A-Za-z][A-Za-z0-9._-]*))?#(?P<num>\d+)"
_DIRECTIVE = re.compile(r"(?<![A-Za-z0-9_])(?P<kw>%s)[ \t]*%s" % (_KW, _REF), re.IGNORECASE)

# Rule 3: an unparseable directive must OPEN its line. A leading list marker or
# open paren is allowed: `- Closes core#150` and `(closes api#151)` are both
# standalone directives.
_LINE_INITIAL = re.compile(r"^[ \t]*(?:[-*]\s*|\(\s*)?(?:%s)[ \t]*\S" % _KW, re.IGNORECASE)

# Rule 4. Bounded to the text BEFORE the keyword on that line, so a later
# sentence containing "not" cannot disqualify an earlier real directive.
_NEGATION = re.compile(
    r"(?:\b(?:do|does|did|will|would|shall|should|can|could|must|may)\s+not\b"
    r"|\b(?:don|doesn|didn|won|wouldn|shan|shouldn|can|couldn|mustn)'?t\b"
    r"|\bnever\b|\bnot\b)\s*(?:\*{1,2})?\s*$",
    re.IGNORECASE,
)


def _strip_markdown_noise(line):
    """Remove emphasis markers so `**core#31**` and `core#31` classify alike.

    Only `*` and `_` runs are dropped. Deliberately NOT link syntax: a reference
    inside `[core#210](url)` is a citation, not a directive, and the bracket is
    the signal that distinguishes them. Erasing it would resurrect the
    descriptive-clause false positive by a different route.
    """
    return re.sub(r"[*_]{1,3}", "", line)


# A continuation reference: `Closes #120, #121` / `Fixes #1 and #2`. GitHub does
# NOT close the trailing ones. Extracted anyway, and flagged, so the
# verification layer can check them.
_CONT_REF = re.compile(r"^[ \t]*(?:,|and\b|&)[ \t]*%s" % _REF)


def _classify(owner, repo, prefix, num):
    if owner and repo:
        return "crossrepo", "%s/%s#%s" % (owner, repo, num)
    if prefix:
        return "unparseable", "%s#%s" % (prefix, num)
    return "parseable", "#%s" % num


def extract(text, source="body"):
    """Return a list of dicts, one per closing directive that survives the rules.

    Each dict: {kind, ref, number, keyword, line, lineno, source}.

    `source` is "body" (a PR description or commit message -- where GitHub's
    linker actually looks) or "title". Directives found in a title are downgraded
    to kind "title-only", because GitHub does not act on a PR title at all.
    Evidence rather than doctrine: on a PR whose title carried two closing
    references and whose description carried none, BOTH issues showed
    `commit_id: NONE` on their close events -- hand-closed, minutes apart, by a
    person. The platform did nothing.
    """
    out = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _strip_markdown_noise(raw)

        # Rule 3, computed ONCE per line and as a POSITION, not a boolean: in
        # `fix(parser): ...; resolves core#73's flag` the `fix(` satisfies "line
        # starts with a keyword", so the match must BE the line-initial one.
        li = _LINE_INITIAL.match(line)
        li_start = None
        if li:
            m0 = re.match(r"^[ \t]*(?:[-*]\s*|\(\s*)?", line)
            li_start = m0.end() if m0 else 0

        for m in _DIRECTIVE.finditer(line):
            num = m.group("num")
            owner, repo, prefix = m.group("owner"), m.group("repo"), m.group("prefix")

            # Rule 4 -- negation immediately preceding the keyword.
            if _NEGATION.search(line[: m.start("kw")]):
                continue

            kind, ref = _classify(owner, repo, prefix, num)

            # Rule 3 -- standalone-directive position (line-initial OR after a
            # `.`), for the unparseable form ONLY; see the module docstring.
            # `(` is not a separator: `Companion to <other PR> (closes core#87)`
            # is about what ANOTHER pull request does.
            if kind == "unparseable":
                before = line[: m.start("kw")].rstrip()
                if m.start("kw") != li_start and not before.endswith("."):
                    continue

            def _add(k, r, n):
                out.append({
                    "kind": "title-only" if source == "title" else k,
                    "ref": r,
                    "number": int(n),
                    "keyword": m.group("kw"),
                    "line": raw.strip(),
                    "lineno": lineno,
                    "source": source,
                })

            _add(kind, ref, num)

            # Trailing `, #N` / ` and #N` refs. GitHub drops these; we keep them
            # so the verification layer can notice they never closed.
            pos = m.end()
            while True:
                cm = _CONT_REF.match(line[pos:])
                if not cm:
                    break
                c_kind, c_ref = _classify(cm.group("owner"), cm.group("repo"),
                                          cm.group("prefix"), cm.group("num"))
                out.append({
                    "kind": "title-only" if source == "title" else "list-continuation",
                    "ref": c_ref,
                    "number": int(cm.group("num")),
                    "keyword": m.group("kw"),
                    "line": raw.strip(),
                    "lineno": lineno,
                    "source": source,
                    "base_kind": c_kind,
                })
                pos += cm.end()
    return out


# --------------------------------------------------------------------------
# Corpus. Every entry reproduces the SHAPE of a site a naive proximity matcher
# hit, with synthetic content.
#
# `want` lists the (kind, ref) pairs that MUST be extracted; anything else
# extracted is a false positive and fails the run.
#
# The case name records which rule it defends. Each of rules 1-4 has at least
# one case that goes red when that rule alone is removed.
# --------------------------------------------------------------------------
CORPUS = [
    (
        "R3+ the defect: three prefix directives on ONE line, none parseable",
        "Closes core#101. Closes core#102. Closes core#103.\n",
        [("unparseable", "core#101"), ("unparseable", "core#102"), ("unparseable", "core#103")],
    ),
    (
        "R1  line-initial keyword, words before the ref (adjacency)",
        'Resolves the four "minor discrepancy" items flagged in the '
        "[core#210](https://github.com/example-org/example-repo/issues/210) review round:\n",
        [],
    ),
    (
        "R2  sentence-boundary bleed across a paragraph break",
        "## Neither underlying gap is closed\n"
        "\n"
        "core#31's queue shortfall and core#32's over-correction both remain **open**.\n",
        [],
    ),
    (
        "R3  inside a markdown table cell",
        "| a skip marker on branch commits disabled the only run | api#61 -> closed core#77 |\n",
        [],
    ),
    (
        "R3  mid-sentence, past tense, describing another pull request",
        "Session notes for the core#70 review (see PR #71, closed core#70, "
        "filed core#72 + api#74).\n",
        [],
    ),
    (
        "R3  parenthetical describing what ANOTHER pull request does",
        "Companion to **example-org/example-repo#88** (closes core#87). "
        "The enforcement lands there; this is the decision record.\n",
        [],
    ),
    (
        "R3  semicolon clause -- `;` is not a sentence separator, and `fix(` is "
        "not a directive",
        "fix(parser): idle-drive the queue; resolves core#73's stale flag\n",
        [],
    ),
    (
        "R3  indented continuation line, parenthesised mid-line",
        "                  cannot represent (closes core#26)\n",
        [],
    ),
    (
        "R3  descriptive clause, mid-line, no sentence boundary before it",
        "    the queue depth, above the idle default, which is why no bound "
        "SHAPE fixes core#52\n",
        [],
    ),
    (
        "R1  'closes out' -- a word between keyword and ref, inside a bullet",
        "- This closes out core#73's last open flag - the guard was already fixed by #180.\n",
        [],
    ),
    (
        "R4  EXPLICIT NEGATION on a BARE ref, which rule 3 exempts",
        # The only corpus case that isolates the negation guard: a bare `#N` is
        # exempt from rule 3.
        "These changes do **not** close #64, which stays open pending review.\n",
        [],
    ),
    (
        "--  non-closing verbs are not keywords, and both issues stay open",
        "Advances #58 (the retry path now backs off). Addresses the second half of #59.\n",
        [],
    ),
    (
        "--  LIST CONTINUATION: `Closes #120, #121.` closes only the first",
        # GitHub's docs require the keyword before EACH issue ("Closes #10,
        # closes #123"), so a trailing `, #121` is not a directive to the linker.
        "Closes #120, #121.\n",
        [("parseable", "#120"), ("list-continuation", "#121")],
    ),
    (
        "--  a closing keyword in a PR TITLE does nothing at all",
        # GitHub's linker reads the PR DESCRIPTION and the commit messages -- not
        # the title. Both refs are reported, and both are downgraded.
        "Live queue visualization for the worker pool - closes #130, #131\n",
        [("title-only", "#130"), ("title-only", "#131")],
    ),
    # --- controls: the forms that MUST keep working -------------------------
    (
        "--  control: the bare form that works today, two on one line",
        "Closes #110. Closes #111.\n",
        [("parseable", "#110"), ("parseable", "#111")],
    ),
    (
        "--  control: cross-repo form, which GitHub also honours",
        "Closes example-org/example-repo#140\n",
        [("crossrepo", "example-org/example-repo#140")],
    ),
    (
        "--  control: every GitHub keyword, prefix form, one per line",
        "\n".join("%s api#%d" % (k, i) for i, k in enumerate(KEYWORDS, 1)) + "\n",
        [("unparseable", "api#%d" % i) for i in range(1, len(KEYWORDS) + 1)],
    ),
    (
        "--  control: list-marker and paren directives are still directives",
        "- Closes core#150\n(closes api#151)\n",
        [("unparseable", "core#150"), ("unparseable", "api#151")],
    ),
    (
        "--  control: cross-repo refs are NOT downgraded to the bare prefix form",
        "Fixes example-org/tooling-config#42\n",
        [("crossrepo", "example-org/tooling-config#42")],
    ),
]


def self_test():
    failures = 0
    naive = re.compile(r"(?:%s)\s+(?:[A-Za-z][A-Za-z0-9._-]*)#\d+" % _KW, re.IGNORECASE)
    naive_hits = 0
    for name, text, want in CORPUS:
        src = "title" if " TITLE " in name or " title " in name else "body"
        got = [(d["kind"], d["ref"]) for d in extract(text, source=src)]
        naive_hits += len(naive.findall(text))
        if got == want:
            print("  PASS  %s" % name)
        else:
            failures += 1
            print("  FAIL  %s" % name)
            print("        want: %r" % (want,))
            print("        got:  %r" % (got,))
    # The corpus over-represents the controls -- real directives a naive
    # matcher also hits -- so this ratio is kinder than the sweep's ~75%.
    real = sum(1 for _, t, _ in CORPUS for d in extract(t) if d["kind"] == "unparseable")
    print()
    print("  naive `keyword\\s+prefix#N` matcher would hit %d site(s) on this corpus;"
          % naive_hits)
    print("  this matcher reports %d unparseable directive(s)." % real)
    return failures


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        print("closing-refs.py self-test -- the closing-directive corpus")
        failures = self_test()
        print()
        if failures:
            print("FAILED: %d case(s)" % failures)
            return 1
        print("ALL PASS")
        return 0

    args = [a for a in argv[1:] if a != "--title"]
    source = "title" if "--title" in argv[1:] else "body"
    if len(args) > 1:
        sys.stderr.write("usage: closing-refs.py [FILE] [--title] | --self-test\n")
        return 2

    try:
        if args:
            with open(args[0], encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        else:
            text = sys.stdin.read()
    except OSError as exc:
        sys.stderr.write("closing-refs: could not read input: %s\n" % exc)
        return 2

    found = extract(text, source=source)
    for d in found:
        print("%s\t%s\t%d\t%s" % (d["kind"], d["ref"], d["number"], d["line"]))
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
