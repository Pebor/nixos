"""Self-tests for hyprmon-report. Run: python3 -m unittest -v test_hyprmon_report

Focus on the attribution logic that is easy to regress: widened classification,
media service mapping, same-site matching, and URL-host overlay.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("hyprmon_report", HERE / "hyprmon-report.py")
r = importlib.util.module_from_spec(spec)
sys.modules["hyprmon_report"] = r
spec.loader.exec_module(r)


def compiled_categories():
    return r.load_categories("nonexistent", False)[0]


class ClassifyTests(unittest.TestCase):
    def setUp(self):
        self.comp = compiled_categories()

    def test_host_drives_school_even_with_generic_title(self):
        self.assertEqual(r.classify("zen", "Random Page", self.comp, host="fit.cvut.cz"), "school")

    def test_path_label_drives_school(self):
        self.assertEqual(r.classify("foot", "hx", self.comp, proc="hx", path="school"), "school")

    def test_hx_is_coding_not_foot(self):
        self.assertEqual(r.classify("foot", "hx", self.comp, proc="hx"), "coding")

    def test_bare_shell_is_terminal(self):
        self.assertEqual(r.classify("foot", "bash", self.comp, proc="bash"), "terminal")

    def test_youtube_by_host(self):
        self.assertEqual(r.classify("zen", "Video", self.comp, host="www.youtube.com"), "youtube")

    def test_spotify_is_music(self):
        self.assertEqual(r.classify("Spotify", "Some Song", self.comp), "music")

    def test_unknown_falls_back(self):
        self.assertEqual(r.classify("someapp", "zzz", self.comp), "other")


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.comp = r.load_media_services("nonexistent", False)[0]

    def test_youtube_by_host(self):
        self.assertEqual(r.service_of("zen", "www.youtube.com", self.comp), "youtube")

    def test_spotify_by_player(self):
        self.assertEqual(r.service_of("spotify", "", self.comp), "spotify")

    def test_unmatched_falls_back_to_player(self):
        self.assertEqual(r.service_of("mpv", "", self.comp), "music")

    def test_same_site_ignores_www(self):
        self.assertTrue(r.same_site("www.youtube.com", "youtube.com"))
        self.assertFalse(r.same_site("www.youtube.com", "spotify.com"))
        self.assertFalse(r.same_site("", "youtube.com"))


class NormalizeHostOverlayTests(unittest.TestCase):
    def _normalize(self, events):
        comp = compiled_categories()
        health = r.new_health("/tmp", "UTC", "test")
        return r.normalize(events, comp, health)

    def test_host_only_applies_to_the_reporting_browser(self):
        ev = [
            {"ts": 100, "type": "url", "host": "www.youtube.com", "channel": "Chan", "browser": "zen-beta"},
            {"ts": 100, "type": "span", "start_ts": 100, "end_ts": 200,
             "class": "Spotify", "title": "Some Song"},
            {"ts": 100, "type": "span", "start_ts": 300, "end_ts": 400,
             "class": "zen-beta", "title": "A Video - YouTube"},
        ]
        spans = self._normalize(ev)[0]
        spotify = next(s for s in spans if s.app.startswith("Spotify"))
        zen = next(s for s in spans if "zen" in s.app)
        # Spotify is not the reporting browser: no host, so it is music not youtube.
        self.assertEqual(spotify.host, "")
        self.assertEqual(spotify.cat, "music")
        self.assertEqual(zen.host, "www.youtube.com")
        self.assertEqual(zen.cat, "youtube")

    def test_span_proc_and_path_are_carried_and_labelled(self):
        ev = [{"ts": 100, "type": "span", "start_ts": 100, "end_ts": 200,
               "class": "foot", "title": "hx", "proc": "hx", "path": "school"}]
        spans = self._normalize(ev)[0]
        self.assertEqual(spans[0].proc, "hx")
        self.assertEqual(spans[0].path, "school")
        self.assertEqual(spans[0].cat, "school")
        self.assertEqual(spans[0].app, "foot/hx")


if __name__ == "__main__":
    unittest.main()
