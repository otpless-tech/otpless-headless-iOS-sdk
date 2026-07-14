#!/usr/bin/env python3
"""changelog-history-guard.py

PreToolUse hook: blocks Edit/Write/MultiEdit calls that would change text
under an already-released "## <version>" heading in CHANGELOG.md. Only the
"## Unreleased" section (and adding a brand-new heading) may be touched —
released history must only be appended to, never rewritten (see the
docs-sync skill's "mark, never delete" rule).

Generic on purpose: it only assumes the "## Unreleased" / "## <version>"
top-level-heading convention (a line starting with "## ") and the literal
filename CHANGELOG.md — no repo-specific paths. Safe to reuse in any repo
using this changelog convention.

Reads the tool-call JSON on stdin (the Claude Code PreToolUse hook contract),
inspects tool_input for Edit ("old_string"), MultiEdit ("edits"), or Write
("content"), and exits 2 (blocking, with a message on stderr) if a released
section would change; exits 0 otherwise. Fails open (exit 0) on anything it
can't confidently parse — this hook is a guardrail, not the source of truth.
"""
import json
import os
import re
import sys

HEADING_RE = re.compile(r'^##\s+(.+?)\s*$', re.MULTILINE)


def split_sections(text):
    """Return [(heading_text, start_offset, end_offset), ...] for each
    top-level '## ' heading in text, in document order. end_offset is the
    start of the next heading (or len(text) for the last section)."""
    matches = list(HEADING_RE.finditer(text))
    sections = []
    for i, m in enumerate(matches):
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections.append((m.group(1).strip(), start, end))
    return sections


def is_released(heading):
    return heading.lower() != "unreleased"


def section_containing(sections, offset):
    for heading, start, end in sections:
        if start <= offset < end:
            return heading
    return None


def check_edit_against_content(before_text, old_string):
    """Block if old_string's location in before_text falls inside an
    already-released section."""
    if not old_string:
        return None
    idx = before_text.find(old_string)
    if idx == -1:
        # Can't locate it uniquely (or Edit will itself error) — fail open.
        return None
    heading = section_containing(split_sections(before_text), idx)
    if heading and is_released(heading):
        return heading
    return None


def check_write_against_content(before_text, after_text):
    """Block if any already-released section's heading+body from
    before_text no longer appears verbatim in after_text."""
    for heading, start, end in split_sections(before_text):
        if not is_released(heading):
            continue
        if before_text[start:end] not in after_text:
            return heading
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    tool_input = data.get("tool_input") or {}
    file_path = tool_input.get("file_path") or ""
    if os.path.basename(file_path) != "CHANGELOG.md":
        return 0
    if not os.path.isfile(file_path):
        return 0

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            before_text = f.read()
    except Exception:
        return 0

    violated_heading = None

    if "content" in tool_input:
        violated_heading = check_write_against_content(before_text, tool_input["content"])
    elif isinstance(tool_input.get("edits"), list):
        for edit in tool_input["edits"]:
            violated_heading = check_edit_against_content(before_text, edit.get("old_string"))
            if violated_heading:
                break
    elif "old_string" in tool_input:
        violated_heading = check_edit_against_content(before_text, tool_input["old_string"])

    if violated_heading:
        sys.stderr.write(
            "changelog-history-guard: refusing to edit already-released section "
            "'## %s' in CHANGELOG.md — released history must only be appended "
            "to, never rewritten. Add a new bullet under '## Unreleased' instead, "
            "or (if this is a genuine release-time rename) edit the still-"
            "'## Unreleased' heading before it is renamed, not after.\n" % violated_heading
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
