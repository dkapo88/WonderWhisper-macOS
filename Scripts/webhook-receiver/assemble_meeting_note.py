#!/usr/bin/env python3
"""Put a WonderWhisper meeting note back together from its webhook parts.

A receiver that sees one request at a time (for example a bot run started per webhook
request) writes the JSON payload it received to a file and runs:

    python3 -I assemble_meeting_note.py --store <store dir> <payload.json>

The helper checks the part (end marker and ``part.sha256``), saves it under
``<store>/<sendId>/``, and once every part from 1 to ``part.total`` is there, in any arrival
order, writes the assembled note and a completion record exactly once. An unsplit payload
completes in one step. It prints one JSON line describing what happened:

    waiting           more parts are needed; "missing" lists their indexes
    complete          the note was assembled just now; "notePath" points to it
    already_complete  this send was already assembled; nothing changed
    mismatch          the part is not what was sent (truncated or copied wrongly); copy the
                      payload again and rerun
    conflict          a different part with the same index (or a different send layout) is
                      already stored; nothing changed
    invalid           not a WonderWhisper meeting note payload

For a ``meeting.note.resent`` payload whose note already has a completed earlier send, the
line also carries ``"resendOfCompleted": true`` and ``"earlierSendIds"``, so the receiver can
update what it made before instead of announcing the note again.

Python 3 standard library only. Exit status 0 for waiting, complete and already_complete;
1 otherwise.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile

SCHEMA_VERSION = 1
RESENT_EVENT = "meeting.note.resent"
OK_STATUSES = {"waiting", "complete", "already_complete"}
SEND_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,99}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
NOTE_FILE = "note.md"
COMPLETE_FILE = "complete.json"
META_FILE = "send.json"
LOCK_FILE = ".lock"


class Outcome(Exception):
    """A final status other than success, raised from deep in the checks."""

    def __init__(self, status, message, **fields):
        super().__init__(message)
        self.status = status
        self.message = message
        self.fields = fields


def end_marker(index, total):
    return f"END-OF-PAYLOAD part {index} of {total}"


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def part_file(index):
    return f"part-{index:04d}.md"


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def read_payload(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as error:
        raise Outcome("invalid", f"Could not read the payload file: {error.strerror}.")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Outcome("mismatch", "The payload file is not valid UTF-8; copy it again.")
    if text.startswith("﻿"):
        text = text[1:]
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        raise Outcome("mismatch", "The payload file is not valid JSON; copy it again.")
    return payload


def parse(payload):
    """The fields the store needs, or an Outcome for an unusable payload."""
    if not isinstance(payload, dict):
        raise Outcome("invalid", "The payload is not a JSON object.")
    note = payload.get("note")
    event = payload.get("event")
    delivery_id = payload.get("deliveryId")
    if (payload.get("schemaVersion") != SCHEMA_VERSION or not isinstance(event, str)
            or not isinstance(delivery_id, str) or not isinstance(note, dict)
            or not isinstance(note.get("id"), str) or not isinstance(note.get("markdown"), str)):
        raise Outcome("invalid", "Not a WonderWhisper meeting note payload (schemaVersion 1).")
    markdown = note["markdown"]
    try:
        markdown.encode("utf-8")
    except UnicodeEncodeError:
        # An unpaired surrogate escape, for example half of a copied emoji.
        raise Outcome("mismatch", "The note's Markdown is not valid Unicode, so it was copied "
                      "wrongly; copy the payload again.")
    part = payload.get("part")
    if part is None:
        send_id = payload.get("sendId") or delivery_id
        index, total, chunk = 1, 1, markdown
    else:
        send_id = payload.get("sendId")
        if not isinstance(part, dict) or not isinstance(send_id, str):
            raise Outcome("invalid", "A split part needs part and sendId.")
        index, total = part.get("index"), part.get("total")
        if not is_int(index) or not is_int(total) or total < 1 or not 1 <= index <= total:
            raise Outcome("invalid", "part.index and part.total are not a valid part number.")
        marker = end_marker(index, total)
        if part.get("endMarker") != marker:
            raise Outcome("invalid", "part.endMarker does not match the part number.")
        suffix = "\n\n" + marker
        if not markdown.endswith(suffix):
            raise Outcome("mismatch", "The part's Markdown does not end with its end marker, "
                          "so it was cut short or copied wrongly; copy the payload again.",
                          index=index, total=total)
        chunk = markdown[:-len(suffix)]
        expected = part.get("sha256")
        if expected is not None:
            if not isinstance(expected, str) or not SHA256.match(expected):
                raise Outcome("invalid", "part.sha256 is not a lowercase hex SHA-256.")
            if sha256_hex(chunk) != expected:
                raise Outcome("mismatch", "The part's Markdown does not match part.sha256; "
                              "copy the payload again.", index=index, total=total)
    if not isinstance(send_id, str) or not SEND_ID.match(send_id):
        raise Outcome("invalid", "sendId is not a safe identifier.")
    if not SEND_ID.match(note["id"]):
        raise Outcome("invalid", "note.id is not a safe identifier.")
    return {
        "event": event,
        "sendId": send_id,
        "deliveryId": delivery_id,
        "noteId": note["id"],
        "title": note.get("title") if isinstance(note.get("title"), str) else None,
        "index": index,
        "total": total,
        "chunk": chunk,
    }


def write_atomically(path, data):
    directory = os.path.dirname(path)
    handle = tempfile.NamedTemporaryFile(dir=directory, prefix=".tmp-", delete=False)
    try:
        with handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(handle.name, path)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def read_text(path):
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8")


def read_json(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def earlier_completed_sends(store, note_id, send_id):
    """Send IDs of other sends of this note that already completed, oldest first."""
    found = []
    try:
        names = os.listdir(store)
    except OSError:
        return found
    for name in names:
        if name == send_id or not SEND_ID.match(name):
            continue
        record = read_json(os.path.join(store, name, COMPLETE_FILE))
        if isinstance(record, dict) and record.get("noteId") == note_id:
            found.append((str(record.get("completedAt", "")), name))
    return [name for _, name in sorted(found)]


def store_part(store, part):
    send_dir = os.path.join(store, part["sendId"])
    os.makedirs(send_dir, exist_ok=True)
    with open(os.path.join(send_dir, LOCK_FILE), "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            return store_part_locked(send_dir, part)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def store_part_locked(send_dir, part):
    index, total = part["index"], part["total"]
    meta_path = os.path.join(send_dir, META_FILE)
    meta = read_json(meta_path)
    layout = {"sendId": part["sendId"], "noteId": part["noteId"], "total": total}
    if meta is None:
        meta = dict(layout, title=part["title"], firstEvent=part["event"])
        write_atomically(meta_path, (json.dumps(meta, indent=2) + "\n").encode("utf-8"))
    elif any(meta.get(key) != value for key, value in layout.items()):
        raise Outcome("conflict", "This sendId is already stored with a different note or part "
                      "total; nothing was changed.", index=index, total=total)

    path = os.path.join(send_dir, part_file(index))
    data = part["chunk"].encode("utf-8")
    duplicate = False
    if os.path.exists(path):
        with open(path, "rb") as handle:
            if handle.read() != data:
                raise Outcome("conflict", f"Part {index} is already stored with different "
                              "content; nothing was changed.", index=index, total=total)
        duplicate = True
    else:
        write_atomically(path, data)

    note_path = os.path.join(send_dir, NOTE_FILE)
    complete_path = os.path.join(send_dir, COMPLETE_FILE)
    if os.path.exists(complete_path):
        return {"status": "already_complete", "notePath": note_path, "duplicate": duplicate}
    missing = [i for i in range(1, total + 1)
               if not os.path.exists(os.path.join(send_dir, part_file(i)))]
    if missing:
        return {"status": "waiting", "missing": missing, "duplicate": duplicate}
    note = "".join(read_text(os.path.join(send_dir, part_file(i))) for i in range(1, total + 1))
    write_atomically(note_path, note.encode("utf-8"))
    record = {
        "sendId": part["sendId"],
        "noteId": part["noteId"],
        "title": meta.get("title"),
        "event": part["event"],
        "total": total,
        "noteSha256": sha256_hex(note),
        "notePath": note_path,
        "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    write_atomically(complete_path, (json.dumps(record, indent=2) + "\n").encode("utf-8"))
    return {"status": "complete", "notePath": note_path, "duplicate": duplicate}


def run(store, payload_path):
    result = {}
    try:
        part = parse(read_payload(payload_path))
        result.update(sendId=part["sendId"], noteId=part["noteId"], event=part["event"],
                      index=part["index"], total=part["total"])
        store = os.path.abspath(store)
        os.makedirs(store, exist_ok=True)
        result.update(store_part(store, part))
        if part["event"] == RESENT_EVENT:
            earlier = earlier_completed_sends(store, part["noteId"], part["sendId"])
            result["resendOfCompleted"] = bool(earlier)
            if earlier:
                result["earlierSendIds"] = earlier
    except Outcome as outcome:
        result.update(outcome.fields)
        result["status"] = outcome.status
        result["message"] = outcome.message
    except OSError as error:
        result["status"] = "invalid"
        result["message"] = f"Could not use the store: {error.strerror}."
    except (UnicodeError, ValueError) as error:
        result["status"] = "invalid"
        result["message"] = f"The payload could not be used: {type(error).__name__}."
    ordered = {"status": result.pop("status")}
    ordered.update(result)
    return ordered


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Assemble a WonderWhisper meeting note from its webhook parts.")
    parser.add_argument("--store", required=True, help="folder that keeps parts and notes")
    parser.add_argument("payload", help="file holding one webhook payload (JSON)")
    args = parser.parse_args(argv)
    result = run(args.store, args.payload)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] in OK_STATUSES else 1


if __name__ == "__main__":
    sys.exit(main())
