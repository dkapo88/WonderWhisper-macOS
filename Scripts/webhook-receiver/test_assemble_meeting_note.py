"""Tests for assemble_meeting_note.py.

Run: python3 -m unittest discover -s Scripts/webhook-receiver
"""

import hashlib
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assemble_meeting_note as helper  # noqa: E402

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble_meeting_note.py")
NOTE_ID = "11111111-2222-3333-4444-555555555555"


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def split_payloads(chunks, send_id=None, event="meeting.note.completed", note_id=NOTE_ID,
                   with_sha=True):
    """Payloads shaped like WonderWhisper's split parts (keys in the app's order)."""
    send_id = send_id or str(uuid.uuid4()).upper()
    total = len(chunks)
    payloads = []
    for offset, chunk in enumerate(chunks):
        index = offset + 1
        marker = f"END-OF-PAYLOAD part {index} of {total}"
        part = {"index": index, "total": total, "endMarker": marker}
        if with_sha:
            part["sha256"] = sha256(chunk)
        payloads.append({
            "event": event,
            "schemaVersion": 1,
            "deliveryId": str(uuid.uuid4()).upper(),
            "sendId": send_id,
            "sentAt": "2026-11-03T10:00:00Z",
            "app": {"name": "WonderWhisper", "version": "test", "build": "1"},
            "part": part,
            "note": {"id": note_id, "title": "Planning", "markdown": chunk + "\n\n" + marker},
        })
    return payloads


def unsplit_payload(markdown, event="meeting.note.completed", note_id=NOTE_ID):
    return {
        "event": event,
        "schemaVersion": 1,
        "deliveryId": str(uuid.uuid4()).upper(),
        "sentAt": "2026-11-03T10:00:00Z",
        "app": {"name": "WonderWhisper", "version": "test", "build": "1"},
        "note": {"id": note_id, "title": "Planning", "markdown": markdown},
    }


CHUNKS = ["# Planning\n\n## Summary\n\n- One ", "two “three” 😀\r\n", "## Transcript\n\nMe: hi\n",
          "Them: bye"]
NOTE = "".join(CHUNKS)


class AssembleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = os.path.join(self.temp.name, "store")
        self.inbox = os.path.join(self.temp.name, "inbox")
        os.makedirs(self.inbox)

    def tearDown(self):
        self.temp.cleanup()

    def deliver(self, payload, raw=None):
        path = os.path.join(self.inbox, f"{uuid.uuid4()}.json")
        with open(path, "wb") as handle:
            handle.write(raw if raw is not None else json.dumps(payload).encode("utf-8"))
        return helper.run(self.store, path)

    def snapshot(self):
        """Every file under the store with its bytes (lock files excluded)."""
        files = {}
        for root, _, names in os.walk(self.store):
            for name in names:
                if name == helper.LOCK_FILE:
                    continue
                path = os.path.join(root, name)
                with open(path, "rb") as handle:
                    files[os.path.relpath(path, self.store)] = handle.read()
        return files

    def read_note(self, result):
        with open(result["notePath"], "rb") as handle:
            return handle.read().decode("utf-8")

    def test_arrival_in_any_order(self):
        for seed in range(5):
            payloads = split_payloads(CHUNKS)
            order = list(range(len(payloads)))
            random.Random(seed).shuffle(order)
            results = [self.deliver(payloads[i]) for i in order]
            self.assertEqual([r["status"] for r in results],
                             ["waiting"] * (len(order) - 1) + ["complete"])
            self.assertEqual(self.read_note(results[-1]), NOTE)

    def test_last_index_first(self):
        payloads = split_payloads(CHUNKS)
        first = self.deliver(payloads[-1])
        self.assertEqual(first["status"], "waiting")
        self.assertEqual(first["missing"], [1, 2, 3])
        for payload in payloads[:-1]:
            result = self.deliver(payload)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(self.read_note(result), NOTE)

    def test_identical_duplicate_is_harmless(self):
        payloads = split_payloads(CHUNKS)
        self.deliver(payloads[0])
        again = self.deliver(payloads[0])
        self.assertEqual(again["status"], "waiting")
        self.assertTrue(again["duplicate"])
        for payload in payloads[1:]:
            result = self.deliver(payload)
        self.assertEqual(result["status"], "complete")
        before = self.snapshot()
        late = self.deliver(payloads[2])
        self.assertEqual(late["status"], "already_complete")
        self.assertEqual(self.snapshot(), before)

    def test_conflicting_duplicate_changes_nothing(self):
        payloads = split_payloads(CHUNKS)
        self.deliver(payloads[1])
        before = self.snapshot()
        other = split_payloads(["x", "different", "y", "z"], send_id=payloads[0]["sendId"])
        result = self.deliver(other[1])
        self.assertEqual(result["status"], "conflict")
        self.assertEqual(result["index"], 2)
        self.assertEqual(self.snapshot(), before)

    def test_a_different_total_for_the_same_send_is_a_conflict(self):
        payloads = split_payloads(CHUNKS)
        self.deliver(payloads[0])
        before = self.snapshot()
        other = split_payloads(["a", "b"], send_id=payloads[0]["sendId"])
        self.assertEqual(self.deliver(other[1])["status"], "conflict")
        self.assertEqual(self.snapshot(), before)

    def test_missing_middle_part_then_late_arrival(self):
        payloads = split_payloads(CHUNKS)
        for payload in payloads[:1] + payloads[2:]:
            result = self.deliver(payload)
        self.assertEqual(result["status"], "waiting")
        self.assertEqual(result["missing"], [2])
        late = self.deliver(payloads[1])
        self.assertEqual(late["status"], "complete")
        self.assertEqual(self.read_note(late), NOTE)

    def test_checksum_mismatch_stores_nothing(self):
        payload = split_payloads(CHUNKS)[1]
        payload["note"]["markdown"] = payload["note"]["markdown"].replace("three", "thre")
        result = self.deliver(payload)
        self.assertEqual(result["status"], "mismatch")
        self.assertIn("copy the payload again", result["message"])
        self.assertEqual(self.snapshot(), {})

    def test_a_cut_part_is_a_mismatch(self):
        payload = split_payloads(CHUNKS)[0]
        payload["note"]["markdown"] = payload["note"]["markdown"][:-5]
        self.assertEqual(self.deliver(payload)["status"], "mismatch")
        self.assertEqual(self.deliver(None, raw=b'{"event": "meeting.note')["status"],
                         "mismatch")

    def test_parts_without_a_checksum_still_assemble(self):
        for payload in split_payloads(CHUNKS, with_sha=False):
            result = self.deliver(payload)
        self.assertEqual(result["status"], "complete")

    def test_unsplit_payload_completes_in_one_step(self):
        result = self.deliver(unsplit_payload(NOTE))
        self.assertEqual(result["status"], "complete")
        self.assertEqual((result["index"], result["total"]), (1, 1))
        self.assertEqual(self.read_note(result), NOTE)

    def test_invalid_payloads(self):
        self.assertEqual(self.deliver({"hello": "world"})["status"], "invalid")
        self.assertEqual(self.deliver([1, 2])["status"], "invalid")
        payload = split_payloads(CHUNKS)[0]
        payload["sendId"] = "../escape"
        self.assertEqual(self.deliver(payload)["status"], "invalid")
        payload = split_payloads(CHUNKS)[0]
        payload["part"]["index"] = 9
        self.assertEqual(self.deliver(payload)["status"], "invalid")
        self.assertEqual(self.snapshot(), {})

    def test_two_runs_finishing_at_the_same_moment_complete_once(self):
        for _ in range(5):
            payloads = split_payloads(CHUNKS)
            for payload in payloads[:-1]:
                self.deliver(payload)
            paths = []
            for _ in range(2):
                path = os.path.join(self.inbox, f"{uuid.uuid4()}.json")
                with open(path, "w", encoding="utf-8") as handle:
                    json.dump(payloads[-1], handle)
                paths.append(path)
            runs = [subprocess.Popen([sys.executable, "-I", HELPER, "--store", self.store, p],
                                     stdout=subprocess.PIPE) for p in paths]
            statuses = sorted(json.loads(run.communicate()[0])["status"] for run in runs)
            self.assertEqual(statuses, ["already_complete", "complete"])

    def test_resent_after_completion(self):
        first = split_payloads(CHUNKS)
        for payload in first:
            done = self.deliver(payload)
        self.assertEqual(done["status"], "complete")
        self.assertNotIn("resendOfCompleted", done)

        # Resend Parts reuses the send: nothing changes.
        before = self.snapshot()
        partial = split_payloads(CHUNKS, send_id=first[0]["sendId"], event="meeting.note.resent")
        result = self.deliver(partial[1])
        self.assertEqual(result["status"], "already_complete")
        self.assertEqual(self.snapshot(), before)

        # A full resend from history is a new send of a completed note.
        resent = split_payloads(CHUNKS, event="meeting.note.resent")
        for payload in resent:
            result = self.deliver(payload)
        self.assertEqual(result["status"], "complete")
        self.assertTrue(result["resendOfCompleted"])
        self.assertEqual(result["earlierSendIds"], [first[0]["sendId"]])
        self.assertEqual(self.read_note(result), NOTE)

    def test_cli_prints_one_json_line(self):
        path = os.path.join(self.inbox, "payload.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(unsplit_payload(NOTE), handle)
        run = subprocess.run([sys.executable, "-I", HELPER, "--store", self.store, path],
                             capture_output=True, text=True, check=False)
        self.assertEqual(run.returncode, 0)
        lines = run.stdout.strip().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["status"], "complete")
        bad = os.path.join(self.inbox, "bad.json")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("{}")
        run = subprocess.run([sys.executable, "-I", HELPER, "--store", self.store, bad],
                             capture_output=True, text=True, check=False)
        self.assertEqual(run.returncode, 1)
        self.assertEqual(json.loads(run.stdout)["status"], "invalid")


if __name__ == "__main__":
    unittest.main()
