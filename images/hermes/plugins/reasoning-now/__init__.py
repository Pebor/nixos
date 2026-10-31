"""reasoning-now — set reasoning effort and ask in one Telegram message.

Why: Hermes parses a command only when the message STARTS with "/", and everything
after it becomes the command's arguments. So `/reasoning low explain X` never asks X —
the whole tail is fed to the effort parser and rejected as an unknown level. There is
also no per-message directive in core.

What this plugin does (ingress hook, before command dispatch and before auth):

    /rnow max <question>   set this session's effort to max, then send <question> as a
                           normal turn (the message text is REWRITTEN to <question>)
    /rnow max              set the effort and confirm (no turn is spent)
    /rnow reset            clear the session override (back to agent.reasoning_effort)

The override is the same one `/reasoning <level>` writes: session-scoped, in-memory,
gone on gateway restart. Nothing is persisted to config.yaml.

Implementation notes (do not "simplify" these):
  * The session key MUST come from `_normalize_source_for_session_key()` then
    `_session_key_for_source()`, exactly like the /reasoning handler — a raw
    event.source key is never read back by the next turn on Telegram DM topics
    (run.py, #30479).
  * A rewrite returns {"action": "rewrite", "text": ...}; returning a dict without a
    str text is ignored, so a typo'd level must be answered out-of-band and skipped.
  * Every path is fail-open: an exception in this hook must never drop a message.
"""
from __future__ import annotations

import json
import logging
import os
import re
import urllib.error
import urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

HOME = Path(os.getenv("HERMES_HOME", "/opt/data"))
ENV_FILE = HOME / ".env"

# `/rnow <level> [rest]` — and the slash-free `rnow <level> [rest]`, which is the one to
# use as the FIRST message of a conversation: a message that looks like a command is
# never moved into a fresh DM topic (telegram_topic_transfer bails on get_command()), so
# the slash form as a conversation opener answers into the previous topic instead.
_RNOW_RE = re.compile(
    r"^(?:/rnow|rnow)(?:@[\w]+)?(?:\s+(?P<level>\S+))?(?:[ \t]+(?P<rest>.*))?$", re.S | re.I
)

_LEVELS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}


def _token() -> str | None:
    tok = (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$", line)
            if m:
                return m.group(1).strip().strip("\"'")
    except Exception:
        pass
    return None


def _api(method: str, params: dict) -> dict:
    tok = _token()
    if not tok:
        return {"ok": False, "description": "no TELEGRAM_BOT_TOKEN"}
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tok}/{method}",
        data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode())
        except Exception:
            return {"ok": False, "description": f"HTTP {exc.code}"}
    except Exception as exc:  # network/DNS/timeout — never raise into dispatch
        return {"ok": False, "description": str(exc)}


def _say(source, text: str) -> None:
    """Post a short reply outside the turn (chat + topic), best effort."""
    chat_id = getattr(source, "chat_id", None)
    if not chat_id:
        return
    params = {"chat_id": str(chat_id), "text": text}
    thread_id = getattr(source, "thread_id", None)
    if thread_id:
        params["message_thread_id"] = str(thread_id)
    _api("sendMessage", params)


def _session_key(gateway, source) -> str:
    try:
        normalized = gateway._normalize_source_for_session_key(source)
    except Exception:
        normalized = source
    try:
        return gateway._session_key_for_source(normalized) or ""
    except Exception:
        return ""


def _authorized(gateway, source) -> bool:
    """Best-effort: never rewrite a message from someone the gateway would refuse."""
    try:
        verdict = gateway._is_sender_authorized(
            getattr(source, "user_id", None),
            getattr(source, "chat_type", None),
            getattr(source, "chat_id", None),
        )
    except Exception:
        return True
    return verdict is not False


def _on_pre_gateway_dispatch(event=None, gateway=None, session_store=None, **kwargs):
    try:
        if event is None or gateway is None:
            return None
        if not getattr(event, "allow_gateway_control", True):
            return None
        text = (event.text or "").strip()
        if not text.lower().startswith(("/rnow", "rnow")):
            return None
        m = _RNOW_RE.match(text)
        if not m:
            return None
        level = (m.group("level") or "").strip().lower()
        rest = (m.group("rest") or "").strip()
        source = getattr(event, "source", None)
        if source is None:
            return None

        from hermes_constants import parse_reasoning_effort

        if level in {"reset", "clear", "default"}:
            parsed = None
            label = "reset"
        elif level in _LEVELS:
            parsed = parse_reasoning_effort(level)
            label = level
        elif not level:
            parsed = False  # nothing to change; show usage
            label = ""
        else:
            _say(source, f"unknown reasoning level: {level}\nvalid: {', '.join(sorted(_LEVELS))} | reset")
            return {"action": "skip"}

        if parsed is False:
            _say(source, "usage: /rnow <level> <message>  —  levels: "
                        + ", ".join(sorted(_LEVELS)) + " | reset")
            return {"action": "skip"}

        if not _authorized(gateway, source):
            return None

        key = _session_key(gateway, source)
        if not key:
            return None
        gateway._set_session_reasoning_override(key, parsed)
        logger.info("reasoning-now: session=%s effort=%s rest=%s", key, label, "yes" if rest else "no")

        if rest:
            return {"action": "rewrite", "text": rest}
        _say(source, f"reasoning → {label} (this session)")
        return {"action": "skip"}
    except Exception:
        logger.debug("reasoning-now hook failed", exc_info=True)
        return None


def register(ctx):
    ctx.register_hook("pre_gateway_dispatch", _on_pre_gateway_dispatch)
