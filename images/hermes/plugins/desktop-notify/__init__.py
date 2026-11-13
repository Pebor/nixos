"""desktop-notify — native desktop notification on the T14 after every turn.

Why this exists: once a bot has Threaded Mode (DM topics) enabled, Telegram
Desktop shows NO notification for that chat at all — every topic and the main
"All" thread (Telegram bug 67167/67161, open as of tdesktop 7.3.3). Delivery
itself works, only the alert is missing. This plugin restores the alert on the
machine Pebor actually sits at, using the same proven path as battery-guard:
ssh into the T14 and hand a message to the session's notification daemon.

Design rules:
  * fire-and-forget — the hook spawns a thread and returns immediately, so a
    slow or sleeping laptop can never delay a reply;
  * fail-open — every exception is swallowed; a notifier must not break turns;
  * drop, never buffer — if the T14 is unreachable the alert is simply
    dropped (an explicit user requirement: a closed laptop must not collect a
    backlog of chat replies to replay later); only a metadata line is logged;
  * settings in a JSON file (not .env), read at call time, overridable per
    install without touching code.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shlex
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("plugin.desktop-notify")

# Paths hang off HERMES_HOME (set by the systemd unit). Hardcoding the retired
# /opt/data pointed every state file at a directory that no longer exists after
# the native cutover: the plugin kept running and silently wrote nothing.
HOME = Path(os.getenv("HERMES_HOME") or os.path.expanduser("~/.hermes"))
BASE = Path(os.getenv("DESKTOP_NOTIFY_DIR") or HOME / "var/desktop-notify")
CONFIG = Path(os.getenv("DESKTOP_NOTIFY_CONFIG") or HOME / "desktop-notify.json")
ATTEMPTS = BASE / "attempts.log"

DEFAULTS: dict[str, Any] = {
    "enabled": True,
    # "low" = brief, silent, non-intrusive; "normal" = pops like a chat alert;
    # "critical" = stays until dismissed.
    "urgency": "low",
    "timeout_ms": 5000,
    "app_name": "Hermes",
    "icon": "dialog-information",
    # empty = every surface; otherwise e.g. ["telegram", "api_server"]
    "only_platforms": [],
    # surfaces ADDED to the always-visible set (telegram); e.g. "api_server"
    # makes the inbox/dashboard chat toast as well
    "extra_platforms": [],
    "max_body_chars": 180,
    # skip turns whose reply is only whitespace or a bare status word
    "skip_if_shorter_than": 4,
    # Empty = one hop straight to the T14: the gateway runs natively on the
    # t490s now. A jump host is only for the old container layout (there the
    # process could not reach the T14 directly).
    "host_jump": "",
    "desktop_host": "pebor@100.86.253.100",
    "connect_timeout": 5,
}

_cfg_mtime: float = 0.0
_cfg_cache: dict[str, Any] = dict(DEFAULTS)


def _config() -> dict[str, Any]:
    """Re-read the settings file when it changes; never raise."""
    global _cfg_mtime, _cfg_cache
    try:
        st = CONFIG.stat()
        if st.st_mtime != _cfg_mtime:
            data = json.loads(CONFIG.read_text())
            merged = dict(DEFAULTS)
            if isinstance(data, dict):
                merged.update({k: v for k, v in data.items() if k in DEFAULTS})
            _cfg_cache, _cfg_mtime = merged, st.st_mtime
    except FileNotFoundError:
        pass
    except Exception:  # malformed file: keep the last good config
        pass
    return _cfg_cache


_MD = re.compile(r"(\*\*|__|\*|_|`{1,3}|~~|^#{1,6}\s+|^\s*[-*+]\s+|\[([^\]]+)\]\([^)]+\))", re.M)

# A turn that is deliberately silent must not become a desktop toast: cron
# wakes and watchers answer `[SILENT]` / `NO_REPLY`, and the old filter only
# looked at length, so every quiet tick popped "[SILENT]" on the T14.
_SILENCE = re.compile(r"^\s*[\[(]?\s*(silent|no[ _-]?reply)\s*[\])]?\s*[.!]?\s*$", re.I)


def _is_silence(text: str) -> bool:
    """True for a bare silence marker, possibly wrapped in punctuation."""
    return bool(_SILENCE.match((text or "").strip()))


def _snippet(text: str, limit: int) -> str:
    """First meaningful line of the reply, stripped of markdown noise."""
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        line = _MD.sub(lambda m: m.group(2) or "", line)
        line = re.sub(r"\s+", " ", line).strip(" ·-—")
        if line:
            return line[:limit]
    return ""


# Where a reply actually lands decides whether a toast is honest. A toast for a
# turn whose text went to the webhook caller (tasks-app comment), to cron/output
# (deliver: local) or to a CLI announces a message he will never see -- exactly
# the "notifications about messages that never reach Telegram" report.
# Telegram is always visible; add more surfaces via extra_platforms.
VISIBLE_PLATFORMS = frozenset({"telegram"})


def _cron_delivery_platform() -> str:
    """The cron run's auto-deliver platform (session ContextVar); "" = delivers nowhere.

    The scheduler sets ``HERMES_CRON_SESSION=1`` plus the job's resolved target
    before the turn starts (``_reload_dotenv_and_publish_delivery_target``), so an
    empty value inside a cron run means ``deliver: local`` -- the answer only ever
    lands in $HERMES_HOME/cron/output.
    """
    try:
        from gateway.session_context import get_session_env

        if (get_session_env("HERMES_CRON_SESSION", "") or "").strip() != "1":
            return ""
        return (get_session_env("HERMES_CRON_AUTO_DELIVER_PLATFORM", "") or "").strip().lower()
    except Exception:  # noqa: BLE001 - unreadable context must not silence real replies
        return ""


def _notify_decision(platform: str, cfg: dict[str, Any]) -> tuple[bool, str]:
    """(notify?, reason) for a finished turn, judged by where its reply lands."""
    extra = {str(item).strip().lower() for item in (cfg.get("extra_platforms") or [])}
    visible = set(VISIBLE_PLATFORMS) | extra
    name = (platform or "").strip().lower()
    if not name:
        return True, "platform:unknown"  # cannot tell -> keep the old behaviour
    if name == "cron":
        dest = _cron_delivery_platform()
        if not dest:
            return False, "cron-local"
        return (dest in visible), "cron->%s" % dest
    return (name in visible), "platform:%s" % name


def _inner_command(cfg: dict[str, Any], title: str, body: str) -> str:
    """The notify-send invocation, as the T14 session sees it.

    DBUS/WAYLAND/DISPLAY are set explicitly: this arrives over ssh from a
    daemon, so there is no session environment to inherit (battery-guard does
    exactly the same and is proven on this host).
    """
    env = (
        "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
        "export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}; "
        "export DISPLAY=${DISPLAY:-:0}; "
        'export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"; '
    )
    send = "notify-send -u {urgency} -t {ttl} -a {app} -i {icon} {title} {body}".format(
        urgency=shlex.quote(str(cfg["urgency"])),
        ttl=int(cfg["timeout_ms"]),
        app=shlex.quote(str(cfg["app_name"])),
        icon=shlex.quote(str(cfg["icon"])),
        title=shlex.quote(title),
        body=shlex.quote(body),
    )
    return env + send


def _host_script(cfg: dict[str, Any], inner: str) -> str:
    """What a jump host runs: one ssh into the T14, command on stdin.

    Only used when ``host_jump`` is set (the retired container layout).
    """
    return (
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
        "-o ConnectTimeout={timeout} {desktop} bash -s <<'EOSSH'\n{inner}\nEOSSH\n"
    ).format(
        timeout=int(cfg["connect_timeout"]),
        desktop=shlex.quote(str(cfg["desktop_host"])),
        inner=inner,
    )


AUDIT = BASE / "notifications.jsonl"
AUDIT_MAX_BYTES = 1_000_000


def _audit(**fields: Any) -> None:
    """One JSON line per hook decision: what was toasted, what was skipped and why.

    ``attempts.log`` only held ``OK len=N``, so a report like "I get toasts about
    messages that never reach Telegram" could not be answered from data. Every
    branch of the hook now records its reason. Never raises: an audit trail must
    not be able to break a turn.
    """
    rec: dict[str, Any] = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S")}
    for key, value in fields.items():
        if value is None or value == "":
            continue
        if isinstance(value, str) and len(value) > 120:
            value = value[:120]
        rec[key] = value
    try:
        BASE.mkdir(parents=True, exist_ok=True)
        if AUDIT.exists() and AUDIT.stat().st_size > AUDIT_MAX_BYTES:
            AUDIT.replace(AUDIT.with_name("notifications.jsonl.1"))
        with AUDIT.open("a") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        pass


def _note(line: str) -> None:
    try:
        BASE.mkdir(parents=True, exist_ok=True)
        with ATTEMPTS.open("a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), line))
        if ATTEMPTS.stat().st_size > 200_000:
            ATTEMPTS.write_text("\n".join(ATTEMPTS.read_text().splitlines()[-200:]) + "\n")
    except Exception:
        pass


def _deliver(cfg: dict[str, Any], title: str, body: str) -> bool:
    """Push one notification; True when the T14 accepted it."""
    inner = _inner_command(cfg, title, body)
    jump = str(cfg.get("host_jump") or "").strip()
    # No jump host = the ssh to the T14 carries the notify-send script itself.
    target = jump or str(cfg["desktop_host"])
    script = _host_script(cfg, inner) if jump else inner
    try:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
             "-o", "ConnectTimeout=%d" % int(cfg["connect_timeout"]),
             target, "bash -s"],
            input=script, text=True, capture_output=True,
            timeout=int(cfg["connect_timeout"]) * 3 + 6,
        )
    except Exception as exc:  # noqa: BLE001 — a notifier never raises
        _note("EXC %s len=%d" % (type(exc).__name__, len(body)))
        return False
    err = (proc.stderr or "").strip().replace("\n", " ")[:160]
    if proc.returncode == 0:
        _note("OK len=%d" % len(body))
        return True
    _note("DROP rc=%s %s" % (proc.returncode, err))
    return False


def _notify_async(title: str, body: str) -> None:
    """Fire and forget: no queue, no retry, no catch-up by design."""
    cfg = _config()

    def _run() -> None:
        try:
            ok = _deliver(cfg, title, body)
            _audit(event="delivered" if ok else "dropped", title=title, body=body)
        except Exception:  # noqa: BLE001
            pass

    threading.Thread(target=_run, name="desktop-notify", daemon=True).start()


def _on_post_llm_call(
    session_id: str = "",
    assistant_response: str = "",
    platform: str = "",
    **kwargs: Any,
) -> None:
    """Observer hook: one notification per finished turn. Returns nothing."""
    try:
        cfg = _config()
        who = {"platform": platform, "session": session_id}
        if not cfg["enabled"]:
            _audit(event="skip", reason="disabled", **who)
            return
        if not (assistant_response or "").strip():
            _audit(event="skip", reason="empty", **who)
            return
        if _is_silence(assistant_response):
            _audit(event="skip", reason="silence", body=assistant_response.strip(), **who)
            return
        body = _snippet(assistant_response, int(cfg["max_body_chars"]))
        if len(body) < int(cfg["skip_if_shorter_than"]):
            _audit(event="skip", reason="short", body=body, **who)
            return
        ok, reason = _notify_decision(platform, cfg)
        if not ok:
            _audit(event="skip", reason=reason, body=body, **who)
            return
        cron = (session_id or "").startswith("local-")
        title = str(cfg["app_name"]) + (" ⏰" if cron else "")
        _audit(event="send", reason=reason, title=title, body=body, **who)
        _notify_async(title, body)
    except Exception:  # noqa: BLE001 — a raising hook takes the turn down
        return


def _handle_notifytest(raw_args: str = "", **kwargs: Any) -> str:
    """`/notifytest [text]` — prove the whole chain on demand."""
    cfg = _config()
    body = (raw_args or "").strip() or "test notification from Hermes"
    ok = _deliver(cfg, str(cfg["app_name"]) + " test", body)
    if ok:
        return "✅ notify-send accepted on %s (urgency=%s)" % (cfg["desktop_host"], cfg["urgency"])
    return (
        "❌ %s unreachable — dropped (no buffering). Last attempt: `%s`"
        % (cfg["desktop_host"], _last_attempt())
    )


def _last_attempt() -> str:
    try:
        return ATTEMPTS.read_text().strip().splitlines()[-1][:160]
    except Exception:
        return "no attempts yet"


def register(ctx) -> None:
    ctx.register_hook("post_llm_call", _on_post_llm_call)
    ctx.register_command("notifytest", handler=_handle_notifytest,
                         description="Send a test desktop notification to the T14")
