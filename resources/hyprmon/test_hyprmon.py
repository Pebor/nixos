"""Self-tests for hyprmon. Run with: python3 -m unittest -v test_hyprmon

These use only the standard library and a temporary store, so they never touch
~/.local/share/hyprmon or a live Hyprland session.
"""

from __future__ import annotations

import gzip
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

import hyprmon as h


class FakeClock:
    def __init__(self, start: float = 1_700_000_000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def make_config(**overrides) -> h.Config:
    data = {"store_dir": "/unused"}
    data.update(overrides)
    return h.parse_config(data, None)


class ParsingTests(unittest.TestCase):
    def test_event_split_on_first_separator_only(self) -> None:
        self.assertEqual(h.parse_event("activewindow>>kitty,a>>b"), ("activewindow", "kitty,a>>b"))

    def test_event_without_separator_is_rejected(self) -> None:
        self.assertIsNone(h.parse_event("configreloaded"))

    def test_activewindow_title_keeps_commas(self) -> None:
        clock = FakeClock()
        rec = h.Recorder(make_config(censor=[]), _NullStore(), clock)
        rec.handle_hypr_event("activewindow", "firefox,Hello, world, and more")
        self.assertEqual(rec._focus_class, "firefox")
        self.assertEqual(rec._focus_title, "Hello, world, and more")

    def test_address_normalised(self) -> None:
        self.assertEqual(h._normalise_address("55aa"), "0x55aa")
        self.assertEqual(h._normalise_address("0x55aa"), "0x55aa")

    def test_busctl_string_and_array_values(self) -> None:
        self.assertEqual(h.parse_variant('s "Playing"'), "Playing")
        metadata = h.parse_string_map(
            'a{sv} 3 "xesam:title" s "A, B" "xesam:url" s "https://ex.com/x?y=1" "xesam:artist" as 1 "Who"'
        )
        self.assertEqual(metadata["xesam:title"], "A, B")
        self.assertEqual(metadata["xesam:url"], "https://ex.com/x?y=1")
        self.assertEqual(metadata["xesam:artist"], ["Who"])

    def test_busctl_unknown_type_keeps_earlier_entries(self) -> None:
        metadata = h.parse_string_map('a{sv} 2 "xesam:title" s "T" "mpris:trackid" o "/x" "weird" (ii) 1 2')
        self.assertEqual(metadata, {"xesam:title": "T", "mpris:trackid": "/x"})

    def test_url_stores_host_only(self) -> None:
        self.assertEqual(h._url_host("https://www.example.org/a/b?token=secret"), "www.example.org")
        self.assertIsNone(h._url_host(None))
        self.assertIsNone(h._url_host("not a url"))


class CensorConfigTests(unittest.TestCase):
    def test_default_rules_apply_without_censor_table(self) -> None:
        cfg = h.parse_config({}, None)
        self.assertEqual(len(cfg.censor_rules), 2)
        self.assertEqual(h._first_rule(cfg.censor_rules, "firefox", "x - Private Browsing").action, "drop")

    def test_default_private_title_rule_matches_czech_suffix(self) -> None:
        cfg = h.parse_config({}, None)
        self.assertEqual(h._first_rule(cfg.censor_rules, "firefox", "Stránka - Anonymní prohlížení").action, "drop")

    def test_class_and_title_rule_is_conjunctive(self) -> None:
        cfg = h.parse_config({}, None)
        self.assertEqual(h._first_rule(cfg.censor_rules, "zen-beta", "New Incognito Tab").action, "drop")
        self.assertIsNone(h._first_rule(cfg.censor_rules, "kitty", "private notes"))
        self.assertIsNone(h._first_rule(cfg.censor_rules, "zen-beta", "Plain tab"))

    def test_first_match_wins(self) -> None:
        cfg = h.parse_config(
            {
                "censor": [
                    {"match_title": "secret", "action": "redact", "replacement": "[r]"},
                    {"match_title": "secret", "action": "drop"},
                ]
            },
            None,
        )
        self.assertEqual(h._first_rule(cfg.censor_rules, None, "a secret").action, "redact")

    def test_empty_censor_disables_defaults(self) -> None:
        self.assertEqual(h.parse_config({"censor": []}, None).censor_rules, ())

    def test_invalid_rules_are_rejected_with_safe_messages(self) -> None:
        bad = [
            {"censor": [{"action": "drop"}]},
            {"censor": [{"match_title": "(", "action": "drop"}]},
            {"censor": [{"match_title": "x", "action": "hide"}]},
            {"censor": [{"match_title": "x", "action": "drop", "typo": 1}]},
            {"retention_days": 0},
            {"retention_days": True},
            {"store_raw_ssid": "yes"},
            {"nonsense": 1},
        ]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(h.ConfigError):
                h.parse_config(data, None)


class _NullStore:
    """Store stand-in that records appends in memory."""

    def __init__(self) -> None:
        self.records: list[dict] = []

    def append(self, record) -> None:
        self.records.append(dict(record))


class RecorderPrivacyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.clock = FakeClock()
        self.store = _NullStore()
        self.cfg = h.parse_config({}, None)  # default private-window rules

    def _recorder(self, cfg: h.Config | None = None) -> h.Recorder:
        return h.Recorder(cfg or self.cfg, self.store, self.clock)

    def test_dropped_span_is_never_written(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "firefox,Secret - Private Browsing")
        self.clock.advance(30)
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.assertFalse([r for r in self.store.records if "Private" in json.dumps(r)])
        self.assertEqual(rec.stats["spans_dropped"], 1)

    def test_kept_span_is_written_with_duration(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.clock.advance(42)
        rec.handle_hypr_event("activewindow", "firefox,Docs")
        span = self.store.records[0]
        self.assertEqual(span["type"], "span")
        self.assertEqual(span["end_ts"] - span["start_ts"], 42)
        self.assertEqual(span["class"], "kitty")

    def test_redact_replaces_title(self) -> None:
        cfg = make_config(censor=[{"match_class": "keepass", "action": "redact", "replacement": "[pw]"}])
        rec = self._recorder(cfg)
        rec.handle_hypr_event("activewindow", "keepass,Vault: Bank login")
        self.clock.advance(5)
        rec.handle_hypr_event("activewindow", "kitty,x")
        span = self.store.records[0]
        self.assertEqual(span["title"], "[pw]")
        self.assertTrue(span["redacted"])

    def test_no_span_while_locked_or_idle(self) -> None:
        rec = self._recorder()
        rec.set_locked(True, record=False)
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.clock.advance(60)
        rec.set_locked(False, record=False)
        self.assertEqual(self.store.records, [])
        rec.set_idle(True)
        rec.handle_hypr_event("activewindow", "kitty,other")
        self.clock.advance(60)
        rec.set_idle(False)
        self.assertEqual(self.store.records, [])

    def test_lock_closes_open_span(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.clock.advance(10)
        rec.set_locked(True, record=False)
        self.assertEqual(len(self.store.records), 1)
        self.assertEqual(self.store.records[0]["end_ts"] - self.store.records[0]["start_ts"], 10)

    def test_span_ends_at_control_timestamp_not_daemon_clock(self) -> None:
        rec = self._recorder()
        start = self.clock.now
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.clock.advance(10)
        rec.set_locked(True, record=False, at=start + 4)  # the CLI wrote the record 4s in
        self.assertEqual(self.store.records[0]["end_ts"], start + 4)

    def test_control_timestamp_in_future_is_clamped(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "kitty,shell")
        self.clock.advance(5)
        rec.set_idle(True, at=self.clock.now + 999)
        self.assertEqual(self.store.records[0]["end_ts"], self.clock.now)

    def test_title_change_splits_span(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("openwindow", "0xabc,1,kitty,one")
        rec.handle_hypr_event("activewindow", "kitty,one")
        rec.handle_hypr_event("activewindowv2", "abc")
        self.clock.advance(3)
        rec.handle_hypr_event("windowtitlev2", "0xabc,two")
        self.assertEqual(len(self.store.records), 1)
        self.assertEqual(self.store.records[0]["title"], "one")

    def test_window_title_change_for_unfocused_window_is_ignored(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("openwindow", "0xabc,1,kitty,one")
        rec.handle_hypr_event("openwindow", "0xdef,2,firefox,two")
        rec.handle_hypr_event("activewindow", "kitty,one")
        rec.handle_hypr_event("activewindowv2", "abc")
        rec.handle_hypr_event("windowtitlev2", "0xdef,Foo - Private Browsing")
        self.clock.advance(3)
        rec.flush()
        self.assertEqual(len(self.store.records), 1)
        self.assertEqual(self.store.records[0]["title"], "one")

    def test_stale_focus_removed_by_closewindow(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("openwindow", "0xabc,1,kitty,one")
        rec.handle_hypr_event("activewindowv2", "abc")
        rec.handle_hypr_event("closewindow", "0xabc")
        self.assertIsNone(rec._focus_addr)

    def test_media_placeholder_stores_status_only(self) -> None:
        rec = self._recorder()
        rec.record_media(
            [h.MediaSnapshot("firefox.instance1", "Playing", "Zen is playing media", "https://x.example/a")]
        )
        record = self.store.records[0]
        self.assertEqual(record["status"], "Playing")
        self.assertNotIn("title", record)
        self.assertNotIn("url_host", record)

    def test_media_title_suppressed_while_private_window_open(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("openwindow", "0xabc,1,firefox,Shop - Private Browsing")
        rec.record_media([h.MediaSnapshot("vlc", "Playing", "Song Name", "https://ex.example/a?token=1")])
        record = self.store.records[0]
        self.assertNotIn("title", record)
        self.assertNotIn("url_host", record)

    def test_media_title_and_host_stored_when_safe(self) -> None:
        rec = self._recorder()
        rec.record_media([h.MediaSnapshot("vlc", "Playing", "Song Name", "https://ex.example/a?token=1")])
        record = self.store.records[0]
        self.assertEqual(record["title"], "Song Name")
        self.assertEqual(record["url_host"], "ex.example")
        self.assertNotIn("token", json.dumps(record))

    def test_media_closed_when_player_disappears(self) -> None:
        rec = self._recorder()
        rec.record_media([h.MediaSnapshot("vlc", "Playing", None, None)])
        rec.record_media([])
        self.assertEqual(self.store.records[-1]["status"], "closed")

    def test_wifi_stores_label_not_raw_ssid(self) -> None:
        cfg = make_config(wifi_labels={"HomeNet": "home"})
        rec = self._recorder(cfg)
        rec.record_wifi("HomeNet")
        rec.record_wifi("NeighbourNet")
        self.assertEqual([r["label"] for r in self.store.records], ["home", "other"])
        for record in self.store.records:
            self.assertNotIn("ssid", record)
            self.assertNotIn("Neighbour", json.dumps(record))

    def test_wifi_raw_ssid_only_when_opted_in(self) -> None:
        cfg = make_config(store_raw_ssid=True)
        rec = self._recorder(cfg)
        rec.record_wifi("HomeNet")
        self.assertEqual(self.store.records[0]["ssid"], "HomeNet")

    def test_snapshot_reports_no_titles(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "kitty,secret title")
        snap = json.dumps(rec.snapshot())
        self.assertNotIn("secret title", snap)
        self.assertNotIn("kitty", snap)

    def test_snapshot_hides_focus_while_locked(self) -> None:
        rec = self._recorder()
        rec.handle_hypr_event("activewindow", "kitty,shell")
        rec.set_locked(True, record=False)
        self.assertIsNone(rec.snapshot()["focus"])


class CpuSamplerTests(unittest.TestCase):
    def test_cpu_percent_from_deltas(self) -> None:
        import tempfile as tf

        with tf.TemporaryDirectory() as d:
            proc = Path(d)
            (proc / "stat").write_text("cpu  100 0 100 800 0 0 0 0 0 0\n")
            (proc / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 2048 kB\n")
            sampler = h.ResourceSampler(Path(d) / "bat", proc)
            self.assertIsNone(sampler.sample()["cpu_pct"])  # baseline sample
            # Over this interval: 200 ticks total, 100 idle, so 100 busy = 50%.
            (proc / "stat").write_text("cpu  150 0 150 900 0 0 0 0 0 0\n")
            sample = sampler.sample()
            self.assertAlmostEqual(sample["cpu_pct"], 50.0, places=1)
            self.assertEqual(sample["mem_available_mb"], 2.0)
            self.assertIsNone(sample["battery_pct"])


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.store = h.Store(Path(self._tmp.name) / "store")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_directory_and_file_permissions(self) -> None:
        now = time.time()
        self.store.append({"ts": now, "type": "idle"})
        self.assertEqual(self.store.directory.stat().st_mode & 0o777, 0o700)
        path = self.store.path_for(date.fromtimestamp(now))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_append_round_trips_in_order(self) -> None:
        now = time.time()
        for label in ("a", "b", "c"):
            self.store.append({"ts": now, "type": "wifi", "label": label})
        self.assertEqual([r["label"] for r in self.store.tail(10)], ["a", "b", "c"])
        self.assertEqual([r["label"] for r in self.store.tail(2)], ["b", "c"])

    def test_torn_tail_is_repaired_without_losing_earlier_records(self) -> None:
        now = time.time()
        self.store.append({"ts": now, "type": "idle"})
        path = self.store.path_for(date.fromtimestamp(now))
        with path.open("ab") as fh:
            fh.write(gzip.compress(b'{"ts":1,"type":"wifi"}\n')[:15])
        self.assertGreater(self.store.repair(path), 0)
        self.store.append({"ts": now, "type": "active"})
        self.assertEqual([r["type"] for r in self.store.tail(5)], ["idle", "active"])

    def test_prune_keeps_retention_window(self) -> None:
        today = date(2026, 10, 21)
        for offset in range(20):
            day = date.fromordinal(today.toordinal() - offset)
            self.store.path_for(day).parent.mkdir(parents=True, exist_ok=True)
            self.store.path_for(day).write_bytes(b"")
        removed = self.store.prune(14, today)
        self.assertEqual(removed, 6)
        self.assertEqual(len(self.store.files()), 14)

    def test_records_use_local_day_file(self) -> None:
        ts = time.mktime((2026, 10, 21, 23, 59, 0, 0, 0, -1))
        self.store.append({"ts": ts, "type": "idle"})
        self.assertTrue(self.store.path_for(date(2026, 10, 21)).exists())


class ControlAndLockTests(unittest.TestCase):
    def test_control_record_written_and_daemon_notified(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            cfg = make_config(store_dir=os.path.join(d, "store"))
            runtime = Path(d) / "run"
            runtime.mkdir()
            sock_path = runtime / h.CONTROL_SOCKET_NAME
            server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            server.bind(str(sock_path))
            server.settimeout(2)
            with mock.patch.object(h, "ipc_dir", return_value=runtime):
                self.assertEqual(h.cmd_control("locked", cfg), h.EX_OK)
                kind, ts_text = server.recv(64).decode("ascii").split(" ")
                self.assertEqual(kind, "locked")
                self.assertAlmostEqual(float(ts_text), time.time(), delta=5)
            server.close()
            store = h.Store(cfg.store_dir)
            self.assertEqual([r["type"] for r in store.tail(5)], ["lock"])

    def test_control_record_written_even_without_daemon(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            cfg = make_config(store_dir=os.path.join(d, "store"))
            with mock.patch.object(h, "ipc_dir", return_value=Path(d) / "absent"):
                self.assertEqual(h.cmd_control("idle", cfg), h.EX_OK)
            self.assertEqual([r["type"] for r in h.Store(cfg.store_dir).tail(5)], ["idle"])

    def test_single_instance_lock(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            lock = Path(d) / "daemon.lock"
            fd = h._acquire_instance_lock(lock)
            try:
                self.assertEqual(h.daemon_pid(lock), os.getpid())
                with self.assertRaises(h.AlreadyRunning):
                    h._acquire_instance_lock(lock)
            finally:
                os.close(fd)
            self.assertIsNone(h.daemon_pid(lock))


class EventStreamTests(unittest.TestCase):
    def test_reads_lines_and_splits_partial_chunks(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            path = Path(d) / "s.sock"
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path))
            server.listen(1)
            stream = h.EventStream(path, time.monotonic)
            self.assertTrue(stream.connect_if_due())
            conn, _ = server.accept()
            conn.sendall(b"configreloaded>>\nactivewindow>>kitty,a")
            time.sleep(0.05)
            lines = stream.read_lines()
            self.assertEqual(lines, ["configreloaded>>"])
            conn.sendall(b"b\n")
            time.sleep(0.05)
            self.assertEqual(stream.read_lines(), ["activewindow>>kitty,ab"])
            conn.close()
            self.assertIsNone(stream.read_lines())  # peer closed: connection is dropped
            self.assertFalse(stream.connected)
            stream.close()
            server.close()


if __name__ == "__main__":
    unittest.main()
