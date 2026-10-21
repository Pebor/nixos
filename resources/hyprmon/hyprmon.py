#!/usr/bin/env python3
"""hyprmon - privacy-first activity logger for Hyprland.

A single stdlib-only file containing both the daemon and its CLI.

    hyprmon run          follow Hyprland's event socket and sample sensors (default)
    hyprmon status       self-check: socket, daemon, censor count, last events
    hyprmon doctor       validate config and environment
    hyprmon idle         record an idle control event   (hypridle listener)
    hyprmon active       record an active control event (hypridle resume)
    hyprmon locked       record a lock control event    (hypridle on_lock_cmd)
    hyprmon unlocked     record an unlock control event (hypridle on_unlock_cmd)

Storage: ~/.local/share/hyprmon/events-YYYY-MM-DD.jsonl.gz, one gzip member per
record (appends stay valid without rewriting the file), one JSON object per line.

Privacy rules enforced here:

* Window classes, titles, media titles and URLs are never written to stdout,
  stderr or the journal. Logs carry counts and event names only.
* [[censor]] rules run when a focus span closes, before anything is written.
  A dropped span is never persisted, and a redacted span stores the replacement.
* Raw Wi-Fi SSIDs are not persisted unless store_raw_ssid = true.
"""

from __future__ import annotations

import argparse
import dataclasses
import fcntl
import gzip
import json
import logging
import os
import pwd
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import time
import tomllib
import zlib
from collections import Counter
from collections.abc import Callable, Iterator, Mapping, Sequence
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

PROGRAM = "hyprmon"
LOG = logging.getLogger(PROGRAM)

EX_OK = 0
EX_FAILURE = 1
EX_USAGE = 2
EX_TEMPFAIL = 75  # another daemon instance already holds the lock

DEFAULT_RETENTION_DAYS = 14
DEFAULT_STORE_DIR = "~/.local/share/hyprmon"
DEFAULT_BATTERY_PATH = "/sys/class/power_supply/BAT0"
DEFAULT_PLACEHOLDERS = ("Zen is playing media", "Firefox is playing media")
REDACTED_TEXT = "[redacted]"
DEFAULT_CENSOR: tuple[Mapping[str, str], ...] = (
    {"match_title": r".*Private Browsing$|.*Anonymní prohlížení$", "action": "drop"},
    {"match_class": "zen-beta|helium", "match_title": "Incognito|Private", "action": "drop"},
)

SOCKET2_NAME = ".socket2.sock"
LOCK_FILE_NAME = "daemon.lock"
CONTROL_SOCKET_NAME = "control.sock"
STATUS_FILE_NAME = "status.json"
SOCKET_BACKOFF_MIN_S = 1.0
SOCKET_BACKOFF_MAX_S = 30.0
RECV_BYTES = 65536
MAX_PARTIAL_LINE = 1 << 20
COMMAND_TIMEOUT_S = 10.0
MAX_SLEEP_S = 60.0

LOCK_POLL_S = 30.0
MEDIA_POLL_S = 60.0
RESOURCE_POLL_S = 60.0
WIFI_POLL_S = 300.0
WIFI_MIN_GAP_S = 60.0
ROTATE_CHECK_S = 60.0
STATS_LOG_S = 600.0

MPRIS_PREFIX = "org.mpris.MediaPlayer2."
MPRIS_OBJECT = "/org/mpris/MediaPlayer2"
MPRIS_PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"

# Control command -> record type. The CLI writes these records; the daemon
# only applies the same state change to its in-memory view.
CONTROL_RECORD_TYPES = {"idle": "idle", "active": "active", "locked": "lock", "unlocked": "unlock"}
FOCUS_EVENTS = frozenset({"activewindow", "activewindowv2", "windowtitlev2"})


class ConfigError(Exception):
    """Invalid configuration. The message is safe to print."""


class SensorUnavailable(Exception):
    """A helper command or file a sensor needs is missing or failed."""


class AlreadyRunning(Exception):
    """Another daemon instance holds the instance lock."""

    def __init__(self, pid: int) -> None:
        super().__init__(f"already running (pid {pid})")
        self.pid = pid


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


IDLE_TYPES = frozenset({"idle", "active"})
LOCK_TYPES = frozenset({"lock", "unlock"})


def _boot_time() -> float:
    """Unix time the kernel booted, from /proc/stat. 0.0 when unavailable."""
    text = _read_text(Path("/proc/stat")) or ""
    for line in text.splitlines():
        if line.startswith("btime "):
            try:
                return float(line.split()[1])
            except (IndexError, ValueError):
                break
    return 0.0


def _current_user() -> str:
    return os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name


def _runtime_base() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR")
    return Path(base) if base else Path(f"/run/user/{os.getuid()}")


def hypr_root() -> Path:
    """Directory Hyprland uses for its per-instance sockets."""
    return _runtime_base() / "hypr"


def ipc_dir() -> Path:
    """Private runtime directory for the lock, control socket and status file."""
    return _runtime_base() / PROGRAM


def default_config_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    return Path(base).expanduser() / PROGRAM / f"{PROGRAM}.toml"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class CensorRule:
    title_re: re.Pattern[str] | None
    class_re: re.Pattern[str] | None
    action: str  # "drop" or "redact"
    replacement: str

    def matches(self, window_class: str | None, title: str | None) -> bool:
        """A rule matches when every matcher it defines matches (AND)."""
        if self.class_re is not None:
            if window_class is None or self.class_re.search(window_class) is None:
                return False
        if self.title_re is not None:
            if title is None or self.title_re.search(title) is None:
                return False
        return True


@dataclasses.dataclass(frozen=True)
class Config:
    source: Path | None
    store_dir: Path
    retention_days: int
    battery_path: Path
    store_raw_ssid: bool
    wifi_labels: Mapping[str, str]
    media_placeholders: frozenset[str]
    censor_rules: tuple[CensorRule, ...]


_TOP_LEVEL_KEYS = frozenset(
    {
        "store_dir",
        "retention_days",
        "battery_path",
        "store_raw_ssid",
        "wifi_labels",
        "media_placeholder_titles",
        "censor",
    }
)
_CENSOR_KEYS = frozenset({"match_title", "match_class", "action", "replacement"})


def _check_keys(table: Mapping[str, Any], allowed: frozenset[str], where: str) -> None:
    unknown = sorted(set(table) - allowed)
    if unknown:
        raise ConfigError(f"{where}: unknown key(s): {', '.join(unknown)}")


def _typed(table: Mapping[str, Any], key: str, kind: type, default: Any, where: str) -> Any:
    value = table.get(key, default)
    is_bool_for_int = kind is int and isinstance(value, bool)
    if not isinstance(value, kind) or is_bool_for_int:
        raise ConfigError(f"{where}: '{key}' must be a {kind.__name__}")
    return value


def _compile_optional(table: Mapping[str, Any], key: str, where: str) -> re.Pattern[str] | None:
    raw = table.get(key)
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise ConfigError(f"{where}: '{key}' must be a string regex")
    try:
        return re.compile(raw)
    except re.error as exc:
        raise ConfigError(f"{where}: invalid regex in '{key}': {exc.msg}") from None


