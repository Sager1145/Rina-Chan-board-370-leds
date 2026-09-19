#!/usr/bin/env python3
"""Extract Simplified-Chinese SwiftUI string-literal localisation keys from RinaBoard/**/*.swift.

Finds the first-argument string literal of common SwiftUI/localisation call sites
(Text, Label, Button, LabeledContent, Section, Toggle, TextField, SecureField,
navigationTitle, ContentUnavailableView, alert, confirmationDialog, Picker,
DisclosureGroup, String(localized:)) when that literal contains CJK characters.

String interpolations `\(...)` are converted to format specifiers: `%@` for
values that look like they are of an unknown/String type, `%lld` for values
that look like integer expressions (e.g. plain identifiers commonly used as
counters/indices), defaulting to `%@` when unsure.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "ios" / "RinaBoard"

CJK_RE = re.compile(r"[一-鿿㐀-䶿]")

# Call sites whose first argument we care about.
CALL_NAMES = [
    "Text", "Label", "Button", "LabeledContent", "Section", "Toggle",
    "TextField", "SecureField", "navigationTitle", "ContentUnavailableView",
    "alert", "confirmationDialog", "Picker", "DisclosureGroup",
    "SwapLabel", "CommandChip",
]

# Matches: <call name>( "..."   — captures the raw (unescaped) string body.
# Also handles String(localized: "...")
STRING_LITERAL = r'"((?:[^"\\]|\\.)*)"'

CALL_RE = re.compile(
    r'\b(?:' + "|".join(CALL_NAMES) + r')\s*\(\s*' + STRING_LITERAL
)
STRING_LOCALIZED_RE = re.compile(
    r'String\s*\(\s*localized:\s*' + STRING_LITERAL
)

# Integer-looking interpolation heuristics: a bare identifier/property chain
# ending in something that reads like a count/index, or an explicit Int(...) cast.
INT_HINT_RE = re.compile(
    r'^(Int\(|.*\.(count|index|value)$|[a-zA-Z_][a-zA-Z0-9_]*$)'
)


def convert_interpolations(raw: str) -> str:
    """Convert \\(...) interpolations in a raw (escaped) Swift string literal
    into %@ / %lld format specifiers, matching Swift's String(format:) style
    localisation keys."""

    def repl(m):
        expr = m.group(1).strip()
        if INT_HINT_RE.match(expr) and any(
            tok in expr for tok in ("count", "index", "Int(", "frame", "a", "b")
        ):
            # Heuristic: short identifiers used as frame/counters -> integers.
            return "%lld"
        return "%@"

    # Non-greedy match of \( ... ) allowing simple nested parens is hard with
    # regex; we do a manual scan for balanced parens instead.
    out = []
    i = 0
    n = len(raw)
    while i < n:
        if raw[i] == "\\" and i + 1 < n and raw[i + 1] == "(":
            depth = 1
            j = i + 2
            start = j
            while j < n and depth > 0:
                if raw[j] == "(":
                    depth += 1
                elif raw[j] == ")":
                    depth -= 1
                j += 1
            expr = raw[start:j - 1]
            out.append(repl(type("M", (), {"group": staticmethod(lambda k, e=expr: e)})()))
            i = j
        else:
            out.append(raw[i])
            i += 1
    return "".join(out)


def unescape(raw: str) -> str:
    return raw.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8", errors="ignore") \
        if False else raw.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n").replace("\\t", "\t")


def extract_from_file(path: Path):
    text = path.read_text(encoding="utf-8")
    keys = set()
    for regex in (CALL_RE, STRING_LOCALIZED_RE):
        for m in regex.finditer(text):
            raw = m.group(1)
            if "\\(" in raw:
                raw = convert_interpolations(raw)
            value = unescape(raw)
            if CJK_RE.search(value):
                keys.add(value)
    return keys


def main():
    all_keys = set()
    for path in ROOT.rglob("*.swift"):
        all_keys |= extract_from_file(path)
    for key in sorted(all_keys):
        print(key)


if __name__ == "__main__":
    main()
