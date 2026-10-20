#!/usr/bin/env python3
"""snapshot-label.py validate VALUE | read SNAPSHOT...: snapshot names.

Lanai's one rule for the optional name (label) a snapshot gets when it is
taken (docs/plugin/snapshot-names/spec.md). The UTC folder name stays the
snapshot's identifier; a label is display data only.

validate prints one JSON object: {"ok": true, "label": string|null} for a
valid or empty label (only U+0020 is trimmed, at both edges), or
{"ok": false, "reason": "invalid-label", "rule": key, "message": text}.
An invalid label is a normal reply (exit 0); only a helper fault exits
nonzero.

read prints one JSON array with each snapshot folder's saved label, or null
when its LABEL is missing, not a regular file, a symlink, longer than 257
bytes, or does not hold one valid label line. It never blocks on a named
pipe and never invalidates the snapshot itself.
"""

import json
import os
import stat
import sys
import unicodedata

MAX_CHARS = 64
MAX_BYTES = 257  # 64 four-byte characters and one newline

# Checked in this order; the first rule a label breaks is its reply.
MESSAGES = {
    "invalid-utf8": "Use valid UTF-8 text.",
    "line-break": "Use one line.",
    "angle-bracket": "Remove < and >.",
    "separator": "Use ordinary spaces between words.",
    "invisible": "Remove unsupported invisible characters. Some emoji contain them.",
    "unsupported-character": "Remove unsupported control or special characters.",
    "too-long": "Use 64 characters or fewer.",
}


def rule_of(char):
    """Return the character rule <char> breaks, or None."""
    if char in "\r\n\u2028\u2029":
        return "line-break"
    if char in "<>":
        return "angle-bracket"
    category = unicodedata.category(char)
    if category.startswith("Z") and char != " ":
        return "separator"
    if category == "Cf":
        return "invisible"
    if category.startswith("C"):
        return "unsupported-character"
    return None


def broken_rule(text):
    """Return the first rule a trimmed, nonempty label breaks, or None."""
    found = {rule_of(ch) for ch in text}
    if len(text) > MAX_CHARS:
        found.add("too-long")
    return next((rule for rule in MESSAGES if rule in found), None)


def validate(value):
    # Recover the exact argv bytes under any locale, then decode them strictly
    # as UTF-8 ourselves, so invalid bytes have their own rule, checked first.
    try:
        text = os.fsencode(value).decode("utf-8").strip(" ")
    except UnicodeDecodeError:
        rule = "invalid-utf8"
        return {"ok": False, "reason": "invalid-label", "rule": rule, "message": MESSAGES[rule]}
    if not text:
        return {"ok": True, "label": None}
    rule = broken_rule(text)
    if rule:
        return {"ok": False, "reason": "invalid-label", "rule": rule, "message": MESSAGES[rule]}
    return {"ok": True, "label": text}


def read_label(snapshot):
    """Return <snapshot>/LABEL's label, or None when it is not readable."""
    try:
        fd = os.open(os.path.join(snapshot, "LABEL"),
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        data = b""
        while len(data) <= MAX_BYTES:
            chunk = os.read(fd, MAX_BYTES + 1 - len(data))
            if not chunk:
                break
            data += chunk
    except OSError:
        return None
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        return None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if text.endswith("\n"):
        text = text[:-1]
    if not text or text != text.strip(" ") or broken_rule(text):
        return None
    return text


def main(args):
    if len(args) == 2 and args[0] == "validate":
        print(json.dumps(validate(args[1])))
    elif args and args[0] == "read":
        print(json.dumps([read_label(path) for path in args[1:]]))
    else:
        print("usage: snapshot-label.py validate VALUE | read SNAPSHOT...", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
