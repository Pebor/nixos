#!/usr/bin/env python3
"""hyprmon-report: turn hyprmon event stores into aggregates.json + report.html.

Python 3.11+ standard library only. The HTML report is fully self-contained
(inline CSS and hand-rolled inline SVG, no scripts, no external resources).

Usage examples:
    hyprmon-report.py --day 2026-10-21
    hyprmon-report.py --week 2026-10-21
    hyprmon-report.py --from 2026-10-01 --to 2026-10-21 --out ./rep
    hyprmon-report.py --input ~/.local/share/hyprmon/ --tz Europe/Prague

See README.md for the data model, category config and design decisions.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import dataclasses
import datetime as dt
import gzip
import html
import json
import math
import os
import re
import sys
import tomllib
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

VERSION = 1
ONE_DAY = dt.timedelta(days=1)
DEFAULT_INPUT = "~/.local/share/hyprmon/"
DEFAULT_CONFIG = "~/.config/hyprmon/hyprmon.toml"
DEFAULT_OUT = "./hyprmon-report-out"
DEFAULT_MEDIA_MAX_GAP_MIN = 30.0
DEFAULT_LOOKBACK_DAYS = 1
HEATMAP_FULL_MINUTES = 60.0  # heatmap intensity 1.0 == 60 active minutes in an hour

# Seed category rules. Each entry is one regex; a category matches when any of
# its regexes matches the window class, title, foreground proc, path label or
# the concurrent browser host (case-insensitive, re.search, matched per-field).
# Categories are tried in order, first match wins; unmatched spans fall back to
# 'other'. A [categories] table in the config file REPLACES these seeds entirely.
#
# Order matters: school first (so a hx session in ~/Documents/school lands in
# school), then coding (hx gets its own colour, not "foot"), then the media and
# messaging services, then generic browsing/terminal.
SEED_CATEGORIES = {
    "school": [
        "jetbrains-idea", "bludiště", r"\bOC\b", "prolog", "stack", "xournal",
        "rnote", "anki", "teams-for-linux", "moodle", "overleaf",
        r"cvut\.cz", r"\bschool\b",
        r"(?i)lesson|lecture|lekce|přednáška|cvičení|course|kurz|quiz|homework|úkol|moodle|fit ?čvut|online\.fit"],
    "coding": [r"\bhx\b", "helix", r"\bcode\b", "jetbrains", r"\bnvim\b", r"\bvim\b", r"\bemacs\b"],
    "youtube": ["youtube", r"youtu\.be"],
    "music": ["spotify", r"\bmpv\b", "soundcloud", "bandcamp", "spotifast", "music"],
    "messaging": ["telegram", "discord", "signal"],
    "browsing": ["firefox", "zen", "helium", "chromium", "brave", "browser"],
    "terminal": ["foot", "kitty", "alacritty", "wezterm", "ghostty",
                 r"\bbash\b", r"\bfish\b", r"\bzsh\b", r"\bgit\b", r"\bdocker\b",
                 r"\bpython", r"\bmake\b", r"\bcargo\b", r"\bnode\b", r"\bgo\b"],
}
FALLBACK_CATEGORY = "other"

CAT_COLORS = {
    "school": "#4e79a7", "coding": "#59a14f", "youtube": "#e15759",
    "music": "#f28e2b", "messaging": "#b07aa1", "browsing": "#76b7b2",
    "terminal": "#9c755f", "other": "#bab0ac",
}
EXTRA_COLORS = ["#edc948", "#ff9da7", "#86bcb6", "#d37295", "#4e79a7", "#59a14f", "#e15759"]
WIFI_COLORS = ["#8dd3c7", "#ffffb3", "#bebada", "#fb8072", "#80b1d3", "#fdb462", "#b3de69", "#fccde5"]
MEDIA_COLOR = "#e15759"
PLAYBACK_COLOR = "#f28e2b"
ACTIVE_COLOR = "#4e79a7"
IDLE_COLOR = "#e6e6e6"
AFK_COLOR = "#9a9a9a"
LOCK_COLOR = "#333333"

# Map a media player / url host to a service label so YouTube, Spotify and the
# rest can be counted separately. Matched against the url host first, then the
# player name. A [media_services] table in the config REPLACES these seeds.
DEFAULT_MEDIA_SERVICES = {
    "youtube": [r"youtube", r"youtu\.be"],
    "spotify": [r"spotify"],
    "music": [r"\bmpv\b", "soundcloud", "bandcamp", r"\bvlc\b", "music"],
}
FILE_RE = re.compile(r"^events-(\d{4}-\d{2}-\d{2})\.jsonl(\.gz)?$")


class UsageError(Exception):
    """Bad CLI usage or unusable input; reported without a traceback."""


class ConfigError(UsageError):
    """Bad config file content."""


@dataclasses.dataclass
class Span:
    start: float
    end: float
    cat: str
    app: str
    idle: bool
    open_: bool = False
    proc: str = ""
    path: str = ""
    host: str = ""
    title: str = ""


# --------------------------------------------------------------------------
# time helpers
# --------------------------------------------------------------------------

def parse_date(text: str) -> dt.date:
    try:
        return dt.datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        raise UsageError(f"not a YYYY-MM-DD date: {text!r}")


def day_epoch(d: dt.date, tz) -> float:
    """Epoch seconds of local midnight at the start of date d."""
    return dt.datetime(d.year, d.month, d.day, tzinfo=tz).timestamp()


def hour_pieces(a: float, b: float, tz):
    """Split [a, b) at local hour boundaries. Yields (local_date, hour, p0, p1).

    Hour boundaries are found from the local wall clock, so this stays correct
    across DST changes (a 23h or 25h day simply yields 23 or 25 pieces).
    """
    t = a
    while t < b:
        d = dt.datetime.fromtimestamp(t, tz)
        floor = t - (d.minute * 60 + d.second + d.microsecond / 1e6)
        nxt = min(b, floor + 3600.0)
        if nxt <= t:  # float guard
            nxt = b
        yield d.date(), d.hour, t, nxt
        t = nxt


def local_date_iso(ts: float, tz) -> str:
    return dt.datetime.fromtimestamp(ts, tz).date().isoformat()


def resolve_tz(name):
    """Return (tzinfo, human-readable name)."""
    if name:
        try:
            return ZoneInfo(name), name
        except (ZoneInfoNotFoundError, ValueError):
            raise UsageError(f"unknown IANA timezone: {name!r}")
    candidates = []
    env = os.environ.get("TZ", "").lstrip(":")
    if env:
        candidates.append(env)
    try:
        real = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in real:
            candidates.append(real.split("zoneinfo/", 1)[1])
    except OSError:
        pass
    for c in candidates:
        try:
            return ZoneInfo(c), c
        except (ZoneInfoNotFoundError, ValueError):
            continue
    now = dt.datetime.now().astimezone()
    return now.tzinfo, f"fixed offset {now:%z} (no IANA zone found; DST not modelled)"


# --------------------------------------------------------------------------
# config / categories
# --------------------------------------------------------------------------

def load_categories(path: str, explicit: bool):
    """Return (compiled, order, source_text, raw_spec)."""
    if os.path.isfile(path):
        try:
            with open(path, "rb") as fh:
                cfg = tomllib.load(fh)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"{path}: invalid TOML: {e}")
        if "categories" in cfg:
            raw = cfg["categories"]
            if not isinstance(raw, dict):
                raise ConfigError("[categories] must be a table")
            spec = {}
            for name, pats in raw.items():
                if isinstance(pats, str):
                    pats = [pats]
                if not isinstance(pats, list) or not all(isinstance(p, str) for p in pats):
                    raise ConfigError(f"[categories].{name} must be a list of regex strings")
                spec[name] = pats
            source = f"config: {path}"
        else:
            spec = SEED_CATEGORIES
            source = f"seed defaults ({path} has no [categories] table)"
    elif explicit:
        raise ConfigError(f"config file not found: {path}")
    else:
        spec = SEED_CATEGORIES
        source = "seed defaults (no config file)"

    compiled = []
    for name, pats in spec.items():
        rxs = []
        for p in pats:
            try:
                rxs.append(re.compile(p, re.IGNORECASE))
            except re.error as e:
                raise ConfigError(f"[categories].{name}: bad regex {p!r}: {e}")
        compiled.append((name, rxs))
    order = [n for n, _ in compiled]
    if FALLBACK_CATEGORY not in order:
        order.append(FALLBACK_CATEGORY)
    return compiled, order, source, {n: list(p) for n, p in spec.items()}


def classify(cls: str, title: str, compiled, proc: str = "", path: str = "", host: str = "") -> str:
    """Match each field independently (so anchors work per-field), first hit wins."""
    subjects = [cls, title, proc, path, host]
    for name, rxs in compiled:
        for rx in rxs:
            for s in subjects:
                if s and rx.search(s):
                    return name
    return FALLBACK_CATEGORY


def load_media_services(path: str, explicit: bool):
    """Return (compiled_services, source_text). Service name -> list of regexes."""
    spec = DEFAULT_MEDIA_SERVICES
    source = "seed defaults"
    if os.path.isfile(path):
        try:
            with open(path, "rb") as fh:
                cfg = tomllib.load(fh)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"{path}: invalid TOML: {e}")
        if "media_services" in cfg:
            raw = cfg["media_services"]
            if not isinstance(raw, dict):
                raise ConfigError("[media_services] must be a table")
            spec = {}
            for name, pats in raw.items():
                if isinstance(pats, str):
                    pats = [pats]
                if not isinstance(pats, list) or not all(isinstance(p, str) for p in pats):
                    raise ConfigError(f"[media_services].{name} must be a list of regex strings")
                spec[name] = pats
            source = f"config: {path}"
    elif explicit:
        raise ConfigError(f"config file not found: {path}")

    compiled = []
    for name, pats in spec.items():
        rxs = []
        for p in pats:
            try:
                rxs.append(re.compile(p, re.IGNORECASE))
            except re.error as e:
                raise ConfigError(f"[media_services].{name}: bad regex {p!r}: {e}")
        compiled.append((name, rxs))
    return compiled, source


def service_of(player: str, host: str, compiled) -> str:
    """Media service label: match the url host first, then the player name."""
    for name, rxs in compiled:
        for rx in rxs:
            if (host and rx.search(host)) or (player and rx.search(player)):
                return name
    return host or player or "other"


def same_site(a: str, b: str) -> bool:
    """True when two hosts look like the same site (ignoring subdomains)."""
    if not a or not b:
        return False
    a, b = a.lower().lstrip("www."), b.lower().lstrip("www.")
    return a == b or a.endswith("." + b) or b.endswith("." + a)


# --------------------------------------------------------------------------
# input discovery and reading
# --------------------------------------------------------------------------

def scan_days(indir: str):
    days = set()
    for name in os.listdir(indir):
        m = FILE_RE.match(name)
        if m:
            try:
                days.add(parse_date(m.group(1)))
            except UsageError:
                pass
    return sorted(days)


def select_files(indir: str, lo: dt.date, hi: dt.date):
    """Return sorted [(date, path)]. Prefers .jsonl.gz over plain .jsonl per day."""
    chosen = {}
    for name in sorted(os.listdir(indir)):
        m = FILE_RE.match(name)
        if not m:
            continue
        d = parse_date(m.group(1))
        if not (lo <= d <= hi):
            continue
        is_gz = bool(m.group(2))
        if d not in chosen or (is_gz and not chosen[d][1]):
            chosen[d] = (os.path.join(indir, name), is_gz)
    return [(d, chosen[d][0]) for d in sorted(chosen)]


def num(x):
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return None
    return float(x) if math.isfinite(x) else None


def read_events(files, health):
    events = []
    seen = set()
    for d, path in files:
        health["files_read"].append(os.path.basename(path))
        opener = gzip.open if path.endswith(".gz") else open
        try:
            with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        health["malformed_lines"] += 1
                        continue
                    if not isinstance(ev, dict):
                        health["malformed_lines"] += 1
                        continue
                    key = json.dumps(ev, sort_keys=True)
                    if key in seen:
                        health["duplicate_lines_removed"] += 1
                        continue
                    seen.add(key)
                    events.append(ev)
        except (OSError, EOFError) as e:
            health["unreadable_files"].append(f"{os.path.basename(path)}: {e}")
    return events


def merge_intervals(ivs):
    out = []
    for a, b in sorted(ivs):
        if b <= a:
            continue
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def control_intervals(ctrl, data_end):
    """ctrl: sorted [(ts, type)] -> (afk_intervals, lock_intervals, open_at_end)."""
    afk, locked = [], []
    afk_start = lock_start = None
    for t, typ in ctrl:
        if typ == "idle" and afk_start is None:
            afk_start = t
        elif typ == "active" and afk_start is not None:
            afk.append((afk_start, t))
            afk_start = None
        elif typ == "lock" and lock_start is None:
            lock_start = t
        elif typ == "unlock" and lock_start is not None:
            locked.append((lock_start, t))
            lock_start = None
    open_flags = []
    if afk_start is not None:
        open_flags.append("idle")
        if data_end > afk_start:
            afk.append((afk_start, data_end))
    if lock_start is not None:
        open_flags.append("lock")
        if data_end > lock_start:
            locked.append((lock_start, data_end))
    return afk, locked, open_flags


class DayIndex:
    """Splits intervals into per-local-day pieces for the window days only."""

    def __init__(self, days, tz):
        self.isos = [d.isoformat() for d in days]
        self.bounds = [(day_epoch(d, tz), day_epoch(d + ONE_DAY, tz)) for d in days]
        self.starts = [b[0] for b in self.bounds]
        self.lo = self.bounds[0][0]
        self.hi = self.bounds[-1][1]

    def split(self, a, b):
        a = max(a, self.lo)
        b = min(b, self.hi)
        if b <= a:
            return
        i = bisect.bisect_right(self.starts, a) - 1
        while i < len(self.isos) and self.bounds[i][0] < b:
            ds, de = self.bounds[i]
            p0, p1 = max(a, ds), min(b, de)
            if p1 > p0:
                yield self.isos[i], p0, p1
            i += 1


def merge_segments(segs):
    """segs: [(p0, p1, kind, label)] -> merged adjacent same-kind/same-label segments."""
    out = []
    for p0, p1, kind, label in sorted(segs, key=lambda s: (s[0], s[1])):
        if out and out[-1][2] == kind and out[-1][3] == label and p0 <= out[-1][1] + 1.0:
            out[-1][1] = max(out[-1][1], p1)
        else:
            out.append([p0, p1, kind, label])
    return [tuple(s) for s in out]


def pct(part, total):
    return round(100.0 * part / total, 1) if total > 0 else 0.0


def r2(x):
    return round(x, 2)


# --------------------------------------------------------------------------
# core build
# --------------------------------------------------------------------------

def new_health(input_dir, tz_name, cat_source):
    return {
        "input_dir": input_dir,
        "timezone": tz_name,
        "category_source": cat_source,
        "files_read": [],
        "unreadable_files": [],
        "window_days": 0,
        "window_days_without_event_file": [],
        "days_with_event_file": 0,
        "days_with_any_event": 0,
        "days_with_active_time": 0,
        "span_records_read": 0,
        "span_records_in_window": 0,
        "span_idle_in_window": 0,
        "span_open_read": 0,
        "span_invalid": 0,
        "span_overlaps_in_window": 0,
        "span_overlap_seconds": 0.0,
        "span_unclassified_percent_time": 0.0,
        "span_unclassified_percent_count": 0.0,
        "media_events": 0,
        "url_events": 0,
        "spans_with_proc": 0,
        "spans_with_path": 0,
        "window_state_events": 0,
        "control_events": 0,
        "wifi_events": 0,
        "resources_events": 0,
        "open_control_states_at_end": [],
        "unknown_types": {},
        "malformed_lines": 0,
        "duplicate_lines_removed": 0,
        "invalid_events": 0,
    }


def url_index_at(points, t):
    """Index of the URL point active at time t (last point with ts <= t), else -1."""
    if not points:
        return -1
    ts_list = [p["ts"] for p in points]
    i = bisect.bisect_right(ts_list, t) - 1
    return i if i >= 0 else -1


def normalize(events, compiled, health):
    raw_spans, ctrl, media, wifi, wstates, url_points = [], [], [], [], [], []
    data_ts = []
    for ev in events:
        typ = ev.get("type")
        ts = num(ev.get("ts"))
        if typ == "span":
            health["span_records_read"] += 1
            start = num(ev.get("start_ts"))
            if start is None:
                health["span_invalid"] += 1
                continue
            end = num(ev.get("end_ts"))
            is_open = end is None
            if is_open:
                health["span_open_read"] += 1
                end = start  # fixed up after sorting
            elif end < start:
                health["span_invalid"] += 1
                continue
            raw_spans.append({
                "start": start, "end": end, "open": is_open,
                "cls": str(ev.get("class") or ""),
                "title": str(ev.get("title") or ""),
                "proc": str(ev.get("proc") or ""),
                "path": str(ev.get("path") or ""),
                "idle": bool(ev.get("idle")),
            })
            data_ts.append(start)
            data_ts.append(end)
        elif typ == "url":
            health["url_events"] = health.get("url_events", 0) + 1
            if ts is None:
                health["invalid_events"] += 1
                continue
            url_points.append({
                "ts": ts,
                "host": str(ev.get("host") or ""),
                "channel": str(ev.get("channel") or ""),
                "title": str(ev.get("title") or ""),
                "browser": str(ev.get("browser") or ""),
            })
            data_ts.append(ts)
        elif typ == "media":
            health["media_events"] += 1
            if ts is None:
                health["invalid_events"] += 1
                continue
            media.append((ts, str(ev.get("player") or "unknown"),
                          str(ev.get("status") or "").strip().lower(),
                          str(ev.get("title") or ""), str(ev.get("url_host") or "")))
            data_ts.append(ts)
        elif typ in ("idle", "active", "lock", "unlock"):
            health["control_events"] += 1
            if ts is None:
                health["invalid_events"] += 1
                continue
            ctrl.append((ts, typ))
            data_ts.append(ts)
        elif typ == "wifi":
            health["wifi_events"] += 1
            if ts is None:
                health["invalid_events"] += 1
                continue
            wifi.append((ts, str(ev.get("label") or "(none)")))
            data_ts.append(ts)
        elif typ == "window_state":
            health["window_state_events"] += 1
            if ts is None:
                health["invalid_events"] += 1
                continue
            wstates.append((ts, bool(ev.get("inhibiting_idle")), bool(ev.get("censored"))))
            data_ts.append(ts)
        elif typ == "resources":
            health["resources_events"] += 1
            if ts is not None:
                data_ts.append(ts)
        else:
            key = str(typ)
            health["unknown_types"][key] = health["unknown_types"].get(key, 0) + 1

    data_end = max(data_ts) if data_ts else 0.0

    # URL points hold their host/channel/title until the next report.
    url_points.sort(key=lambda p: p["ts"])
    health["url_events"] = len(url_points)

    # Open spans: the focus is assumed to last until the next span starts
    # (or until the end of the data if there is no next span).
    raw_spans.sort(key=lambda s: (s["start"], s["end"]))
    for i, s in enumerate(raw_spans):
        if s["open"]:
            nxt = raw_spans[i + 1]["start"] if i + 1 < len(raw_spans) else data_end
            s["end"] = max(s["start"], nxt)

    # Build Spans: attribute the concurrent browser host, then classify on the
    # widened subject (class|title|proc|path|host). The host only applies to a
    # window of the same browser that reported the URL — otherwise a background
    # Spotify span would inherit whatever tab is open.
    spans = []
    for s in raw_spans:
        host = ""
        idx = url_index_at(url_points, s["start"])
        if idx >= 0:
            p = url_points[idx]
            browser, cls_l = p["browser"].lower(), s["cls"].lower()
            if browser and (browser in cls_l or cls_l in browser):
                host = p["host"]
        proc = s["proc"]
        app = s["cls"] or "(unknown)"
        if proc and proc.lower() != app.lower():
            app = f"{app}/{proc}"  # foot/hx, foot/bash — terminals are not one app
        cat = classify(s["cls"], s["title"], compiled, proc, s["path"], host)
        spans.append(Span(s["start"], s["end"], cat, app, s["idle"], s["open"],
                          proc, s["path"], host, s["title"]))
        if proc:
            health["spans_with_proc"] += 1
        if s["path"]:
            health["spans_with_path"] += 1
    return spans, sorted(ctrl), media, sorted(wifi), sorted(wstates), url_points, data_end


def run_build(args):
    indir = os.path.expanduser(args.input)
    if not os.path.isdir(indir):
        raise UsageError(f"input directory not found: {indir}")
    tz, tz_name = resolve_tz(args.tz)
    cfg_path = os.path.expanduser(args.config)
    compiled, order, cat_source, cat_spec = load_categories(cfg_path, args.config_explicit)

    all_days = scan_days(indir)
    if args.day:
        w_from = w_to = parse_date(args.day)
    elif args.week:
        d = parse_date(args.week)
        w_from = d - dt.timedelta(days=d.weekday())  # ISO week, Monday start
        w_to = w_from + dt.timedelta(days=6)
    elif args.from_ or args.to:
        if not (args.from_ and args.to):
            raise UsageError("--from and --to must be given together")
        w_from, w_to = parse_date(args.from_), parse_date(args.to)
        if w_from > w_to:
            raise UsageError("--from is after --to")
    else:
        if not all_days:
            raise UsageError(f"no events-YYYY-MM-DD.jsonl.gz files found in {indir}")
        w_from, w_to = all_days[0], all_days[-1]

    n_days = (w_to - w_from).days + 1
    days = [w_from + dt.timedelta(days=i) for i in range(n_days)]
    isos = [d.isoformat() for d in days]
    lo = day_epoch(w_from, tz)
    hi = day_epoch(w_to + ONE_DAY, tz)

    read_lo = w_from - dt.timedelta(days=args.lookback_days)
    read_hi = w_to + ONE_DAY
    files = select_files(indir, read_lo, read_hi)

    health = new_health(indir, tz_name, cat_source)
    health["window_days"] = n_days
    file_days = {d for d, _ in files if w_from <= d <= w_to}
    health["days_with_event_file"] = len(file_days)
    health["window_days_without_event_file"] = [i for d, i in zip(days, isos) if d not in file_days]

    events = read_events(files, health)
    spans, ctrl, media, wifi, wstates, url_points, data_end = normalize(events, compiled, health)
    media_services, media_service_source = load_media_services(cfg_path, args.config_explicit)

    cap = args.media_max_gap * 60.0
    didx = DayIndex(days, tz)

    # ---- per-day containers
    per_day = {i: {c: 0.0 for c in order} for i in isos}
    tot = {i: {"active_minutes": 0.0, "idle_span_minutes": 0.0, "media_minutes": 0.0, "playback_minutes": 0.0, "playback_censored_minutes": 0.0,
               "afk_minutes": 0.0, "locked_minutes": 0.0} for i in isos}
    per_day_hour = {i: [0.0] * 24 for i in isos}
    hour_total = [0.0] * 24
    cat_app_hour = collections.defaultdict(float)
    app_tot = collections.defaultdict(float)
    timeline = {i: {"activity": [], "afk": [], "locked": [], "media": [], "wifi": []} for i in isos}

    # ---- spans (focus) in window
    in_win = [s for s in spans if s.end > lo and s.start < hi]
    health["span_records_in_window"] = len(in_win)
    health["span_idle_in_window"] = sum(1 for s in in_win if s.idle)
    max_end = -math.inf
    for s in in_win:  # overlap audit (data-quality check, not used in totals)
        if s.start < max_end:
            health["span_overlaps_in_window"] += 1
            health["span_overlap_seconds"] += min(max_end, s.end) - s.start
        max_end = max(max_end, s.end)

    unclassified_count = 0
    classified_count = 0
    for s in in_win:
        if s.idle:
            continue
        if s.cat == FALLBACK_CATEGORY:
            unclassified_count += 1
        else:
            classified_count += 1
    for s in in_win:
        a, b = max(s.start, lo), min(s.end, hi)
        if b <= a:
            continue
        for d, h, p0, p1 in hour_pieces(a, b, tz):
            iso = d.isoformat()
            if iso not in tot:
                continue
            m = (p1 - p0) / 60.0
            if s.idle:
                tot[iso]["idle_span_minutes"] += m
                kind = "idle"
            else:
                tot[iso]["active_minutes"] += m
                per_day[iso][s.cat] += m
                per_day_hour[iso][h] += m
                hour_total[h] += m
                cat_app_hour[(s.cat, s.app, h)] += m
                app_tot[(s.cat, s.app)] += m
                kind = s.cat
            timeline[iso]["activity"].append((p0, p1, kind, s.app))

    # ---- AFK / lock from control events
    afk_iv, lock_iv, open_flags = control_intervals(ctrl, data_end)
    health["open_control_states_at_end"] = open_flags
    afk_total = lock_total = 0.0
    for a, b in afk_iv:
        for iso, p0, p1 in didx.split(a, b):
            tot[iso]["afk_minutes"] += (p1 - p0) / 60.0
            timeline[iso]["afk"].append((p0, p1, "afk", "AFK"))
    for a, b in lock_iv:
        for iso, p0, p1 in didx.split(a, b):
            tot[iso]["locked_minutes"] += (p1 - p0) / 60.0
            timeline[iso]["locked"].append((p0, p1, "locked", "locked"))

    # ---- media: per-player intervals bounded by next event of that player.
    # Each playing interval carries its service and title so YouTube, Spotify
    # and the rest can be counted separately.
    by_player = collections.defaultdict(list)
    for ts, player, status, title, host in media:
        by_player[player].append((ts, status, title, host))
    player_iv = {}
    playing_runs = []  # (start, end, service, title, host, player)
    for player, evs in by_player.items():
        ivs = []
        for i, (t, st, title, host) in enumerate(evs):
            if st != "playing":
                continue
            # Playing runs until the player's next event. The cap only applies
            # when no Paused/Stopped was recorded (next event is another
            # Playing, or there is no next event), i.e. the stop went missing.
            end = t + cap
            if i + 1 < len(evs):
                nxt_t, nxt_st = evs[i + 1][0], evs[i + 1][1]
                end = nxt_t if nxt_st != "playing" else min(nxt_t, t + cap)
            if end > t:
                ivs.append((t, end))
                service = service_of(player, host, media_services)
                playing_runs.append((t, end, service, title, host, player))
        player_iv[player] = merge_intervals(ivs)  # per-player overlap dedupe
    union = merge_intervals([iv for v in player_iv.values() for iv in v])
    media_per_player = {}
    for player, ivs in player_iv.items():
        media_per_player[player] = sum(
            p1 - p0 for a, b in ivs for _, p0, p1 in didx.split(a, b)) / 60.0

    # Per-service playing minutes (union per service so overlap is not doubled).
    service_iv = collections.defaultdict(list)
    for t, end, service, _title, _host, _player in playing_runs:
        service_iv[service].append((t, end))
    media_per_service = {}
    service_per_day = {i: {} for i in isos}
    for service, ivs in service_iv.items():
        total = 0.0
        for a, b in merge_intervals(ivs):
            for iso, p0, p1 in didx.split(a, b):
                m = (p1 - p0) / 60.0
                total += m
                service_per_day[iso][service] = service_per_day[iso].get(service, 0.0) + m
        media_per_service[service] = r2(total)

    # Channel attribution: a playing interval belongs to the channel the active
    # browser tab reported, but only when the media and the tab are the same
    # site (so background Spotify is not credited to an open YouTube tab).
    channel_playing = collections.defaultdict(float)
    channel_titles = collections.defaultdict(set)
    for t, end, _service, title, host, _player in playing_runs:
        idx = url_index_at(url_points, t)
        if idx < 0:
            continue
        p = url_points[idx]
        if not p["channel"] or not same_site(host, p["host"]):
            continue
        for _iso, p0, p1 in didx.split(t, end):
            channel_playing[p["channel"]] += (p1 - p0) / 60.0
        if title:
            channel_titles[p["channel"]].add(title)

    # Focused time per host and per channel's tab, from browser focus spans
    # (each span is roughly one tab, since a tab switch splits the span).
    host_minutes = collections.defaultdict(float)
    channel_tab = collections.defaultdict(float)
    for s in in_win:
        if s.idle or not s.host:
            continue
        idx = url_index_at(url_points, s.start)
        channel = url_points[idx]["channel"] if idx >= 0 else ""
        for _iso, p0, p1 in didx.split(s.start, s.end):
            m = (p1 - p0) / 60.0
            host_minutes[s.host] += m
            if channel:
                channel_tab[channel] += m

    media_total = 0.0
    for a, b in union:
        for iso, p0, p1 in didx.split(a, b):
            m = (p1 - p0) / 60.0
            tot[iso]["media_minutes"] += m
            media_total += m
            timeline[iso]["media"].append((p0, p1, "media", "media"))

    # ---- playback hint (window_state samples): each sample with
    # inhibiting_idle covers the interval since the previous sample of any
    # kind (poll cadence ~60 s), capped at 2 min so a missed poll cannot
    # over-count. Censored samples (private window focused) count as
    # unattributed playback.
    PLAYBACK_SAMPLE_CAP = 120.0
    pb_ivs, pb_cens_ivs = [], []
    prev_ts = None
    for ts, inh, cens in wstates:
        if inh:
            start = (prev_ts if prev_ts is not None else ts - 60.0)
            start = max(start, ts - PLAYBACK_SAMPLE_CAP)
            if ts > start:
                (pb_cens_ivs if cens else pb_ivs).append((start, ts))
        prev_ts = ts
    playback_total = 0.0
    for a2, b2 in merge_intervals(pb_ivs):
        for iso, p0, p1 in didx.split(a2, b2):
            m = (p1 - p0) / 60.0
            tot[iso]["playback_minutes"] += m
            playback_total += m
    playback_censored_total = 0.0
    for a2, b2 in merge_intervals(pb_cens_ivs):
        for iso, p0, p1 in didx.split(a2, b2):
            m = (p1 - p0) / 60.0
            tot[iso]["playback_censored_minutes"] += m
            playback_censored_total += m

    # ---- wifi bands (label holds from its event until the next wifi event)
    wifi_segs = []
    for i, (t, label) in enumerate(wifi):
        end = wifi[i + 1][0] if i + 1 < len(wifi) else data_end
        if end > t:
            wifi_segs.append((t, end, label))
    labels = sorted({lab for _, _, lab in wifi_segs})
    wifi_minutes = collections.defaultdict(float)
    for a, b, label in wifi_segs:
        for iso, p0, p1 in didx.split(a, b):
            wifi_minutes[label] += (p1 - p0) / 60.0
            timeline[iso]["wifi"].append((p0, p1, "wifi", label))

    # ---- health finishing
    active_total = sum(tot[i]["active_minutes"] for i in isos)
    other_total = sum(per_day[i].get(FALLBACK_CATEGORY, 0.0) for i in isos)
    health["span_unclassified_percent_time"] = pct(other_total, active_total)
    health["span_unclassified_percent_count"] = pct(
        unclassified_count, unclassified_count + classified_count)
    health["days_with_active_time"] = sum(1 for i in isos if tot[i]["active_minutes"] > 0)
    event_days = set()
    for s in in_win:
        for iso, _, _ in didx.split(s.start, s.end):
            event_days.add(iso)
    for ts, *_rest in media:
        if lo <= ts < hi:
            event_days.add(local_date_iso(ts, tz))
    for ts, _ in ctrl:
        if lo <= ts < hi:
            event_days.add(local_date_iso(ts, tz))
    for ts, _ in wifi:
        if lo <= ts < hi:
            event_days.add(local_date_iso(ts, tz))
    health["days_with_any_event"] = len([i for i in isos if i in event_days])

    # ---- assemble aggregates
    total_active = active_total
    per_hour = [round(x, 2) for x in hour_total]
    agg_top = sorted(app_tot.items(), key=lambda kv: (-kv[1], kv[0][1]))
    top_apps = [{"category": c, "app": a, "minutes": r2(m), "percent": pct(m, total_active)}
                for (c, a), m in agg_top]
    cat_rows = []
    for (c, a, h), m in sorted(cat_app_hour.items(),
                               key=lambda kv: (order.index(kv[0][0]), kv[0][1], kv[0][2])):
        cat_rows.append({"category": c, "app": a, "hour": h, "minutes": r2(m)})

    per_day_out, per_day_pct, per_day_totals = {}, {}, {}
    for i in isos:
        active_i = tot[i]["active_minutes"]
        per_day_out[i] = {c: r2(m) for c, m in per_day[i].items()}
        per_day_pct[i] = {c: pct(m, active_i) for c, m in per_day[i].items()}
        t = {k: r2(v) for k, v in tot[i].items()}
        t["unclassified_percent"] = pct(per_day[i].get(FALLBACK_CATEGORY, 0.0), active_i)
        per_day_totals[i] = t

    totals = {
        "active_minutes": r2(total_active),
        "idle_span_minutes": r2(sum(tot[i]["idle_span_minutes"] for i in isos)),
        "media_minutes": r2(media_total),
        "playback_minutes": r2(playback_total),
        "playback_censored_minutes": r2(playback_censored_total),
        "afk_minutes": r2(sum(tot[i]["afk_minutes"] for i in isos)),
        "locked_minutes": r2(sum(tot[i]["locked_minutes"] for i in isos)),
        "category_minutes": {c: r2(sum(per_day[i][c] for i in isos)) for c in order},
        "category_percent": {c: pct(sum(per_day[i][c] for i in isos), total_active) for c in order},
    }

    channels = []
    for ch in sorted(channel_playing, key=lambda c: (-channel_playing[c], c)):
        channels.append({
            "channel": ch,
            "playing_minutes": r2(channel_playing[ch]),
            "tab_minutes": r2(channel_tab.get(ch, 0.0)),
            "videos": len(channel_titles[ch]),
        })
    hosts = [{"host": h, "tab_minutes": r2(m)}
             for h, m in sorted(host_minutes.items(), key=lambda kv: (-kv[1], kv[0]))]

    aggregates = {
        "schema_version": VERSION,
        "generated_at": dt.datetime.now(tz).isoformat(timespec="seconds"),
        "window": {"from": w_from.isoformat(), "to": w_to.isoformat(), "days": n_days,
                   "timezone": tz_name, "lookback_days": args.lookback_days,
                   "media_max_gap_minutes": args.media_max_gap},
        "categories": {"order": order, "source": cat_source, "patterns": cat_spec},
        "health": health,
        "days": isos,
        "per_day": per_day_out,               # per_day[date][category] = minutes
        "per_day_percent": per_day_pct,       # per_day_percent[date][category] = % of active
        "per_day_totals": per_day_totals,     # active, idle, media, afk, locked, unclassified %
        "per_day_hour": {i: [r2(x) for x in per_day_hour[i]] for i in isos},
        "per_hour": per_hour,                 # hour-of-day totals across the window
        "by_category_app_hour": cat_rows,
        "top_apps": top_apps,                 # sorted by minutes; report shows top 10
        "media_minutes": {
            "total": r2(media_total),
            "per_player": {p: r2(m) for p, m in sorted(media_per_player.items())},
            "per_service": media_per_service,
            "per_service_per_day": {i: {s: r2(m) for s, m in service_per_day[i].items()} for i in isos},
            "per_day": {i: r2(tot[i]["media_minutes"]) for i in isos},
            "service_source": media_service_source,
        },
        "channels": channels,                 # per-YouTube-channel playing + tab minutes
        "hosts": hosts,                       # tab-active minutes per browser host
        "afk_minutes": {"total": totals["afk_minutes"],
                        "per_day": {i: r2(tot[i]["afk_minutes"]) for i in isos}},
        "locked_minutes": {"total": totals["locked_minutes"],
                           "per_day": {i: r2(tot[i]["locked_minutes"]) for i in isos}},
        "wifi_minutes": {k: r2(v) for k, v in sorted(wifi_minutes.items())},
        "totals": totals,
    }

    day_bounds = {iso: didx.bounds[k] for k, iso in enumerate(isos)}
    return aggregates, timeline, day_bounds, tz, labels, cat_spec


# --------------------------------------------------------------------------
# HTML rendering (hand-rolled inline SVG)
# --------------------------------------------------------------------------

def esc(x) -> str:
    return html.escape(str(x), quote=True)


def hm(minutes: float) -> str:
    total = int(round(minutes))
    return f"{total // 60}h {total % 60:02d}m"


def color_map(order, labels_wifi):
    colors = {}
    extra = iter(EXTRA_COLORS)
    for c in order:
        if c in CAT_COLORS:
            colors[c] = CAT_COLORS[c]
        else:
            colors[c] = next(extra, "#888888")
    wifi = {lab: WIFI_COLORS[k % len(WIFI_COLORS)] for k, lab in enumerate(labels_wifi)}
    return colors, wifi


def svg_stacked_bars(aggr, order, colors):
    days = aggr["days"]
    label_w, bar_w, row_h = 96, 720, 22
    totals = [aggr["per_day_totals"][d]["active_minutes"] for d in days]
    scale_max = max(totals) if totals and max(totals) > 0 else 1.0
    width = label_w + bar_w + 110
    height = len(days) * row_h + 12
    out = [f'<svg width="{width}" height="{height}" role="img" aria-label="Stacked bars per category per day">']
    for k, d in enumerate(days):
        y = 6 + k * row_h
        out.append(f'<text x="{label_w - 6}" y="{y + 15}" text-anchor="end">{esc(d)}</text>')
        x = float(label_w)
        active = aggr["per_day_totals"][d]["active_minutes"]
        for c in order:
            m = aggr["per_day"][d].get(c, 0.0)
            if m <= 0:
                continue
            w = m / scale_max * bar_w
            p = aggr["per_day_percent"][d].get(c, 0.0)
            out.append(
                f'<rect x="{x:.1f}" y="{y}" width="{max(w, 0.5):.1f}" height="{row_h - 5}" '
                f'fill="{colors[c]}"><title>{esc(d)} {esc(c)}: {m:.1f} min ({p:.1f}%)</title></rect>')
            x += w
        out.append(f'<text x="{x + 5:.1f}" y="{y + 15}">{active:.1f} min</text>')
    out.append("</svg>")
    return "".join(out)


def heat_color(t):
    t = max(0.0, min(1.0, t))
    a, b = (240, 244, 255), (31, 78, 156)
    return "#{:02x}{:02x}{:02x}".format(*(round(a[k] + (b[k] - a[k]) * t) for k in range(3)))


def svg_heatmap(aggr):
    days = aggr["days"]
    label_w, cell_w, cell_h = 96, 28, 18
    width = label_w + 24 * cell_w + 8
    height = 22 + len(days) * cell_h + 6
    out = [f'<svg width="{width}" height="{height}" role="img" aria-label="Hour-of-day heatmap">']
    for h in range(0, 24, 3):
        out.append(f'<text x="{label_w + h * cell_w + cell_w / 2:.1f}" y="14" text-anchor="middle">{h:02d}</text>')
    for k, d in enumerate(days):
        y = 22 + k * cell_h
        out.append(f'<text x="{label_w - 6}" y="{y + 13}" text-anchor="end">{esc(d)}</text>')
        row = aggr["per_day_hour"][d]
        for h in range(24):
            v = row[h]
            x = label_w + h * cell_w
            out.append(
                f'<rect x="{x}" y="{y}" width="{cell_w - 2}" height="{cell_h - 2}" '
                f'fill="{heat_color(v / HEATMAP_FULL_MINUTES)}">'
                f'<title>{esc(d)} {h:02d}:00: {v:.1f} active min</title></rect>')
    out.append("</svg>")
    return "".join(out)


def svg_media_vs_active(aggr):
    days = aggr["days"]
    label_w, bar_w, bh = 96, 620, 9
    row_h = 40
    vals = [max(aggr["per_day_totals"][d].get("active_minutes", 0.0),
                aggr["per_day_totals"][d].get("media_minutes", 0.0),
                aggr["per_day_totals"][d].get("playback_minutes", 0.0))
            for d in days]
    scale = max(vals) if vals and max(vals) > 0 else 1.0
    width = label_w + bar_w + 150
    height = len(days) * row_h + 26
    out = [f'<svg width="{width}" height="{height}" role="img" aria-label="Media vs active time per day">',
           f'<rect x="{label_w}" y="4" width="10" height="10" fill="{ACTIVE_COLOR}"/>'
           f'<text x="{label_w + 14}" y="13">active (non-idle focus)</text>',
           f'<rect x="{label_w + 180}" y="4" width="10" height="10" fill="{MEDIA_COLOR}"/>'
           f'<text x="{label_w + 194}" y="13">media playing (MPRIS)</text>',
           f'<rect x="{label_w + 360}" y="4" width="10" height="10" fill="{PLAYBACK_COLOR}"/>'
           f'<text x="{label_w + 374}" y="13">video playback (idle-inhibit hint)</text>']
    for k, d in enumerate(days):
        y = 22 + k * row_h
        t_ = aggr["per_day_totals"][d]
        out.append(f'<text x="{label_w - 6}" y="{y + 13}" text-anchor="end">{esc(d)}</text>')
        bars = ((t_.get("active_minutes", 0.0), ACTIVE_COLOR),
                (t_.get("media_minutes", 0.0), MEDIA_COLOR),
                (t_.get("playback_minutes", 0.0), PLAYBACK_COLOR))
        for j, (val, col) in enumerate(bars):
            w = val / scale * bar_w
            yy = y + j * (bh + 2)
            out.append(f'<rect x="{label_w}" y="{yy}" width="{max(w, 0.5 if val > 0 else 0):.1f}" '
                       f'height="{bh}" fill="{col}"><title>{esc(d)}: {val:.1f} min</title></rect>')
            out.append(f'<text x="{label_w + w + 4:.1f}" y="{yy + 8}" font-size="10">{val:.1f}</text>')
    out.append("</svg>")
    return "".join(out)


def svg_timeline(aggr, timeline, day_bounds, colors, wifi_colors):
    days = aggr["days"]
    left, W = 96, 800
    row_h = 58
    out = [f'<svg width="{left + W + 20}" height="{24 + len(days) * row_h + 4}" role="img" '
           f'aria-label="Per-day timeline">']
    for h in range(0, 25, 3):
        x = left + W * h / 24
        out.append(f'<line x1="{x:.1f}" y1="18" x2="{x:.1f}" y2="{24 + len(days) * row_h}" stroke="#eee"/>')
        out.append(f'<text x="{x:.1f}" y="12" text-anchor="middle">{h:02d}</text>')
    for k, d in enumerate(days):
        y0 = 22 + k * row_h
        ds, de = day_bounds[d]
        span_s = de - ds

        def X(t):
            return left + (t - ds) / span_s * W

        def tooltip(p0, p1, label):
            a = dt.datetime.fromtimestamp(p0).strftime("%H:%M")
            b = dt.datetime.fromtimestamp(p1).strftime("%H:%M")
            return f"{a}-{b} {label}"

        out.append(f'<text x="{left - 6}" y="{y0 + 14}" text-anchor="end">{esc(d)}</text>')
        out.append(f'<rect x="{left}" y="{y0}" width="{W}" height="20" fill="#fafafa"/>')
        tl = timeline[d]
        for p0, p1, kind, alabel in merge_segments(tl["activity"]):
            col = IDLE_COLOR if kind == "idle" else colors.get(kind, "#888")
            label = "idle span" if kind == "idle" else f"{kind} ({alabel})"
            out.append(f'<rect x="{X(p0):.1f}" y="{y0}" width="{max(X(p1) - X(p0), 0.5):.1f}" height="20" '
                       f'fill="{col}"><title>{esc(tooltip(p0, p1, label))}</title></rect>')
        for p0, p1, _, _ in merge_segments(tl["media"]):
            out.append(f'<rect x="{X(p0):.1f}" y="{y0 + 23}" width="{max(X(p1) - X(p0), 0.5):.1f}" height="6" '
                       f'fill="{MEDIA_COLOR}"><title>{esc(tooltip(p0, p1, "media playing"))}</title></rect>')
        for p0, p1, _, _ in merge_segments(tl["afk"]):
            out.append(f'<rect x="{X(p0):.1f}" y="{y0 + 31}" width="{max(X(p1) - X(p0), 0.5):.1f}" height="6" '
                       f'fill="{AFK_COLOR}"><title>{esc(tooltip(p0, p1, "AFK (idle)"))}</title></rect>')
        for p0, p1, _, _ in merge_segments(tl["locked"]):
            out.append(f'<rect x="{X(p0):.1f}" y="{y0 + 31}" width="{max(X(p1) - X(p0), 0.5):.1f}" height="6" '
                       f'fill="{LOCK_COLOR}"><title>{esc(tooltip(p0, p1, "locked"))}</title></rect>')
        for p0, p1, _, label in merge_segments(tl["wifi"]):
            x0, x1 = X(p0), X(p1)
            w = max(x1 - x0, 0.5)
            out.append(f'<rect x="{x0:.1f}" y="{y0 + 40}" width="{w:.1f}" height="16" '
                       f'fill="{wifi_colors.get(label, "#ccc")}"><title>{esc(tooltip(p0, p1, "wifi: " + label))}</title></rect>')
            max_chars = int(w / 6.5)
            if max_chars >= 3:
                text = label if len(label) <= max_chars else label[: max_chars - 1] + "…"
                out.append(f'<text x="{x0 + 3:.1f}" y="{y0 + 52}" font-size="10">{esc(text)}</text>')
    out.append("</svg>")
    return "".join(out)


def legend_html(order, colors):
    parts = [f'<span><i class="sw" style="background:{colors[c]}"></i>{esc(c)}</span>' for c in order]
    return '<div class="legend">' + "".join(parts) + "</div>"


def health_html(h, aggr):
    rows = [
        ("Input directory", h["input_dir"]),
        ("Timezone", h["timezone"]),
        ("Category rules", h["category_source"]),
        ("Window", f'{aggr["window"]["from"]} to {aggr["window"]["to"]} ({h["window_days"]} days)'),
        ("Event files read", f'{len(h["files_read"])} ({", ".join(h["files_read"]) or "none"})'),
        ("Window days with no event file", f'{len(h["window_days_without_event_file"])} '
                                           f'({", ".join(h["window_days_without_event_file"]) or "none"})'),
        ("Days covered (any event)", f'{h["days_with_any_event"]} of {h["window_days"]}'),
        ("Days with active time", f'{h["days_with_active_time"]} of {h["window_days"]}'),
        ("Span events in window", f'{h["span_records_in_window"]} (idle-flagged: {h["span_idle_in_window"]}, '
                                  f'open: {h["span_open_read"]} read in total)'),
        ("Unclassified (other) share", f'{h["span_unclassified_percent_time"]:.1f}% of active time; '
                                       f'{h["span_unclassified_percent_count"]:.1f}% of active span events'),
        ("Overlapping spans", f'{h["span_overlaps_in_window"]} '
                              f'({h["span_overlap_seconds"] / 60:.1f} min double-covered)'),
        ("Media / control / wifi events", f'{h["media_events"]} / {h["control_events"]} / {h["wifi_events"]}'),
        ("Malformed lines / invalid events", f'{h["malformed_lines"]} / {h["invalid_events"] + h["span_invalid"]}'),
        ("Duplicate lines removed", str(h["duplicate_lines_removed"])),
        ("Unknown event types", json.dumps(h["unknown_types"]) if h["unknown_types"] else "none"),
        ("Control states still open at end of data", ", ".join(h["open_control_states_at_end"]) or "none"),
        ("Unreadable files", "; ".join(h["unreadable_files"]) or "none"),
    ]
    body = "".join(f"<tr><th>{esc(k)}</th><td>{esc(v)}</td></tr>" for k, v in rows)
    warn = ""
    if h["span_records_in_window"] == 0:
        warn = '<p class="warn">No span events in this window. Check --input and the date range.</p>'
    return f'{warn}<table class="health">{body}</table>'


def top_apps_html(aggr):
    rows = aggr["top_apps"][:10]
    if not rows:
        return '<p class="note">No active focus time in this window.</p>'
    body = []
    for k, r in enumerate(rows, 1):
        body.append(f'<tr><td>{k}</td><td>{esc(r["app"])}</td><td>{esc(r["category"])}</td>'
                    f'<td class="num">{r["minutes"]:.1f}</td><td class="num">{hm(r["minutes"])}</td>'
                    f'<td class="num">{r["percent"]:.1f}%</td></tr>')
    return ('<table><tr><th>#</th><th>App (class)</th><th>Category</th><th>Minutes</th>'
            '<th>Duration</th><th>% of active</th></tr>' + "".join(body) + "</table>")


def build_timeline_payload(timeline, day_bounds, colors, wifi_colors):
    """Flatten per-day timeline segments into a JSON payload for the zoomable view.

    Times are seconds-of-day (0..86400) so every row shares one x-axis that can
    be zoomed/panned. Labels carry the app (foot/hx), service or wifi name.
    """
    rows = []
    for iso in timeline:
        start = day_bounds[iso][0]
        segs = []
        for lane, key in (("activity", "activity"), ("media", "media"),
                          ("afk", "afk"), ("afk", "locked"), ("wifi", "wifi")):
            for p0, p1, kind, label in timeline[iso][key]:
                segs.append({"lane": lane, "t0": round(p0 - start, 1),
                             "t1": round(p1 - start, 1), "kind": kind, "label": label})
        segs.sort(key=lambda s: (s["lane"], s["t0"]))
        rows.append({"day": iso, "segs": segs})
    return {
        "days": list(timeline.keys()),
        "lanes": ["activity", "media", "afk", "wifi"],
        "catColors": colors,
        "wifiColors": wifi_colors,
        "special": {"idle": IDLE_COLOR, "media": MEDIA_COLOR,
                    "afk": AFK_COLOR, "locked": LOCK_COLOR},
        "rows": rows,
    }


TIMELINE_JS = r"""
(function () {
  var D = JSON.parse(document.getElementById('hm-tl-data').textContent);
  var wrap = document.getElementById('hm-tl-wrap');
  var svg = document.getElementById('hm-tl-svg');
  var tip = document.getElementById('hm-tl-tip');
  var NS = 'http://www.w3.org/2000/svg';
  var PADL = 84, PADR = 16, PADT = 24, ROWH = 62;
  var laneH = { activity: 22, media: 7, afk: 7, wifi: 13 };
  var laneY = { activity: 2, media: 27, afk: 36, wifi: 45 };
  var DAY = 86400;
  var z0 = 0, z1 = DAY, W = 1080, plotW = W - PADL - PADR;

  function X(t) { return PADL + (t - z0) / (z1 - z0) * plotW; }
  function fmt(t) {
    t = Math.max(0, Math.min(DAY, t));
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60);
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
  }
  function fmtDur(s) {
    s = Math.round(s); var m = Math.floor(s / 60);
    return m >= 60 ? (Math.floor(m / 60) + 'h ' + (m % 60) + 'm') : (m + 'm ' + (s % 60) + 's');
  }
  function color(seg) {
    if (seg.lane === 'activity') return seg.kind === 'idle' ? D.special.idle : (D.catColors[seg.kind] || '#888');
    if (seg.lane === 'media') return D.special.media;
    if (seg.lane === 'afk') return seg.kind === 'locked' ? D.special.locked : D.special.afk;
    return D.wifiColors[seg.label] || '#ccc';
  }
  function el(n, a) { var e = document.createElementNS(NS, n); for (var k in a) e.setAttribute(k, a[k]); return e; }
  function clear() { while (svg.firstChild) svg.removeChild(svg.firstChild); }

  function render() {
    clear();
    W = wrap.clientWidth || 1080;
    plotW = W - PADL - PADR;
    var height = PADT + D.rows.length * ROWH + 14;
    svg.setAttribute('width', W);
    svg.setAttribute('height', height);
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + height);
    var span = z1 - z0;
    var step = span > 12 * 3600 ? 3 * 3600 : span > 6 * 3600 ? 3600 : span > 2 * 3600 ? 1800
             : span > 3600 ? 600 : span > 900 ? 300 : 60;
    for (var t = Math.ceil(z0 / step) * step; t <= z1; t += step) {
      var x = X(t);
      svg.appendChild(el('line', { x1: x, y1: PADT - 6, x2: x, y2: PADT + D.rows.length * ROWH, stroke: '#eee' }));
      var tx = el('text', { x: x, y: PADT - 10, 'text-anchor': 'middle', 'font-size': 10 });
      tx.textContent = fmt(t); svg.appendChild(tx);
    }
    D.rows.forEach(function (row, ri) {
      var y0 = PADT + ri * ROWH;
      var lb = el('text', { x: PADL - 6, y: y0 + 16, 'text-anchor': 'end', 'font-size': 11 });
      lb.textContent = row.day; svg.appendChild(lb);
      D.lanes.forEach(function (lane) {
        svg.appendChild(el('rect', { x: PADL, y: y0 + laneY[lane], width: plotW, height: laneH[lane], fill: '#fafafa' }));
      });
      row.segs.forEach(function (seg) {
        var t0 = Math.max(seg.t0, z0), t1 = Math.min(seg.t1, z1);
        if (t1 <= t0) return;
        var r = el('rect', { x: X(t0), y: y0 + laneY[seg.lane], width: Math.max(X(t1) - X(t0), 0.6), height: laneH[seg.lane], fill: color(seg) });
        r.addEventListener('mousemove', function (ev) { showTip(ev, seg); });
        r.addEventListener('mouseleave', hideTip);
        svg.appendChild(r);
      });
    });
  }
  function showTip(ev, seg) {
    tip.style.display = 'block';
    tip.textContent = fmt(seg.t0) + '\u2013' + fmt(seg.t1) + ' \u00b7 ' + fmtDur(seg.t1 - seg.t0) + ' \u00b7 ' + (seg.label || seg.kind);
    var r = svg.getBoundingClientRect();
    tip.style.left = (ev.clientX - r.left + 12) + 'px';
    tip.style.top = (ev.clientY - r.top + 12) + 'px';
  }
  function hideTip() { tip.style.display = 'none'; }

  svg.addEventListener('wheel', function (ev) {
    ev.preventDefault();
    var r = svg.getBoundingClientRect();
    var frac = (ev.clientX - r.left - PADL) / plotW;
    var at = z0 + frac * (z1 - z0);
    var factor = ev.deltaY > 0 ? 1.25 : 0.8;
    var nz0 = at - (at - z0) * factor, nz1 = at + (z1 - at) * factor;
    if (nz1 - nz0 < 60) { nz0 = at - 30; nz1 = at + 30; }
    if (nz0 < 0) { nz1 -= nz0; nz0 = 0; }
    if (nz1 > DAY) { nz0 -= (nz1 - DAY); nz1 = DAY; }
    z0 = Math.max(0, nz0); z1 = Math.min(DAY, nz1);
    render();
  }, { passive: false });

  var dragging = false, dragX = 0, dragZ0 = 0, dragZ1 = 0;
  svg.addEventListener('mousedown', function (ev) { dragging = true; dragX = ev.clientX; dragZ0 = z0; dragZ1 = z1; ev.preventDefault(); });
  window.addEventListener('mouseup', function () { dragging = false; });
  window.addEventListener('mousemove', function (ev) {
    if (!dragging) return;
    var dt = -((ev.clientX - dragX) / plotW) * (dragZ1 - dragZ0);
    var span = dragZ1 - dragZ0;
    z0 = Math.max(0, Math.min(DAY - span, dragZ0 + dt)); z1 = z0 + span;
    render();
  });

  Array.prototype.forEach.call(document.querySelectorAll('.hm-tl-btn'), function (b) {
    b.addEventListener('click', function () {
      var hrs = parseFloat(b.getAttribute('data-hours'));
      if (!hrs) { z0 = 0; z1 = DAY; }
      else { var mid = (z0 + z1) / 2; z0 = Math.max(0, mid - hrs * 1800); z1 = Math.min(DAY, mid + hrs * 1800); }
      render();
    });
  });

  window.addEventListener('resize', render);
  render();
})();
"""


def interactive_timeline_html(payload):
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    data = data.replace("</", "<\\/")  # keep a stray </script> in a label from breaking out
    controls = (
        '<div class="tl-controls">'
        '<button class="hm-tl-btn" data-hours="0">24h</button>'
        '<button class="hm-tl-btn" data-hours="12">12h</button>'
        '<button class="hm-tl-btn" data-hours="6">6h</button>'
        '<button class="hm-tl-btn" data-hours="3">3h</button>'
        '<button class="hm-tl-btn" data-hours="1">1h</button>'
        '<button class="hm-tl-btn" data-hours="0.5">30m</button>'
        '<span class="note"> scroll to zoom · drag to pan · hover for detail</span>'
        '</div>'
    )
    return (
        controls
        + '<div id="hm-tl-wrap" class="tl-wrap">'
        + '<svg id="hm-tl-svg" role="img" aria-label="Zoomable per-day timeline"></svg>'
        + '<div id="hm-tl-tip" class="tl-tip"></div>'
        + '</div>'
        + '<script id="hm-tl-data" type="application/json">' + data + '</script>'
        + '<script>' + TIMELINE_JS + '</script>'
    )


def services_html(aggr):
    per_service = aggr["media_minutes"]["per_service"]
    if not per_service:
        return '<p class="note">No media playing recorded (or no service matched).</p>'
    rows = "".join(
        f'<tr><th>{esc(s)}</th><td class="num">{m:.1f}</td><td class="num">{hm(m)}</td></tr>'
        for s, m in sorted(per_service.items(), key=lambda kv: -kv[1]))
    return ('<table><tr><th>Service</th><th class="num">Minutes</th><th class="num">Duration</th></tr>'
            + rows + '</table>')


def channels_html(aggr):
    rows = aggr.get("channels") or []
    if not rows:
        return ('<p class="note">No per-channel data yet. This needs the companion browser extension '
                'reporting the active tab (channel + host) to hyprmon.</p>')
    body = []
    for k, r in enumerate(rows, 1):
        body.append(f'<tr><td>{k}</td><td>{esc(r["channel"])}</td>'
                    f'<td class="num">{r["playing_minutes"]:.1f}</td>'
                    f'<td class="num">{hm(r["playing_minutes"])}</td>'
                    f'<td class="num">{r["tab_minutes"]:.1f}</td>'
                    f'<td class="num">{r["videos"]}</td></tr>')
    return ('<table><tr><th>#</th><th>Channel</th><th class="num">Playing min</th>'
            '<th class="num">Playing</th><th class="num">Tab min</th><th class="num">Videos</th></tr>'
            + "".join(body) + '</table>')


def hosts_html(aggr):
    rows = (aggr.get("hosts") or [])[:15]
    if not rows:
        return ('<p class="note">No browsing tab time recorded. This needs the companion browser '
                'extension reporting the active tab.</p>')
    body = "".join(
        f'<tr><td>{esc(h["host"])}</td><td class="num">{h["tab_minutes"]:.1f}</td>'
        f'<td class="num">{hm(h["tab_minutes"])}</td></tr>' for h in rows)
    return ('<table><tr><th>Site (host)</th><th class="num">Tab min</th><th class="num">Duration</th></tr>'
            + body + '</table>')


CSS = """
body{font-family:system-ui,sans-serif;margin:24px;color:#222;max-width:1200px}
h1{font-size:22px;margin-bottom:4px} h2{font-size:17px;margin-top:34px;border-bottom:1px solid #ddd;padding-bottom:4px}
table{border-collapse:collapse;font-size:13px;margin-top:6px}
th,td{padding:3px 10px;border-bottom:1px solid #eee;text-align:left;vertical-align:top}
th.k,table.health th{width:260px;font-weight:600;color:#444}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.legend span{display:inline-block;margin:4px 14px 4px 0;font-size:12px}
.sw{display:inline-block;width:11px;height:11px;margin-right:4px;vertical-align:-1px}
.note{color:#666;font-size:12px} .warn{color:#a40000;font-weight:600}
.scroll{overflow-x:auto}
svg text{font-family:system-ui,sans-serif;font-size:11px;fill:#333}
.tl-controls{margin:8px 0}
.tl-controls button{font-size:12px;padding:3px 10px;margin-right:5px;border:1px solid #ccc;border-radius:4px;background:#fafafa;cursor:pointer}
.tl-controls button:hover{background:#eef}
.tl-wrap{position:relative;overflow-x:auto}
.tl-tip{display:none;position:absolute;pointer-events:none;background:#222;color:#fff;font-size:12px;
padding:4px 8px;border-radius:4px;white-space:nowrap;z-index:10;box-shadow:0 2px 6px rgba(0,0,0,.25)}
"""


def render_html(aggr, timeline, day_bounds, tz, wifi_labels, cat_spec):
    order = aggr["categories"]["order"]
    colors, wifi_colors = color_map(order, wifi_labels)
    tl_payload = build_timeline_payload(timeline, day_bounds, colors, wifi_colors)
    w = aggr["window"]
    t = aggr["totals"]
    summary = (f'Active {hm(t["active_minutes"])} · media playing {hm(t["media_minutes"])} · '
               f'AFK {hm(t["afk_minutes"])} · locked {hm(t["locked_minutes"])} · '
               f'idle-flagged spans {hm(t["idle_span_minutes"])}')
    cat_list = "".join(
        f'<tr><th>{esc(c)}</th><td>{t["category_minutes"][c]:.1f} min</td>'
        f'<td class="num">{t["category_percent"][c]:.1f}%</td></tr>' for c in order)
    wifi_rows = "".join(f'<tr><th>{esc(k)}</th><td>{v:.1f} min</td></tr>'
                        for k, v in aggr["wifi_minutes"].items()) or '<tr><td colspan="2">no wifi events</td></tr>'
    parts = [
        '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">',
        f'<title>hyprmon report {esc(w["from"])} to {esc(w["to"])}</title>',
        f"<style>{CSS}</style></head><body>",
        f'<h1>hyprmon report</h1><p class="note">{esc(w["from"])} to {esc(w["to"])} · '
        f'{esc(w["timezone"])} · generated {esc(aggr["generated_at"])}</p>',
        f"<p>{esc(summary)}</p>",
        "<h2>Data health</h2>", health_html(aggr["health"], aggr),
        "<h2>Category totals</h2>",
        f'<table>{cat_list}</table>',
        "<h2>1. Active minutes per category per day</h2>",
        legend_html(order, colors),
        '<div class="scroll">', svg_stacked_bars(aggr, order, colors), "</div>",
        "<h2>2. Hour-of-day heatmap (active minutes per hour)</h2>",
        '<p class="note">Cell intensity = active minutes in that local hour (full colour at 60 min).</p>',
        '<div class="scroll">', svg_heatmap(aggr), "</div>",
        "<h2>3. Top 10 apps</h2>", top_apps_html(aggr),
        "<h2>4. Media playing vs active time per day</h2>",
        '<p class="note">Media time = union of Playing intervals across players. A Playing run ends at the '
        f'player\'s next event; without one it is capped at {w["media_max_gap_minutes"]:g} min.</p>',
        '<div class="scroll">', svg_media_vs_active(aggr), "</div>",
        "<h2>5. Media by service</h2>",
        '<p class="note">Playing minutes grouped by service (YouTube, Spotify, …), so different kinds of '
        'media are counted apart.</p>', services_html(aggr),
        "<h2>6. YouTube channels</h2>",
        '<p class="note">Playing time per channel, joined from MPRIS playback and the active tab\'s '
        'channel. "Playing" is actual playback; "Tab" is focused-tab time.</p>', channels_html(aggr),
        "<h2>7. Browsing &mdash; focused tab time per site</h2>",
        '<p class="note">Time the browser was focused on each host. A domain matching a school rule '
        '(e.g. cvut.cz) is counted as school.</p>', hosts_html(aggr),
        "<h2>8. Per-day timeline (overview)</h2>",
        '<p class="note">Top bar: category colours (grey = idle-flagged spans). Then media (red), '
        'AFK (grey) / locked (black), wifi label band.</p>',
        '<div class="scroll">', svg_timeline(aggr, timeline, day_bounds, colors, wifi_colors), "</div>",
        "<h2>9. Detailed timeline (zoom &amp; pan)</h2>",
        '<p class="note">The same focus switches, inspectable. Lanes: focus (category colour, labelled '
        'foot/hx etc), media, AFK/lock, wifi.</p>',
        interactive_timeline_html(tl_payload),
        '<h3 style="font-size:14px">Wifi time per label</h3>', f"<table>{wifi_rows}</table>",
        '<h2>Category rules used</h2><table>',
    ]
    for name in order:
        pats = cat_spec.get(name, [])
        parts.append(f'<tr><th>{esc(name)}</th><td><code>{esc(" | ".join(pats) or "(fallback)")}</code></td></tr>')
    parts.append("</table></body></html>")
    return "".join(parts)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="hyprmon-report.py",
        description="Aggregate hyprmon event stores into aggregates.json and a self-contained report.html.")
    sel = p.add_argument_group("time window (pick one; default = all days present)")
    sel.add_argument("--day", metavar="YYYY-MM-DD", help="single local day")
    sel.add_argument("--week", metavar="YYYY-MM-DD",
                     help="ISO week (Mon-Sun) containing this date")
    sel.add_argument("--from", dest="from_", metavar="YYYY-MM-DD", help="first local day (inclusive)")
    sel.add_argument("--to", metavar="YYYY-MM-DD", help="last local day (inclusive)")
    p.add_argument("--input", default=DEFAULT_INPUT,
                   help=f"directory with events-YYYY-MM-DD.jsonl.gz (default {DEFAULT_INPUT})")
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help=f"TOML config with a [categories] table (default {DEFAULT_CONFIG})")
    p.add_argument("--out", default=DEFAULT_OUT, help=f"output directory (default {DEFAULT_OUT})")
    p.add_argument("--tz", metavar="IANA_ZONE",
                   help="timezone for day/hour bucketing (default: TZ env or /etc/localtime)")
    p.add_argument("--media-max-gap", type=float, default=DEFAULT_MEDIA_MAX_GAP_MIN, metavar="MIN",
                   help="max media Playing run when the player sent no Paused/Stopped (default %(default)s)")
    p.add_argument("--lookback-days", type=int, default=DEFAULT_LOOKBACK_DAYS,
                   help="extra day files read before the window for open state (default %(default)s)")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    args.config_explicit = args.config != DEFAULT_CONFIG
    try:
        if sum(bool(x) for x in (args.day, args.week, args.from_ or args.to)) > 1:
            raise UsageError("use only one of --day, --week, --from/--to")
        if args.media_max_gap <= 0:
            raise UsageError("--media-max-gap must be > 0")
        if args.lookback_days < 0:
            raise UsageError("--lookback-days must be >= 0")
        aggr, timeline, day_bounds, tz, wifi_labels, cat_spec = run_build(args)
    except UsageError as e:
        print(f"hyprmon-report: error: {e}", file=sys.stderr)
        return 2

    out = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out, exist_ok=True)
    agg_path = os.path.join(out, "aggregates.json")
    html_path = os.path.join(out, "report.html")
    with open(agg_path, "w", encoding="utf-8") as fh:
        json.dump(aggr, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    with open(html_path, "w", encoding="utf-8") as fh:
        fh.write(render_html(aggr, timeline, day_bounds, tz, wifi_labels, cat_spec))

    t = aggr["totals"]
    h = aggr["health"]
    print(f"window {aggr['window']['from']}..{aggr['window']['to']} ({aggr['window']['days']} days)")
    print(f"active {t['active_minutes']:.1f} min, media {t['media_minutes']:.1f} min, "
          f"afk {t['afk_minutes']:.1f} min, locked {t['locked_minutes']:.1f} min")
    print(f"span events in window: {h['span_records_in_window']}, "
          f"unclassified: {h['span_unclassified_percent_time']:.1f}% of active time")
    print(f"wrote {agg_path}")
    print(f"wrote {html_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
