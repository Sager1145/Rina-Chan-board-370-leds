#!/usr/bin/env python3
"""Count XCTest and Swift Testing bodies without accepting skipped-only runs."""
import re
import sys
from pathlib import Path


def counts(text):
    executed = skipped = failures = 0
    summaries = re.findall(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", text)
    if summaries:
        count, skip, fail = summaries[-1]
        executed += int(count)
        skipped += int(skip or 0)
        failures += int(fail)
    swift = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed) after", text)
    if swift:
        count, result = swift[-1]
        executed += int(count)
        skipped += len(re.findall(r"^.*\bTest (?!Case\b).+ skipped(?:\.| |$)", text, re.MULTILINE))
        failures += int(result == "failed")
    return (executed, skipped, failures) if summaries or swift else None


if __name__ == "__main__":
    result = counts(Path(sys.argv[1]).read_text(errors="replace"))
    if result is not None:
        print(*result)
