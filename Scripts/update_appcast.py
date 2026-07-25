#!/usr/bin/env python3
"""Insert (or replace) one release entry in Sparkle's appcast.xml.

Sparkle's own `generate_appcast` expects every archive to live under a single
`--download-url-prefix`, but GitHub puts each asset under its own tag path
(`/releases/download/<tag>/<file>.dmg`), so it cannot build this feed. This script does the
one thing that is actually needed: add a correctly-formed <item> for a release whose DMG has
already been signed with `sign_update`.

Entries are kept newest-first by sparkle:version. Re-running for an existing version replaces
that entry in place, so a re-release cannot leave two items claiming the same build.
"""

import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

# Placeholder swapped for a real CDATA block after serialisation. ElementTree cannot emit
# CDATA and would entity-escape the HTML, so item descriptions are held out of the tree and
# spliced back in at the end.
DESCRIPTION_TOKEN_PREFIX = "@@SPARKLE_DESCRIPTION_"
DESCRIPTION_TOKEN_SUFFIX = "@@"


def markdown_to_html(text: str) -> str:
    """Convert the small Markdown subset used in dist/*.release-notes.md to HTML.

    Sparkle renders the <description> as HTML, so raw Markdown would show its own bullet
    characters and '##' as literal text. Only the constructs actually used are handled:
    '## heading', '- bullet', and blank-line-separated paragraphs.
    """
    html: list[str] = []
    in_list = False

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            html.append("</ul>")
            in_list = False

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            close_list()
            continue
        if line.startswith("## "):
            close_list()
            html.append(f"<h2>{escape_text(line[3:].strip())}</h2>")
        elif line.startswith("# "):
            close_list()
            html.append(f"<h2>{escape_text(line[2:].strip())}</h2>")
        elif line.startswith("- "):
            if not in_list:
                html.append("<ul>")
                in_list = True
            html.append(f"<li>{escape_text(line[2:].strip())}</li>")
        else:
            close_list()
            html.append(f"<p>{escape_text(line)}</p>")

    close_list()
    return "\n".join(html)


def escape_text(text: str) -> str:
    # Escaped even though the payload sits in CDATA: a stray "]]>" in release notes would
    # otherwise terminate the section early and corrupt the feed.
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def empty_feed(title: str) -> ET.Element:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "description").text = f"Most recent updates to {title}"
    ET.SubElement(channel, "language").text = "en"
    return rss


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.short_version
    if args.minimum_system_version:
        ET.SubElement(
            item, f"{{{SPARKLE_NS}}}minimumSystemVersion"
        ).text = args.minimum_system_version
    # See DESCRIPTION_TOKEN_PREFIX: the HTML is kept out of the tree and spliced in after
    # serialisation, otherwise it renders as literal "&lt;h2&gt;" in Sparkle's notes pane.
    ET.SubElement(item, "description").text = (
        f"{DESCRIPTION_TOKEN_PREFIX}{args.version}{DESCRIPTION_TOKEN_SUFFIX}"
    )
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            f"{{{SPARKLE_NS}}}edSignature": args.signature,
            "length": str(args.length),
            "type": "application/octet-stream",
        },
    )
    return item


def version_sort_key(item: ET.Element) -> int:
    node = item.find(f"{{{SPARKLE_NS}}}version")
    try:
        return int((node.text or "0").strip())
    except (AttributeError, ValueError):
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True, help="CFBundleVersion, e.g. 2026072600")
    parser.add_argument("--short-version", required=True, help="Display version, e.g. 2026-07-26")
    parser.add_argument("--url", required=True, help="Download URL for the DMG")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature from sign_update")
    parser.add_argument("--length", required=True, help="DMG size in bytes")
    parser.add_argument("--notes", required=True, type=Path, help="Markdown release notes")
    parser.add_argument("--minimum-system-version", default="")
    parser.add_argument("--title", default="WonderWhisper")
    args = parser.parse_args()

    if not args.notes.is_file():
        print(f"ERROR: release notes not found: {args.notes}", file=sys.stderr)
        return 1
    if not str(args.version).isdigit():
        print(f"ERROR: --version must be numeric, got {args.version!r}", file=sys.stderr)
        return 1

    if args.appcast.is_file():
        tree = ET.parse(args.appcast)
        rss = tree.getroot()
        channel = rss.find("channel")
        if channel is None:
            print(f"ERROR: {args.appcast} has no <channel>", file=sys.stderr)
            return 1
    else:
        rss = empty_feed(args.title)
        channel = rss.find("channel")

    # Existing entries were parsed with their CDATA already unwrapped into plain text. Pull
    # each one back out behind a token so re-serialising cannot entity-escape previously
    # published release notes into literal "&lt;h2&gt;" markup.
    descriptions: dict[str, str] = {}
    for existing in channel.findall("item"):
        version = (existing.findtext(f"{{{SPARKLE_NS}}}version") or "").strip()
        node = existing.find("description")
        if version and node is not None and node.text:
            descriptions[version] = node.text
            node.text = f"{DESCRIPTION_TOKEN_PREFIX}{version}{DESCRIPTION_TOKEN_SUFFIX}"

    # Drop any existing entry for this exact build so a re-release replaces rather than
    # duplicates it; Sparkle would otherwise see two items with the same sparkle:version.
    for existing in channel.findall("item"):
        if (existing.findtext(f"{{{SPARKLE_NS}}}version") or "").strip() == args.version:
            channel.remove(existing)

    descriptions[args.version] = markdown_to_html(args.notes.read_text())
    channel.append(build_item(args))

    items = channel.findall("item")
    for node in items:
        channel.remove(node)
    for node in sorted(items, key=version_sort_key, reverse=True):
        channel.append(node)

    ET.indent(rss, space="  ")
    xml = ET.tostring(rss, encoding="unicode")
    for version, html in descriptions.items():
        token = f"{DESCRIPTION_TOKEN_PREFIX}{version}{DESCRIPTION_TOKEN_SUFFIX}"
        xml = xml.replace(token, f"<![CDATA[{html}]]>")
    if DESCRIPTION_TOKEN_PREFIX in xml:
        print("ERROR: unresolved description placeholder in appcast", file=sys.stderr)
        return 1
    args.appcast.write_text('<?xml version="1.0" encoding="utf-8"?>\n' + xml + "\n")
    print(f"appcast updated: {args.appcast} (version {args.version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