def _parse_censor_entry(entry: Any, index: int) -> CensorRule:
    where = f"[[censor]] entry {index + 1}"
    if not isinstance(entry, Mapping):
        raise ConfigError(f"{where} must be a table")
    _check_keys(entry, _CENSOR_KEYS, where)
    title_re = _compile_optional(entry, "match_title", where)
    class_re = _compile_optional(entry, "match_class", where)
    if title_re is None and class_re is None:
        raise ConfigError(f"{where} needs match_title and/or match_class")
    action = entry.get("action")
    if action not in ("drop", "redact"):
        raise ConfigError(f"{where}: action must be 'drop' or 'redact'")
    replacement = _typed(entry, "replacement", str, REDACTED_TEXT, where)
    return CensorRule(title_re, class_re, action, replacement)


def parse_config(data: Mapping[str, Any], source: Path | None) -> Config:
    """Validate a decoded TOML document and build a Config."""
    _check_keys(data, _TOP_LEVEL_KEYS, "config")
    retention = _typed(data, "retention_days", int, DEFAULT_RETENTION_DAYS, "config")
    if retention < 1:
        raise ConfigError("config: 'retention_days' must be at least 1")
    labels = _typed(data, "wifi_labels", dict, {}, "config")
    if not all(isinstance(label, str) for label in labels.values()):
        raise ConfigError("config: [wifi_labels] values must be strings")
    placeholders = _typed(data, "media_placeholder_titles", list, list(DEFAULT_PLACEHOLDERS), "config")
    if not all(isinstance(title, str) for title in placeholders):
        raise ConfigError("config: 'media_placeholder_titles' must be a list of strings")
    # The built-in private-browsing rules apply unless the file sets [[censor]]
    # itself. An explicit `censor = []` disables censoring.
    censor_entries = data.get("censor", list(DEFAULT_CENSOR))
    if not isinstance(censor_entries, list):
        raise ConfigError("config: 'censor' must be an array of tables")
    return Config(
        source=source,
        store_dir=Path(_typed(data, "store_dir", str, DEFAULT_STORE_DIR, "config")).expanduser(),
        retention_days=retention,
        battery_path=Path(_typed(data, "battery_path", str, DEFAULT_BATTERY_PATH, "config")),
        store_raw_ssid=_typed(data, "store_raw_ssid", bool, False, "config"),
        wifi_labels=dict(labels),
        media_placeholders=frozenset(placeholders),
        censor_rules=tuple(_parse_censor_entry(e, i) for i, e in enumerate(censor_entries)),
    )


def load_config(explicit: Path | None) -> Config:
    path = explicit if explicit is not None else default_config_path()
    if not path.exists():
        if explicit is not None:
            raise ConfigError(f"config file not found: {path}")
        return parse_config({}, None)
    try:
        with path.open("rb") as fh:
            data = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from None
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc.strerror}") from None
    return parse_config(data, path)


def _first_rule(rules: Sequence[CensorRule], window_class: str | None, title: str | None) -> CensorRule | None:
    """First matching rule wins."""
    for rule in rules:
        if rule.matches(window_class, title):
            return rule
    return None


def _rule_number(rules: Sequence[CensorRule], window_class: str | None, title: str | None) -> int | None:
    """1-based index of the first matching rule, for status output that must not show titles."""
    for number, rule in enumerate(rules, start=1):
        if rule.matches(window_class, title):
            return number
    return None


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

_FILE_PREFIX = "events-"
_FILE_SUFFIX = ".jsonl.gz"


def _day_of(path: Path) -> date | None:
    name = path.name
    if not (name.startswith(_FILE_PREFIX) and name.endswith(_FILE_SUFFIX)):
        return None
    try:
        return datetime.strptime(name[len(_FILE_PREFIX) : -len(_FILE_SUFFIX)], "%Y-%m-%d").date()
    except ValueError:
        return None


def _read_records(path: Path) -> Iterator[dict[str, Any]]:
    """Yield the records of one store file, stopping at a damaged member."""
    try:
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            for line in fh:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if isinstance(record, dict):
                    yield record
    except (OSError, EOFError, UnicodeDecodeError, zlib.error):
        # A torn tail from a crash, or a file being repaired, ends the read.
        # Everything before the damage has already been yielded.
        LOG.debug("store read stopped early at a damaged member")


_REPAIR_CHUNK = 1 << 16


def _valid_prefix_length(data: bytes) -> int:
    """Byte length of the leading run of complete, CRC-valid gzip members.

    Each member is fed in chunks so that the work stays linear in the file size.
    """
    total = len(data)
    offset = 0
    while offset < total:
        member = zlib.decompressobj(zlib.MAX_WBITS | 16)  # gzip wrapper, checks CRC
        pos = offset
        try:
            while not member.eof and pos < total:
                chunk = data[pos : pos + _REPAIR_CHUNK]
                member.decompress(chunk)
                pos += len(chunk)
        except zlib.error:
            break
        if not member.eof:
            break  # truncated member
        offset = pos - len(member.unused_data)
    return offset


