#!/usr/bin/env python3
"""Self-check for update_appcast.py. Run: python3 Scripts/test_update_appcast.py

Guards the two failure modes that would silently break updates for every user:
release notes rendering as escaped markup, and version ordering that strands newer builds.
"""

import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT = Path(__file__).with_name("update_appcast.py")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def add(appcast: Path, notes: Path, version: str, short: str, signature: str) -> None:
    result = subprocess.run(
        [
            sys.executable, str(SCRIPT),
            "--appcast", str(appcast),
            "--version", version,
            "--short-version", short,
            "--url", f"https://example.invalid/{short}.dmg",
            "--signature", signature,
            "--length", "1234",
            "--notes", str(notes),
            "--minimum-system-version", "15.5",
        ],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"update_appcast failed: {result.stderr}"


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        appcast = work / "appcast.xml"
        notes = work / "notes.md"
        notes.write_text("## What's new\n\n- Fixed <thing> & stuff\n- Second item\n")

        add(appcast, notes, "2026072500", "2026-07-25", "SIG_A==")
        raw = appcast.read_text()

        # Release notes must reach Sparkle as real HTML inside CDATA. If ElementTree escapes
        # them, users see literal "&lt;h2&gt;" in the update pane.
        assert "<![CDATA[" in raw, "description is not wrapped in CDATA"
        assert "<h2>What's new</h2>" in raw, "heading was not converted to HTML"
        assert "<li>Fixed &lt;thing&gt; &amp; stuff</li>" in raw, "text not escaped inside HTML"
        assert "&lt;h2&gt;" not in raw, "HTML was double-escaped"

        add(appcast, notes, "2026072600", "2026-07-26", "SIG_B==")
        # A same-day re-release must replace its entry, never duplicate it.
        add(appcast, notes, "2026072600", "2026-07-26", "SIG_B_REDONE==")

        root = ET.parse(appcast).getroot()
        items = root.find("channel").findall("item")
        assert len(items) == 2, f"expected 2 items after re-release, got {len(items)}"

        versions = [i.findtext(f"{{{SPARKLE_NS}}}version") for i in items]
        assert versions == ["2026072600", "2026072500"], f"wrong order: {versions}"

        signatures = [i.find("enclosure").get(f"{{{SPARKLE_NS}}}edSignature") for i in items]
        assert signatures[0] == "SIG_B_REDONE==", "re-release did not replace the signature"

        # The earlier entry must survive a rewrite untouched.
        assert appcast.read_text().count("<![CDATA[") == 2, "an existing description was lost"
        assert "&lt;h2&gt;" not in appcast.read_text(), "existing notes were re-escaped"

        # A same-day suffix must still sort below the next day, or later releases look older.
        add(appcast, notes, "2026080100", "2026-08-01", "SIG_C==")
        root = ET.parse(appcast).getroot()
        ordered = [i.findtext(f"{{{SPARKLE_NS}}}version") for i in root.find("channel").findall("item")]
        assert ordered[0] == "2026080100", f"newest release is not first: {ordered}"

    print("update_appcast self-check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