def _write_fully(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


class Store:
    """Daily gzip store. Every append is one self-contained gzip member."""

    def __init__(self, directory: Path) -> None:
        self._directory = directory

    @property
    def directory(self) -> Path:
        return self._directory

    def path_for(self, day: date) -> Path:
        return self._directory / f"{_FILE_PREFIX}{day.isoformat()}{_FILE_SUFFIX}"

    def files(self) -> list[Path]:
        if not self._directory.is_dir():
            return []
        return sorted(p for p in self._directory.iterdir() if _day_of(p) is not None)

    def append(self, record: Mapping[str, Any]) -> None:
        """Append one record under an exclusive flock, so CLI and daemon can both write."""
        day = datetime.fromtimestamp(float(record["ts"])).date()
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        member = gzip.compress(line.encode("utf-8"))
        self._directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(self.path_for(day), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            start = os.fstat(fd).st_size
            try:
                _write_fully(fd, member)
            except OSError:
                # A partial member would hide every later record; roll it back.
                os.ftruncate(fd, start)
                raise
        finally:
            os.close(fd)  # closing the descriptor releases the flock

    def repair(self, path: Path) -> int:
        """Truncate a damaged tail left by a crash. Returns the number of bytes removed."""
        try:
            fd = os.open(path, os.O_RDWR)
        except FileNotFoundError:
            return 0
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            data = os.pread(fd, os.fstat(fd).st_size, 0)
            good = _valid_prefix_length(data)
            if good < len(data):
                os.ftruncate(fd, good)
            return len(data) - good
        finally:
            os.close(fd)

    def repair_all(self) -> int:
        return sum(self.repair(path) for path in self.files())

    def tail(self, count: int) -> list[dict[str, Any]]:
        """Return the last ``count`` records in chronological order."""
        chunks: list[list[dict[str, Any]]] = []
        total = 0
        for path in reversed(self.files()):
            records = list(_read_records(path))
            chunks.append(records)
            total += len(records)
            if total >= count:
                break
        flat = [record for chunk in reversed(chunks) for record in chunk]
        return flat[-count:] if count else []

    def last_record_since(self, since: float, types: frozenset[str]) -> str | None:
        """Type of the newest record of one of ``types`` written at or after ``since``."""
        if since <= 0:
            return None  # boot time unknown: refuse to guess from old records
        for path in reversed(self.files()):
            for record in reversed(list(_read_records(path))):
                ts = record.get("ts")
                if not isinstance(ts, (int, float)) or ts < since:
                    return None
                if record.get("type") in types:
                    return str(record["type"])
        return None

    def prune(self, retention_days: int, today: date) -> int:
        """Delete files older than ``retention_days``; today counts as one day."""
        cutoff = today - timedelta(days=retention_days - 1)
        removed = 0
        for path in self.files():
            day = _day_of(path)
            if day is not None and day < cutoff:
                path.unlink(missing_ok=True)
                removed += 1
        return removed


# ---------------------------------------------------------------------------
# Hyprland event parsing and socket client
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class SocketLocation:
    path: Path
    instance: str


def event_socket_candidates(override: Path | None = None) -> list[SocketLocation]:
    """Possible socket2 paths, best first.

    Order: explicit --socket; then $HYPRLAND_INSTANCE_SIGNATURE when exported;
    then every ``*/.socket2.sock`` under the hypr root, newest first. Stale
    sockets from a crashed Hyprland are still listed, so callers must try
    them in order and not stop at the first one.
    """
    if override is not None:
        return [SocketLocation(override, override.parent.name)] if override.is_socket() else []
    root = hypr_root()
    found: list[SocketLocation] = []
    preferred = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if preferred and (root / preferred / SOCKET2_NAME).is_socket():
        found.append(SocketLocation(root / preferred / SOCKET2_NAME, preferred))
    by_age = sorted(
        (p for p in root.glob(f"*/{SOCKET2_NAME}") if p.is_socket()),
        key=_mtime,
        reverse=True,
    )
    for path in by_age:
        if all(path != loc.path for loc in found):
            found.append(SocketLocation(path, path.parent.name))
    return found


def find_event_socket(override: Path | None = None) -> SocketLocation | None:
    """The most likely socket2 location, or None when Hyprland is not running."""
    candidates = event_socket_candidates(override)
    return candidates[0] if candidates else None


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return -1.0


def parse_event(line: str) -> tuple[str, str] | None:
    """Split 'EVENT>>DATA' on the first '>>' only; DATA may itself contain '>>'."""
    name, sep, data = line.partition(">>")
    return (name, data) if sep else None


def _normalise_address(raw: str) -> str:
    """Hyprland window addresses carry a 0x prefix. Some events omit it, so add it when missing."""
    raw = raw.strip()
    if not raw:
        return ""
    return raw if raw.startswith("0x") else "0x" + raw


def _workspace_name(client: Mapping[str, Any]) -> str | None:
    workspace = client.get("workspace")
    if isinstance(workspace, dict) and isinstance(workspace.get("name"), str):
        return workspace["name"]
    return None


class EventStream:
    """Non-blocking client for socket2 with exponential-backoff reconnects."""

    def __init__(self, override: Path | None, clock: Callable[[], float]) -> None:
        self._override = override
        self._clock = clock
        self._sock: socket.socket | None = None
        self._pending = b""
        self._backoff = SOCKET_BACKOFF_MIN_S
        self._retry_at = 0.0
        self._announced_wait = False
        self.instance: str | None = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    @property
    def retry_at(self) -> float:
        return self._retry_at

    def fileno(self) -> int:
        if self._sock is None:
            raise RuntimeError("event stream is not connected")
        return self._sock.fileno()

    def connect_if_due(self) -> bool:
        """Try to connect when the backoff allows. Returns True on a new connection."""
        if self._sock is not None or self._clock() < self._retry_at:
            return False
        candidates = event_socket_candidates(self._override)
        if not candidates:
            if not self._announced_wait:
                LOG.info("waiting for Hyprland event socket")
                self._announced_wait = True
            self._schedule_retry()
            return False
        for location in candidates:
            sock = self._try_connect(location)
            if sock is not None:
                self._adopt(sock, location)
                return True
        LOG.warning("no Hyprland event socket accepted a connection; retrying")
        self._schedule_retry()
        return False

    def _try_connect(self, location: SocketLocation) -> socket.socket | None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(location.path))
        except OSError:
            sock.close()  # stale socket file, or Hyprland is restarting
            return None
        return sock

    def _adopt(self, sock: socket.socket, location: SocketLocation) -> None:
        sock.setblocking(False)
        self._sock = sock
        self._pending = b""
        self._announced_wait = False
        self.instance = location.instance
        LOG.info("connected to Hyprland event socket (instance %s)", location.instance)

    def read_lines(self) -> list[str] | None:
        """Return complete lines read so far, or None if the connection was lost."""
        if self._sock is None:
            return None
        try:
            chunk = self._sock.recv(RECV_BYTES)
        except BlockingIOError:
            return []
        except OSError as exc:
            self._lose(exc.strerror or type(exc).__name__)
            return None
        if not chunk:
            self._lose("end of stream")
            return None
        # Reset backoff only once the peer has actually sent data. A socket
        # that accepts and immediately closes would otherwise retry at 1s forever.
        self._backoff = SOCKET_BACKOFF_MIN_S
        *complete, self._pending = (self._pending + chunk).split(b"\n")
        if len(self._pending) > MAX_PARTIAL_LINE:
            self._lose("oversized event line")
            return None
        return [raw.decode("utf-8", "replace") for raw in complete if raw]

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def _lose(self, reason: str) -> None:
        self.close()
        LOG.warning("event socket lost (%s); reconnecting", reason)
        self._schedule_retry()

    def _schedule_retry(self) -> None:
        self._retry_at = self._clock() + self._backoff
        self._backoff = min(self._backoff * 2, SOCKET_BACKOFF_MAX_S)


# ---------------------------------------------------------------------------
# Recording: focus spans, lock and idle state, privacy filtering
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class _Window:
    window_class: str
    title: str
    workspace: str | None


@dataclasses.dataclass
class _OpenSpan:
    window_class: str
    title: str
    started: float
    workspace: str | None


@dataclasses.dataclass(frozen=True)
class MediaSnapshot:
    player: str  # bus name with the MPRIS prefix removed
    status: str
    title: str | None
    url: str | None


def _url_host(url: str | None) -> str | None:
    """Only the host of a media URL is ever stored, never path or query."""
    if not url:
        return None
    try:
        return urlsplit(url).hostname or None
    except ValueError:
        return None


class Recorder:
    """Turns Hyprland events and sensor samples into privacy-filtered records."""

    def __init__(self, config: Config, store: Store, clock: Callable[[], float] = time.time) -> None:
        self._config = config
        self._store = store
        self._clock = clock
        self._handlers: dict[str, Callable[[str], None]] = {
            "activewindow": self._on_activewindow,
            "activewindowv2": self._on_activewindowv2,
            "openwindow": self._on_openwindow,
            "closewindow": self._on_closewindow,
            "windowtitlev2": self._on_windowtitlev2,
            "movewindowv2": self._on_movewindowv2,
            "focusedmonv2": self._on_focusedmonv2,
            "configreloaded": self._on_configreloaded,
        }
        self._windows: dict[str, _Window] = {}
        self._focus_addr: str | None = None
        self._focus_class = ""
        self._focus_title = ""
        self._span: _OpenSpan | None = None
        self._media_state: dict[str, tuple[str, str | None, str | None]] = {}
        self._wifi_state: tuple[str, str | None] | None = None
        self.idle = False
        self.locked = False
        self.stats: Counter[str] = Counter()

    # -- Hyprland events ----------------------------------------------------

    def handle_hypr_event(self, name: str, data: str) -> bool:
        """Apply one event. Returns True if the event concerns focus."""
        handler = self._handlers.get(name)
        if handler is None:
            self.stats["events_ignored"] += 1
            return False
        handler(data)
        return name in FOCUS_EVENTS

    def _on_activewindow(self, data: str) -> None:
        window_class, _, title = data.partition(",")
        # activewindowv2 always follows and supplies the address. Clearing it
        # here stops a title event for the previous window from being applied
        # to the new focus during that gap.
        self._focus_addr = None
        self._set_focus(window_class, title)

    def _on_activewindowv2(self, data: str) -> None:
        self._focus_addr = _normalise_address(data) or None
        if self._span is not None:
            self._span.workspace = self._workspace_for(self._focus_addr)

    def _on_openwindow(self, data: str) -> None:
        fields = data.split(",", 3)
        if len(fields) != 4:
            self.stats["events_malformed"] += 1
            return
        address, workspace, window_class, title = fields
        self._windows[_normalise_address(address)] = _Window(window_class, title, workspace)

    def _on_closewindow(self, data: str) -> None:
        address = _normalise_address(data)
        self._windows.pop(address, None)
        if address == self._focus_addr:
            self._focus_addr = None

    def _on_windowtitlev2(self, data: str) -> None:
        address, _, title = data.partition(",")
        address = _normalise_address(address)
        window = self._windows.get(address)
        if window is not None:
            window.title = title
        if address and address == self._focus_addr:
            self._set_focus(self._focus_class, title)

    def _on_movewindowv2(self, data: str) -> None:
        fields = data.split(",", 2)
        if len(fields) != 3:
            self.stats["events_malformed"] += 1
            return
        address, _workspace_id, workspace = fields
        window = self._windows.get(_normalise_address(address))
        if window is not None:
            window.workspace = workspace

    def _on_focusedmonv2(self, _data: str) -> None:
        self.stats["monitor_focus_changes"] += 1

    def _on_configreloaded(self, _data: str) -> None:
        # Reloading Hyprland's own config does not change hyprmon's config.
        self.stats["hyprland_config_reloads"] += 1

    def seed(self, clients: Sequence[Mapping[str, Any]], active: Mapping[str, Any]) -> None:
        """Load the window list and focus from hyprctl after (re)connecting.

        Hyprland does not replay state on connect, so without this the window
        focused at startup would go unrecorded until the next focus change.
        """
        for client in clients:
            address = _normalise_address(str(client.get("address", "")))
            if address:
                self._windows[address] = _Window(
                    str(client.get("class", "")), str(client.get("title", "")), _workspace_name(client)
                )
        # An empty activewindow means nothing is focused; clear any stale focus.
        self._focus_addr = _normalise_address(str(active.get("address", ""))) or None
        self._set_focus(str(active.get("class", "")), str(active.get("title", "")))
        self.stats["seeded_windows"] = len(self._windows)

    # -- focus spans --------------------------------------------------------

    def _workspace_for(self, address: str | None) -> str | None:
        window = self._windows.get(address) if address else None
        return window.workspace if window is not None else None

    def _set_focus(self, window_class: str, title: str) -> None:
        self._focus_class = window_class
        self._focus_title = title
        if self._span is not None and (self._span.window_class, self._span.title) == (window_class, title):
            return
        self._close_span()
        self._open_span_if_allowed()

    def _open_span_if_allowed(self, at: float | None = None) -> None:
        if self._span is not None or self.idle or self.locked:
            return
        if not (self._focus_class or self._focus_title):
            return
        self._span = _OpenSpan(
            self._focus_class,
            self._focus_title,
            self._boundary(at),
            self._workspace_for(self._focus_addr),
        )

    def _boundary(self, at: float | None) -> float:
        """A span boundary. A control record's own timestamp is used when it is
        in the past, so spans end exactly at the lock or idle event."""
        now = self._clock()
        return now if at is None else min(at, now)

    def _close_span(self, at: float | None = None) -> None:
        span, self._span = self._span, None
        if span is None:
            return
        ended = self._boundary(at)
        if ended <= span.started:
            self.stats["spans_empty"] += 1  # e.g. focus flipped back in the same instant
            return
        rule = _first_rule(self._config.censor_rules, span.window_class, span.title)
        if rule is not None and rule.action == "drop":
            self.stats["spans_dropped"] += 1
            return
        record: dict[str, Any] = {
            "ts": span.started,
            "type": "span",
            "start_ts": span.started,
            "end_ts": ended,
            "class": span.window_class,
            "title": span.title,
            "workspace": span.workspace,
        }
        if rule is not None:
            record["title"] = rule.replacement
            record["redacted"] = True
            self.stats["spans_redacted"] += 1
        self._store.append(record)
        self.stats["spans_written"] += 1

    # -- lock and idle ------------------------------------------------------

    def set_idle(self, idle: bool, at: float | None = None) -> None:
        if idle == self.idle:
            return
        self._close_span(at)
        self.idle = idle
        self._open_span_if_allowed(at)

    def set_locked(self, locked: bool, *, record: bool, at: float | None = None) -> None:
        """Apply a lock state. ``record`` writes a lock/unlock record; pass it only
        for transitions the daemon observed itself. Control-socket updates set
        False because the CLI has already written that record."""
        if locked == self.locked:
            return
        self._close_span(at)
        self.locked = locked
        if record:
            self._store.append({"ts": self._boundary(at), "type": "lock" if locked else "unlock"})
            self.stats["lock_records"] += 1
        self._open_span_if_allowed(at)

    def flush(self) -> None:
        """Close the open span (shutdown)."""
        self._close_span()

    def forget_windows(self) -> None:
        """Drop window state when the socket is lost; Hyprland may have restarted."""
        self._close_span()
        self._windows.clear()
        self._focus_addr = None
        self._focus_class = ""
        self._focus_title = ""

    # -- media --------------------------------------------------------------

    def _dropped_window_open(self) -> bool:
        """True if any open window, focused or not, matches a drop rule.

        Browsers can route private-window media through a shared MPRIS
        session, so one private window anywhere suppresses media titles.
        """
        windows: list[tuple[str, str]] = [(w.window_class, w.title) for w in self._windows.values()]
        if self._focus_class or self._focus_title:
            windows.append((self._focus_class, self._focus_title))
        return any(self._is_dropped(cls, title) for cls, title in windows)

    def _is_dropped(self, window_class: str | None, title: str | None) -> bool:
        rule = _first_rule(self._config.censor_rules, window_class, title)
        return rule is not None and rule.action == "drop"

    def _media_detail(self, snapshot: MediaSnapshot) -> tuple[str | None, str | None]:
        """Return (title, url_host) to store. (None, None) means status only."""
        title = snapshot.title
        if not title:
            return None, None
        if title in self._config.media_placeholders:
            # Browsers hide private-window media behind a placeholder title.
            self.stats["media_status_only"] += 1
            return None, None
        if self._dropped_window_open():
            self.stats["media_status_only"] += 1
            return None, None
        if self._is_dropped(None, title):
            self.stats["media_status_only"] += 1
            return None, None
        rule = _first_rule(self._config.censor_rules, None, title)
        stored_title = title if rule is None else rule.replacement
        return stored_title, _url_host(snapshot.url)

    def record_media(self, players: Sequence[MediaSnapshot]) -> None:
        """Store media changes. A player that disappears gets a 'closed' record."""
        now = self._clock()
        seen: set[str] = set()
        for snapshot in players:
            seen.add(snapshot.player)
            title, host = self._media_detail(snapshot)
            state = (snapshot.status, title, host)
            if self._media_state.get(snapshot.player) == state:
                continue
            self._media_state[snapshot.player] = state
            record: dict[str, Any] = {
                "ts": now,
                "type": "media",
                "player": snapshot.player,
                "status": snapshot.status,
            }
            if title is not None:
                record["title"] = title
            if host is not None:
                record["url_host"] = host
            self._store.append(record)
            self.stats["media_records"] += 1
        for gone in sorted(set(self._media_state) - seen):
            del self._media_state[gone]
            self._store.append({"ts": now, "type": "media", "player": gone, "status": "closed"})
            self.stats["media_records"] += 1

    # -- wifi, resources ----------------------------------------------------

    def record_wifi(self, ssid: str | None) -> None:
        """Store the Wi-Fi label. The raw SSID is written only when store_raw_ssid is set."""
        label = "none" if ssid is None else self._config.wifi_labels.get(ssid, "other")
        stored_ssid = ssid if (self._config.store_raw_ssid and ssid is not None) else None
        state = (label, stored_ssid)
        if state == self._wifi_state:
            return
        self._wifi_state = state
        record: dict[str, Any] = {"ts": self._clock(), "type": "wifi", "label": label}
        if stored_ssid is not None:
            record["ssid"] = stored_ssid
        self._store.append(record)
        self.stats["wifi_records"] += 1

    def record_resources(self, sample: Mapping[str, Any]) -> None:
        self._store.append({"ts": self._clock(), "type": "resources", **sample})
        self.stats["resource_records"] += 1

    # -- introspection ------------------------------------------------------

    def snapshot(self) -> dict[str, Any]:
        """Current state for status.json. It holds no window class or title,
        only whether a window is focused and what the censor rules would do."""
        focus: dict[str, Any] | None = None
        if (self._focus_class or self._focus_title) and not self.locked:
            # While locked the daemon knows about windows but must not report them.
            rule_no = _rule_number(self._config.censor_rules, self._focus_class, self._focus_title)
            focus = {"censor": "keep" if rule_no is None else self._config.censor_rules[rule_no - 1].action,
                     "rule": rule_no}
        return {
            "idle": self.idle,
            "locked": self.locked,
            "focus": focus,
            "open_windows": len(self._windows),
            "stats": dict(self.stats),
        }


# ---------------------------------------------------------------------------
# Sensors
# ---------------------------------------------------------------------------


def _run_command(argv: Sequence[str], env: Mapping[str, str] | None = None) -> str:
    """Run a helper and return stdout. Errors name the command, never its output."""
    try:
        result = subprocess.run(
            list(argv),
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=COMMAND_TIMEOUT_S,
            check=False,
            env=None if env is None else dict(env),
        )
    except FileNotFoundError:
        raise SensorUnavailable(f"{argv[0]} is not installed") from None
    except subprocess.TimeoutExpired:
        raise SensorUnavailable(f"{argv[0]} timed out") from None
    except OSError:
        raise SensorUnavailable(f"{argv[0]} could not be started") from None
    if result.returncode != 0:
        raise SensorUnavailable(f"{argv[0]} exited with status {result.returncode}")
    return result.stdout


# busctl renders D-Bus values as tokens: quoted strings or bare words.
_BUS_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|(\S+)')
_STRING_TYPES = frozenset({"s", "o", "g"})
_SCALAR_TYPES = frozenset({"b", "y", "n", "q", "i", "u", "x", "t", "d"})


class UnsupportedVariant(ValueError):
    """busctl printed a D-Bus type this parser does not handle."""


def _unescape(text: str) -> str:
    return re.sub(r"\\(.)", r"\1", text)


def _bus_tokens(text: str) -> Iterator[str]:
    for match in _BUS_TOKEN.finditer(text):
        quoted, bare = match.groups()
        yield _unescape(quoted) if quoted is not None else bare


def _next_token(tokens: Iterator[str]) -> str:
    try:
        return next(tokens)
    except StopIteration:
        raise ValueError("unexpected end of busctl output") from None


def _read_value(tokens: Iterator[str]) -> Any:
    signature = _next_token(tokens)
    if signature in _STRING_TYPES:
        return _next_token(tokens)
    if signature == "as":
        count = int(_next_token(tokens))
        return [_next_token(tokens) for _ in range(count)]
    if signature in _SCALAR_TYPES:
        return _next_token(tokens)
    raise UnsupportedVariant(signature)


def parse_variant(text: str) -> Any:
    """Parse busctl's rendering of one value, e.g. ``s "Playing"``."""
    return _read_value(_bus_tokens(text))


def parse_string_map(text: str) -> dict[str, Any]:
    """Parse busctl's rendering of an a{sv} property.

    Entries are decoded up to the first unsupported type. The parser cannot
    skip an unknown value safely, so entries after it are dropped.
    """
    tokens = _bus_tokens(text)
    if _next_token(tokens) != "a{sv}":
        raise ValueError("expected an a{sv} value")
    result: dict[str, Any] = {}
    count = int(_next_token(tokens))
    for _ in range(count):
        key = _next_token(tokens)
        try:
            result[key] = _read_value(tokens)
        except UnsupportedVariant:
            break
    return result


def _mpris_bus_names() -> list[str]:
    out = _run_command(["busctl", "--user", "--no-legend", "--no-pager", "list"])
    names = []
    for line in out.splitlines():
        fields = line.split(None, 1)
        if fields and fields[0].startswith(MPRIS_PREFIX):
            names.append(fields[0])
    return names


def _get_property(bus_name: str, prop: str) -> str:
    return _run_command(
        ["busctl", "--user", "get-property", bus_name, MPRIS_OBJECT, MPRIS_PLAYER_IFACE, prop]
    )


def read_media() -> list[MediaSnapshot]:
    """Sample every MPRIS player on the session bus."""
    snapshots: list[MediaSnapshot] = []
    for bus_name in _mpris_bus_names():
        try:
            status = str(parse_variant(_get_property(bus_name, "PlaybackStatus")))
            metadata = parse_string_map(_get_property(bus_name, "Metadata"))
        except (SensorUnavailable, ValueError):
            continue  # the player exited between list and get-property
        title = metadata.get("xesam:title")
        url = metadata.get("xesam:url")
        snapshots.append(
            MediaSnapshot(
                player=bus_name.removeprefix(MPRIS_PREFIX),
                status=status,
                title=title if isinstance(title, str) else None,
                url=url if isinstance(url, str) else None,
            )
        )
    return snapshots


def read_locked() -> bool:
    """True when logind reports LockedHint=yes for the user's graphical session."""
    user = _current_user()
    shown = _run_command(["loginctl", "show-user", user, "-p", "Display", "--value"]).strip()
    if not shown:
        raise SensorUnavailable("no graphical session for this user")
    out = _run_command(["loginctl", "show-session", shown, "-p", "LockedHint", "-p", "State"])
    values = dict(line.partition("=")[::2] for line in out.splitlines() if "=" in line)
    return values.get("LockedHint") == "yes"


def read_active_ssid() -> str | None:
    """SSID of the active Wi-Fi connection, or None when not connected."""
    out = _run_command(["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi", "list", "--rescan", "no"])
    for line in out.splitlines():
        active, _, ssid = line.partition(":")
        if active == "yes":
            return _unescape(ssid)  # terse mode escapes ':' inside SSIDs
    return None


def _hyprctl_json(args: Sequence[str], env: Mapping[str, str]) -> Any:
    out = _run_command(["hyprctl", "-j", *args], env=env)
    try:
        return json.loads(out)
    except ValueError:
        raise SensorUnavailable("hyprctl returned invalid JSON") from None


def read_hypr_state(instance: str | None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Client list and active window from hyprctl, used to seed state on connect."""
    env = dict(os.environ)
    if instance:
        env["HYPRLAND_INSTANCE_SIGNATURE"] = instance
    clients = _hyprctl_json(["clients"], env)
    active = _hyprctl_json(["activewindow"], env)
    if not isinstance(clients, list) or not isinstance(active, dict):
        raise SensorUnavailable("hyprctl returned an unexpected shape")
    return [c for c in clients if isinstance(c, dict)], active


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="ascii", errors="replace")
    except OSError:
        return None


def _read_int(path: Path) -> int | None:
    text = _read_text(path)
    try:
        return int(text.strip()) if text is not None else None
    except ValueError:
        return None


class ResourceSampler:
    """CPU, memory and battery gauges from procfs and sysfs. Missing values are None."""

    def __init__(self, battery_dir: Path, proc: Path = Path("/proc")) -> None:
        self._battery_dir = battery_dir
        self._proc = proc
        self._last_cpu: tuple[int, int] | None = self._cpu_totals()  # baseline for the first sample

    def sample(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "cpu_pct": self._cpu_percent(),
            "mem_available_mb": self._mem_available_mb(),
        }
        result.update(self._battery())
        return result

    def _cpu_percent(self) -> float | None:
        totals = self._cpu_totals()
        if totals is None:
            return None
        previous, self._last_cpu = self._last_cpu, totals
        if previous is None:
            return None  # the first sample only sets the baseline
        d_total = totals[0] - previous[0]
        d_idle = totals[1] - previous[1]
        if d_total <= 0:
            return None
        return round(100.0 * (d_total - d_idle) / d_total, 1)

    def _cpu_totals(self) -> tuple[int, int] | None:
        text = _read_text(self._proc / "stat")
        if text is None:
            return None
        fields = text.split("\n", 1)[0].split()
        # cpu user nice system idle iowait irq softirq steal (guest is already in user)
        if len(fields) < 9 or fields[0] != "cpu":
            return None
        try:
            values = [int(v) for v in fields[1:9]]
        except ValueError:
            return None
        return sum(values), values[3] + values[4]

    def _mem_available_mb(self) -> float | None:
        text = _read_text(self._proc / "meminfo")
        if text is None:
            return None
        for line in text.splitlines():
            if line.startswith("MemAvailable:"):
                try:
                    return round(int(line.split()[1]) / 1024, 1)
                except (IndexError, ValueError):
                    return None
        return None

    def _battery(self) -> dict[str, Any]:
        power_uw = _read_int(self._battery_dir / "power_now")
        status = _read_text(self._battery_dir / "status")
        return {
            "battery_pct": _read_int(self._battery_dir / "capacity"),
            "battery_power_w": None if power_uw is None else round(power_uw / 1e6, 2),
            "battery_status": status.strip() if status is not None else None,
        }


# ---------------------------------------------------------------------------
# Single-instance lock, control socket, status file
# ---------------------------------------------------------------------------


def _pid_from_lock(fd: int) -> int:
    text = os.pread(fd, 32, 0).decode("ascii", "replace").strip()
    return int(text) if text.isdigit() else 0


def _acquire_instance_lock(path: Path) -> int:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pid = _pid_from_lock(fd)
        os.close(fd)
        raise AlreadyRunning(pid) from None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode("ascii"))
    return fd


def daemon_pid(lock_path: Path) -> int | None:
    """PID of the running daemon (0 if running but unreadable), or None if not running."""
    try:
        fd = os.open(lock_path, os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return _pid_from_lock(fd)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


def _bind_control_socket(path: Path) -> socket.socket:
    # The caller holds the instance lock, so no live daemon owns this path.
    path.unlink(missing_ok=True)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(str(path))
    sock.setblocking(False)
    return sock


def notify_daemon(kind: str, ts: float) -> bool:
    """Tell a running daemon about a control event. False if none is listening."""
    path = ipc_dir() / CONTROL_SOCKET_NAME
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.sendto(f"{kind} {ts:.6f}".encode("ascii"), str(path))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def _atomic_write_json(path: Path, payload: Mapping[str, Any]) -> None:
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, separators=(",", ":"))
    os.replace(tmp, path)


def read_status_file(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class _Task:
    name: str
    period: float
    run: Callable[[], None]
    due: float = 0.0


class Daemon:
    """Event loop: Hyprland socket, control datagrams, periodic sensors, signals."""

    def __init__(
        self,
        config: Config,
        *,
        socket_override: Path | None = None,
        state_dir: Path | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._config = config
        self._clock = clock
        self._dir = state_dir if state_dir is not None else ipc_dir()
        self._store = Store(config.store_dir)
        self._recorder = Recorder(config, self._store, clock)
        self._events = EventStream(socket_override, clock)
        self._samples = ResourceSampler(config.battery_path)
        self._stop = False
        self._started = clock()
        self._lock_fd: int | None = None
        self._control: socket.socket | None = None
        self._wake_r = -1
        self._wake_w = -1
        self._last_wifi_poll = float("-inf")
        self._warned: set[str] = set()
        self._counters: Counter[str] = Counter()
        self._current_day = date.today()
        self._status_dirty = True
        self._tasks = [
            _Task("lock", LOCK_POLL_S, self._poll_lock),
            _Task("media", MEDIA_POLL_S, self._poll_media),
            _Task("resources", RESOURCE_POLL_S, self._poll_resources),
            _Task("wifi", WIFI_POLL_S, self._poll_wifi),
            _Task("rotate", ROTATE_CHECK_S, self._check_rotation),
            _Task("stats", STATS_LOG_S, self._log_stats),
        ]

    def run(self) -> int:
        self._dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self._lock_fd = _acquire_instance_lock(self._dir / LOCK_FILE_NAME)
        except AlreadyRunning as exc:
            LOG.error("%s", exc)
            return EX_TEMPFAIL
        try:
            self._control = _bind_control_socket(self._dir / CONTROL_SOCKET_NAME)
            self._startup()
            self._loop()
        finally:
            self._shutdown()
        return EX_OK

    def _startup(self) -> None:
        repaired = self._store.repair_all()
        if repaired:
            LOG.warning("removed %d byte(s) of damaged store tail left by an earlier crash", repaired)
        pruned = self._store.prune(self._config.retention_days, date.today())
        if pruned:
            LOG.info("pruned %d store file(s) past retention", pruned)
        # Establish lock and idle state before the first focus span can open, so
        # a restart while locked or idle records no window. Both are restored only
        # from control records written since this boot, so a reboot cannot leave
        # the daemon stuck idle or locked.
        boot = _boot_time()
        self._recorder.set_idle(self._store.last_record_since(boot, IDLE_TYPES) == "idle")
        try:
            locked = read_locked()
        except SensorUnavailable as exc:
            self._warn_once("lock", f"lock state unavailable at startup: {exc}")
            locked = self._store.last_record_since(boot, LOCK_TYPES) == "lock"
        self._recorder.set_locked(locked, record=False)
        self._wake_r, self._wake_w = os.pipe()
        os.set_blocking(self._wake_r, False)
        os.set_blocking(self._wake_w, False)
        signal.set_wakeup_fd(self._wake_w)
        signal.signal(signal.SIGTERM, self._request_stop)
        signal.signal(signal.SIGINT, self._request_stop)
        now = self._clock()
        for task in self._tasks:
            task.due = now
        LOG.info(
            "started; %d censor rule(s), retention %d day(s)",
            len(self._config.censor_rules),
            self._config.retention_days,
        )

    # -- loop ---------------------------------------------------------------

    def _request_stop(self, _signum: int, _frame: Any) -> None:
        # Only set a flag here. Logging from a signal handler is not reentrant-safe.
        self._stop = True

    def _loop(self) -> None:
        assert self._control is not None
        while not self._stop:
            if self._events.connect_if_due():
                self._guard("seed", self._seed_from_hyprctl)
            watched = [self._wake_r, self._control.fileno()]
            if self._events.connected:
                watched.append(self._events.fileno())
            ready = select.select(watched, [], [], self._sleep_seconds())[0]
            if self._wake_r in ready:
                self._drain_wakeup()
            if self._control.fileno() in ready:
                self._drain_control()
            if self._events.connected and self._events.fileno() in ready:
                self._read_events()
            self._run_due_tasks()
            if self._status_dirty:
                self._guard("status", self._write_status)
        LOG.info("stop requested")

    def _sleep_seconds(self) -> float:
        deadlines = [task.due for task in self._tasks]
        if not self._events.connected:
            deadlines.append(self._events.retry_at)
        return max(0.0, min(min(deadlines) - self._clock(), MAX_SLEEP_S))

    def _drain_wakeup(self) -> None:
        try:
            while os.read(self._wake_r, 512):
                pass
        except BlockingIOError:
            pass

    def _drain_control(self) -> None:
        assert self._control is not None
        while True:
            try:
                message = self._control.recv(64)
            except (BlockingIOError, OSError):
                return
            kind, at = _parse_control(message.decode("ascii", "replace"))
            self._guard("control", lambda: self._apply_control(kind, at))

    def _apply_control(self, kind: str, at: float | None) -> None:
        # The CLI has already written the record. This only updates live state.
        if kind == "idle":
            self._recorder.set_idle(True, at)
        elif kind == "active":
            self._recorder.set_idle(False, at)
        elif kind == "locked":
            self._recorder.set_locked(True, record=False, at=at)
        elif kind == "unlocked":
            self._recorder.set_locked(False, record=False, at=at)
        else:
            self._counters["control_unknown"] += 1
            return
        self._counters["control_applied"] += 1
        self._status_dirty = True

    def _seed_from_hyprctl(self) -> None:
        try:
            clients, active = read_hypr_state(self._events.instance)
        except SensorUnavailable as exc:
            self._warn_once("seed", f"could not read initial window state: {exc}")
            return
        self._recorder.seed(clients, active)
        self._status_dirty = True

    def _read_events(self) -> None:
        lines = self._events.read_lines()
        if lines is None:
            self._recorder.forget_windows()
            self._status_dirty = True
            return
        focus_touched = False
        for line in lines:
            focus_touched = self._handle_line(line) or focus_touched
        if focus_touched and self._clock() - self._last_wifi_poll >= WIFI_MIN_GAP_S:
            # Refresh the Wi-Fi label after focus activity, rate-limited.
            self._task("wifi").due = self._clock()
        self._status_dirty = True

    def _handle_line(self, line: str) -> bool:
        parsed = parse_event(line)
        if parsed is None:
            self._counters["lines_malformed"] += 1
            return False
        name, data = parsed
        try:
            return self._recorder.handle_hypr_event(name, data)
        except Exception as exc:  # one bad line must not stop the daemon
            self._counters["event_errors"] += 1
            LOG.warning("failed to handle %s event (%s)", name[:40], type(exc).__name__)
            return False

    def _task(self, name: str) -> _Task:
        return next(t for t in self._tasks if t.name == name)

    def _run_due_tasks(self) -> None:
        now = self._clock()
        for task in self._tasks:
            if now < task.due:
                continue
            task.due = now + task.period
            self._guard(task.name, task.run)
            if task.name == "wifi":
                self._last_wifi_poll = now

    def _warn_once(self, key: str, message: str) -> None:
        if key not in self._warned:
            self._warned.add(key)
            LOG.warning("%s", message)

    def _guard(self, name: str, run: Callable[[], None]) -> None:
        try:
            run()
        except SensorUnavailable as exc:
            self._counters[f"{name}_unavailable"] += 1
            self._warn_once(name, f"{name} unavailable: {exc}")
        except Exception as exc:  # a sensor bug must not stop the daemon
            self._counters[f"{name}_errors"] += 1
            self._warn_once(f"{name}:{type(exc).__name__}", f"{name} failed ({type(exc).__name__})")

    # -- tasks --------------------------------------------------------------

    def _poll_lock(self) -> None:
        # LockedHint is the backstop for setups without lock hooks. With hooks, the
        # CLI writes the record and notifies the daemon, which then already holds
        # the new state, so no second record is written. A duplicate is possible
        # only if a poll lands between the CLI's write and its notification.
        locked = read_locked()
        if locked != self._recorder.locked:
            self._recorder.set_locked(locked, record=True)
            self._status_dirty = True

    def _poll_media(self) -> None:
        if self._recorder.locked:
            return  # nothing from the session is recorded while locked
        self._recorder.record_media(read_media())

    def _poll_resources(self) -> None:
        self._recorder.record_resources(self._samples.sample())

    def _poll_wifi(self) -> None:
        self._recorder.record_wifi(read_active_ssid())

    def _check_rotation(self) -> None:
        today = date.today()
        if today == self._current_day:
            return
        self._current_day = today
        pruned = self._store.prune(self._config.retention_days, today)
        LOG.info("rotated to a new day; pruned %d store file(s)", pruned)

    def _log_stats(self) -> None:
        LOG.info("stats %s", json.dumps(self._stats(), sort_keys=True))

    def _stats(self) -> dict[str, int]:
        merged = Counter(self._recorder.stats)
        merged.update(self._counters)
        return dict(merged)

    # -- status and shutdown ------------------------------------------------

    def _write_status(self) -> None:
        payload = {
            "pid": os.getpid(),
            "started": self._started,
            "updated": self._clock(),
            "instance": self._events.instance,
            "socket_connected": self._events.connected,
            **self._recorder.snapshot(),
        }
        _atomic_write_json(self._dir / STATUS_FILE_NAME, payload)
        self._status_dirty = False

    def _shutdown(self) -> None:
        try:
            self._recorder.flush()
        except OSError as exc:
            LOG.error("could not write the open span (%s)", type(exc).__name__)
        self._events.close()
        LOG.info("stopped; stats %s", json.dumps(self._stats(), sort_keys=True))
        if self._control is not None:
            self._control.close()
            (self._dir / CONTROL_SOCKET_NAME).unlink(missing_ok=True)
        (self._dir / STATUS_FILE_NAME).unlink(missing_ok=True)
        signal.set_wakeup_fd(-1)
        for fd in (self._wake_r, self._wake_w):
            if fd >= 0:
                os.close(fd)
        if self._lock_fd is not None:
            os.close(self._lock_fd)  # releases the instance lock


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_control(kind: str, config: Config) -> int:
    ts = time.time()
    record = {"ts": ts, "type": CONTROL_RECORD_TYPES[kind]}
    try:
        Store(config.store_dir).append(record)
    except OSError as exc:
        print(f"{PROGRAM}: cannot write event: {exc.strerror}", file=sys.stderr)
        return EX_FAILURE
    notify_daemon(kind, ts)  # best effort; the record is already on disk
    return EX_OK


def _parse_control(message: str) -> tuple[str, float | None]:
    """Parse '<kind> [<unix-ts>]'. A missing or bad timestamp means 'now'."""
    kind, _, ts_text = message.strip().partition(" ")
    try:
        return kind, float(ts_text) if ts_text else None
    except ValueError:
        return kind, None


def _format_time(ts: float) -> str:
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def _describe_record(record: Mapping[str, Any]) -> str:
    """One line per record. Window classes, titles and media titles are never printed."""
    kind = record.get("type", "?")
    when = _format_time(float(record.get("ts", 0)))
    if kind == "span":
        duration = float(record.get("end_ts", 0)) - float(record.get("start_ts", 0))
        detail = f"{duration:.0f}s focus span"
    elif kind == "media":
        detail = f"{record.get('player', '?')} {record.get('status', '?')}"
        if "url_host" in record:
            detail += f" (host {record['url_host']})"
    elif kind == "wifi":
        detail = f"label={record.get('label')}"
    elif kind == "resources":
        detail = f"cpu={record.get('cpu_pct')}% mem={record.get('mem_available_mb')}MB"
        if record.get("battery_pct") is not None:
            detail += f" bat={record['battery_pct']}%"
    else:
        detail = ""
    return f"  {when}  {kind:<9} {detail}".rstrip()


def _print_focus(focus: Mapping[str, Any] | None) -> None:
    if not focus:
        print("focused:        none (or hidden while locked)")
        return
    rule = focus.get("rule")
    via = f", matched censor rule {rule}" if rule else ""
    print(f"focused:        window present; verdict {focus.get('censor')}{via}; details not printed")


def cmd_status(config: Config, socket_override: Path | None) -> int:
    location = find_event_socket(socket_override)
    print(f"config:         {config.source or 'built-in defaults (no config file)'}")
    print(f"censor rules:   {len(config.censor_rules)}")
    if location is None:
        print("event socket:   not found")
    else:
        print(f"event socket:   found (HIS {location.instance})")
    pid = daemon_pid(ipc_dir() / LOCK_FILE_NAME)
    if pid is None:
        print("daemon:         not running")
    else:
        print(f"daemon:         running (pid {pid})")
        snapshot = read_status_file(ipc_dir() / STATUS_FILE_NAME)
        if snapshot is not None:
            print(f"socket link:    {'connected' if snapshot.get('socket_connected') else 'disconnected'}")
            print(f"idle / locked:  {bool(snapshot.get('idle'))} / {bool(snapshot.get('locked'))}")
            _print_focus(snapshot.get("focus"))
    print(f"store:          {config.store_dir}")
    print("last 5 events:")
    records = Store(config.store_dir).tail(5)
    if not records:
        print("  (none)")
    for record in records:
        print(_describe_record(record))
    return EX_OK


def _which(tool: str) -> str | None:
    return shutil.which(tool)


def cmd_doctor(config_path: Path | None, socket_override: Path | None) -> int:
    failures = 0

    def report(level: str, label: str, detail: str) -> None:
        nonlocal failures
        if level == "fail":
            failures += 1
        print(f"[{level:<4}] {label}: {detail}")

    try:
        config = load_config(config_path)
    except ConfigError as exc:
        report("fail", "config", str(exc))
        return EX_FAILURE
    report("ok", "config", f"valid ({config.source or 'built-in defaults'})")
    if config.censor_rules:
        report("ok", "censor", f"{len(config.censor_rules)} rule(s)")
    else:
        report("warn", "censor", "no rules; private browser windows will be recorded")

    if os.environ.get("XDG_RUNTIME_DIR"):
        report("ok", "runtime dir", "XDG_RUNTIME_DIR is set")
    else:
        report("warn", "runtime dir", f"XDG_RUNTIME_DIR unset; using {_runtime_base()}")

    location = find_event_socket(socket_override)
    if location is None:
        report("warn", "event socket", "not found (is Hyprland running?)")
    else:
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(1.0)
        try:
            probe.connect(str(location.path))
            report("ok", "event socket", f"connectable (HIS {location.instance})")
        except OSError as exc:
            report("fail", "event socket", f"not connectable ({exc.strerror or type(exc).__name__})")
        finally:
            probe.close()

    for tool in ("hyprctl", "busctl", "loginctl", "nmcli"):
        if _which(tool):
            report("ok", tool, "found")
        else:
            report("warn", tool, "not on PATH; the matching sensor is disabled")

    sensor_probes = (
        ("busctl --user (MPRIS)", "busctl", _mpris_bus_names),
        ("loginctl (lock state)", "loginctl", read_locked),
        ("nmcli (Wi-Fi)", "nmcli", read_active_ssid),
    )
    for label, tool, probe in sensor_probes:
        if not _which(tool):
            continue  # already reported above
        try:
            probe()
            report("ok", label, "responds")
        except SensorUnavailable as exc:
            report("warn", label, str(exc))

    if config.battery_path.is_dir():
        report("ok", "battery", f"{config.battery_path} present")
    else:
        report("warn", "battery", "no battery directory; battery fields will be null")

    store_dir = config.store_dir
    if store_dir.is_dir():
        mode = store_dir.stat().st_mode & 0o777
        if mode == 0o700:
            report("ok", "store", f"{store_dir} (mode 0700)")
        else:
            report("warn", "store", f"{store_dir} has mode {mode:o}; expected 700")
    elif os.access(store_dir.parent if store_dir.parent.exists() else Path.home(), os.W_OK):
        report("ok", "store", f"{store_dir} will be created on first write")
    else:
        report("fail", "store", f"cannot create {store_dir}")

    pid = daemon_pid(ipc_dir() / LOCK_FILE_NAME)
    if pid is None:
        report("warn", "daemon", "not running")
    else:
        report("ok", "daemon", f"running (pid {pid})")
    return EX_FAILURE if failures else EX_OK


def cmd_run(config: Config, socket_override: Path | None) -> int:
    return Daemon(config, socket_override=socket_override).run()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Privacy-first activity logger for Hyprland. Default command: run.",
    )
    parser.add_argument("--config", type=Path, help="config file (default: ~/.config/hyprmon/hyprmon.toml)")
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")

    run = sub.add_parser("run", help="run the daemon (default)")
    run.add_argument("--socket", type=Path, help="Hyprland socket2 path (default: auto-detect)")

    status = sub.add_parser("status", help="show daemon and store state")
    status.add_argument("--socket", type=Path, help="Hyprland socket2 path (default: auto-detect)")

    doctor = sub.add_parser("doctor", help="validate config and environment")
    doctor.add_argument("--socket", type=Path, help="Hyprland socket2 path (default: auto-detect)")

    for name, text in (
        ("idle", "record that the user went idle"),
        ("active", "record that the user is active again"),
        ("locked", "record that the session is locked"),
        ("unlocked", "record that the session is unlocked"),
    ):
        sub.add_parser(name, help=text)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    command = args.command or "run"
    logging.basicConfig(
        level=logging.INFO if command == "run" else logging.WARNING,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    socket_override = getattr(args, "socket", None)

    if command == "doctor":
        return cmd_doctor(args.config, socket_override)
    try:
        config = load_config(args.config)
    except ConfigError as exc:
        print(f"{PROGRAM}: config error: {exc}", file=sys.stderr)
        return EX_USAGE

    if command == "run":
        return cmd_run(config, socket_override)
    if command == "status":
        return cmd_status(config, socket_override)
    if command in CONTROL_RECORD_TYPES:
        return cmd_control(command, config)
    print(f"{PROGRAM}: unknown command {command!r}", file=sys.stderr)
    return EX_USAGE


if __name__ == "__main__":
    sys.exit(main())
