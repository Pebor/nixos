"""telegram-topic-cleaner — keep the Telegram DM topic list short.

Why: every message typed in the main DM gets a fresh DM topic (dm_topic_auto_transfer),
so the topic list grows without bound. Hermes creates and renames those topics but has
no command to delete one, and the Bot API has no "list forum topics" method — so the
source of truth for *which* topics exist is `telegram_dm_topic_bindings` in state.db.

What this plugin does:
  /topics                       list bound topics: id, age, last activity, messages
  /topicdel [id]                delete the current topic (or the given one)
  /topicsweep <days> [yes]      delete topics idle for >= <days>; dry-run unless "yes"

Deleting = Bot API deleteForumTopic on (chat_id, message_thread_id) + prune the stale
binding row so no job/topic routing keeps pointing at a dead thread. Sessions and their
messages stay in state.db (session_search still finds them).

Protected threads (never swept, never deleted by /topicdel without an explicit id):
the permanent Cron topic (109054) plus anything in TOPIC_CLEANER_PROTECT (csv).
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

HOME = Path(os.getenv("HERMES_HOME", "/opt/data"))
STATE_DB = Path(os.getenv("TOPIC_CLEANER_DB", str(HOME / "state.db")))
CONFIG = Path(os.getenv("TOPIC_CLEANER_CONFIG", str(HOME / "topic-cleaner.json")))
ENV_FILE = HOME / ".env"
DEFAULT_KEEP_DAYS = 5.0
# The one permanent DM topic: every automated job targets it (standing convention).
_DEFAULT_PROTECT = {"109054"}


# ── plumbing ────────────────────────────────────────────────────────────────────
def _session_env(name: str) -> str | None:
    """Read a per-turn session var (ContextVar in the gateway, os.environ in the CLI)."""
    try:
        from gateway.session_context import get_session_env  # type: ignore

        value = get_session_env(name)
        if value:
            return str(value)
    except Exception:
        pass
    return os.getenv(name) or None


def _token() -> str | None:
    tok = (os.getenv("TELEGRAM_BOT_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+)", line)
            if m:
                return m.group(1).strip().strip("\"'")
    except Exception:
        pass
    return None


def _api(method: str, **params: Any) -> dict:
    tok = _token()
    if not tok:
        return {"ok": False, "description": "no TELEGRAM_BOT_TOKEN"}
    body = json.dumps(params).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tok}/{method}",
        data=body,
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
    except Exception as exc:  # network, DNS, timeout — never raise into the turn
        return {"ok": False, "description": str(exc)[:120]}


def _chat_int(chat_id: str) -> Any:
    s = str(chat_id)
    return int(s) if s.lstrip("-").isdigit() else s


def _cfg() -> dict:
    """Operator settings: $HERMES_HOME/topic-cleaner.json (env vars override)."""
    try:
        data = json.loads(CONFIG.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def keep_days() -> float:
    env = os.getenv("TOPIC_CLEANER_KEEP_DAYS")
    if env:
        try:
            return float(env)
        except ValueError:
            pass
    try:
        return float(_cfg().get("keep_days") or DEFAULT_KEEP_DAYS)
    except (TypeError, ValueError):
        return DEFAULT_KEEP_DAYS


def _protected() -> set[str]:
    ids = set(_DEFAULT_PROTECT)
    ids.update(str(x) for x in (_cfg().get("protect_ids") or []))
    for part in (os.getenv("TOPIC_CLEANER_PROTECT") or "").split(","):
        part = part.strip()
        if part:
            ids.add(part)
    return ids


def _protected_titles() -> list[str]:
    out = [str(t).strip().lower() for t in (_cfg().get("protect_titles") or []) if str(t).strip()]
    return out


def _bindings(chat_id: str) -> list[dict]:
    """Bound topics for one chat, newest activity first. Read-only; [] on any error."""
    try:
        con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=5)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            """
            SELECT b.thread_id, b.session_id, b.updated_at, s.title, s.message_count,
                   (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = b.session_id) AS last_ts
            FROM telegram_dm_topic_bindings b
            LEFT JOIN sessions s ON s.id = b.session_id
            WHERE b.chat_id = ?
            """,
            (str(chat_id),),
        ).fetchall()
        con.close()
    except Exception:
        return []
    out = []
    for r in rows:
        d = dict(r)
        d["last"] = max(float(d.get("last_ts") or 0), float(d.get("updated_at") or 0)) or None
        out.append(d)
    out.sort(key=lambda d: d["last"] or 0, reverse=True)
    return out


def _prune_binding(chat_id: str, thread_id: str) -> bool:
    try:
        con = sqlite3.connect(str(STATE_DB), timeout=10)
        con.execute(
            "DELETE FROM telegram_dm_topic_bindings WHERE chat_id = ? AND thread_id = ?",
            (str(chat_id), str(thread_id)),
        )
        con.commit()
        con.close()
        return True
    except Exception:
        return False


def _age(ts: float | None) -> str:
    if not ts:
        return "?"
    hours = max(0.0, (time.time() - ts) / 3600.0)
    if hours < 1:
        return f"{int(hours * 60)}m"
    if hours < 48:
        return f"{int(hours)}h"
    return f"{int(hours / 24)}d"


def _short(text: str | None, n: int = 42) -> str:
    t = (text or "(untitled)").replace("\n", " ").strip()
    return t if len(t) <= n else t[: n - 1] + "…"


# ── core operations (shared by the commands and the cron sweeper) ───────────────
_ALREADY_GONE = ("topic_id_invalid", "message thread not found", "thread not found")


def delete_topic(chat_id: str, thread_id: str, prune_binding: bool = True) -> dict:
    res = _api("deleteForumTopic", chat_id=_chat_int(chat_id), message_thread_id=int(thread_id))
    ok = bool(res.get("ok"))
    desc = str(res.get("description") or "")
    gone = (not ok) and any(marker in desc.lower() for marker in _ALREADY_GONE)
    if gone:
        # Telegram no longer knows this thread (DM topic ids stop being addressable after
        # ~96h of idleness), so there is nothing to delete — only the stale binding to drop.
        ok = True
    pruned = _prune_binding(chat_id, thread_id) if (ok and prune_binding) else False
    return {"ok": ok, "thread_id": str(thread_id), "description": desc,
            "already_gone": gone, "binding_pruned": pruned}


def sweep(chat_id: str, days: float | None = None, dry_run: bool = True,
          protect_thread: str | None = None) -> dict:
    """Delete (or list, when dry_run) topics idle for >= days (default: configured keep_days)."""
    days = keep_days() if days is None else float(days)
    protect = _protected() | ({str(protect_thread)} if protect_thread else set())
    titles = _protected_titles()
    now = time.time()
    doomed: list[dict] = []
    skipped_titles: list[str] = []
    for b in _bindings(chat_id):
        tid = str(b["thread_id"])
        if tid in protect:
            continue
        title = (b.get("title") or "")
        if titles and any(t in title.lower() for t in titles):
            skipped_titles.append(f"{tid} {_short(title)}")
            continue
        last = b["last"] or 0
        if (now - last) / 86400.0 < days:
            continue
        doomed.append({"thread_id": tid, "title": _short(title),
                       "messages": b.get("message_count") or 0, "last": last})
    results = []
    if not dry_run:
        for t in doomed:
            results.append(delete_topic(chat_id, t["thread_id"]))
    return {
        "chat_id": str(chat_id),
        "days": days,
        "dry_run": dry_run,
        "topics": doomed,
        "results": results,
        "protected": sorted(protect),
        "protected_titles": skipped_titles,
        "bound_total": len(_bindings(chat_id)),
    }


def _write_cfg(**updates: Any) -> None:
    data = _cfg()
    data.update(updates)
    try:
        CONFIG.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except Exception:
        pass


def set_lock(thread_id: str, locked: bool) -> list[str]:
    """Persist a thread id in (or out of) protect_ids; returns the new list."""
    ids = [str(x) for x in (_cfg().get("protect_ids") or [])]
    if locked and str(thread_id) not in ids:
        ids.append(str(thread_id))
    if not locked:
        ids = [x for x in ids if x != str(thread_id)]
    _write_cfg(protect_ids=ids)
    return ids


def report_sweep(res: dict, notify_chat: str | None = None) -> str:
    n = len(res["topics"])
    if res["dry_run"]:
        head = f"🧹 {n} topic(s) idle ≥{res['days']:.0f}d (dry run — nothing deleted)"
    else:
        deleted = sum(1 for r in res["results"] if r["ok"] and not r.get("already_gone"))
        gone = sum(1 for r in res["results"] if r["ok"] and r.get("already_gone"))
        head = f"🧹 {deleted} deleted · {gone} already gone (binding pruned) · {res['days']:.0f}d limit"
    lines = [head]
    for t in res["topics"][:25]:
        lines.append(f"• {t['thread_id']} · {_age(t['last'])} · {t['messages']} msg · {t['title']}")
    if n > 25:
        lines.append(f"… +{n - 25} more")
    fails = [r for r in res["results"] if not r["ok"]]
    if fails:
        lines.append("⚠️ failed: " + ", ".join(f"{r['thread_id']} ({r['description'][:40]})" for r in fails[:5]))
    if res["dry_run"]:
        lines.append(f"Apply: /topicsweep {res['days']:.0f} yes")
    return "\n".join(lines)


# ── command handlers ───────────────────────────────────────────────────────────
def _chat_thread() -> tuple[str | None, str | None]:
    return (_session_env("HERMES_SESSION_CHAT_ID"), _session_env("HERMES_SESSION_THREAD_ID"))


def _handle_topics(raw_args: str = "", session_id: str = "", platform: str = "", **kw: Any) -> str:
    try:
        chat, current = _chat_thread()
        if not chat:
            return "⚠️ no chat in this session"
        want = str(raw_args or "").strip()
        if want.isdigit():
            n = max(1, min(60, int(want)))
        else:
            n = 20
        rows = _bindings(chat)
        if not rows:
            return "No bound Telegram topics for this chat."
        keep = keep_days()
        protect = _protected()
        titles = _protected_titles()
        out = [f"📋 {len(rows)} topics · sweep keeps {keep:.0f}d · 🗑 = would be swept"]
        for b in rows[:n]:
            tid = str(b["thread_id"])
            flags = []
            if tid == str(current):
                flags.append("▶️")
            if tid in protect or (titles and any(t in (b.get("title") or "").lower() for t in titles)):
                flags.append("🔒")
            elif b["last"] and (time.time() - b["last"]) / 86400.0 >= keep:
                flags.append("🗑")
            out.append(
                f"{''.join(flags) or '  '} {tid} · {_age(b['last'])} · "
                f"{b.get('message_count') or 0} msg · {_short(b.get('title'))}"
            )
        if len(rows) > n:
            out.append(f"… +{len(rows) - n} more (use /topics {len(rows)})")
        out.append("Delete: /topicdel            Sweep: /topicsweep <days> [yes]")
        return "\n".join(out)
    except Exception as exc:  # never take the turn down
        return f"⚠️ /topics failed: {exc}"


def _handle_topicdel(raw_args: str = "", session_id: str = "", platform: str = "", **kw: Any) -> str:
    try:
        chat, current = _chat_thread()
        if not chat:
            return "⚠️ no chat in this session"
        arg = str(raw_args or "").strip()
        target = arg if arg.isdigit() else (current or "")
        if not target:
            return "⚠️ Not inside a topic — pass an id: /topicdel 110831"
        if str(target) in _protected():
            return (f"🔒 {target} is a protected topic (Cron/notify lane) — refusing to delete it.\n"
                    f"Protected: {', '.join(sorted(_protected()))} (override with TOPIC_CLEANER_PROTECT)")
        rows = {str(b["thread_id"]): b for b in _bindings(chat)}
        info = rows.get(str(target)) or {}
        title = _short(info.get("title"))
        res = delete_topic(chat, str(target))
        if not res["ok"]:
            return f"⚠️ delete {target} failed: {res['description'] or 'unknown error'}"
        # the topic (and anything sent into it) is gone — confirm in the main DM instead
        note = (f"🗑 Topic {target} deleted · {title} · {info.get('message_count') or 0} msg"
                f"{'' if res['binding_pruned'] else ' (binding prune failed)'}")
        _api("sendMessage", chat_id=_chat_int(chat), text=note)
        if str(target) == str(current):
            return ""  # nothing to say into a thread that no longer exists
        return note
    except Exception as exc:
        return f"⚠️ /topicdel failed: {exc}"


def _handle_topiclock(raw_args: str = "", session_id: str = "", platform: str = "", **kw: Any) -> str:
    return _lock_cmd(raw_args, lock=True)


def _handle_topicunlock(raw_args: str = "", session_id: str = "", platform: str = "", **kw: Any) -> str:
    return _lock_cmd(raw_args, lock=False)


def _lock_cmd(raw_args: str, lock: bool) -> str:
    try:
        chat, current = _chat_thread()
        arg = str(raw_args or "").strip()
        if arg.lower() in ("list", "ls"):
            ids = sorted(_protected())
            return "🔒 locked topics: " + (", ".join(ids) if ids else "(none)") + \
                   "\nUnlock: /topicunlock <id> · Lock: /topiclock <id>"
        target = arg if arg.isdigit() else (current or "")
        if not target:
            return "⚠️ Not inside a topic — pass an id: /topiclock 110831"
        ids = set_lock(str(target), lock)
        titles = {str(b["thread_id"]): _short(b.get("title"), 32) for b in _bindings(chat or "")} if chat else {}
        label = titles.get(str(target), "")
        if lock:
            return f"🔒 {target} {label} locked — the sweep will never delete it.\nLocked now: {', '.join(sorted(ids))}"
        return f"🔓 {target} {label} unlocked — sweep may delete it once idle.\nLocked now: {', '.join(sorted(ids)) or '(none)'}"
    except Exception as exc:
        return f"⚠️ lock/unlock failed: {exc}"


def _handle_topicsweep(raw_args: str = "", session_id: str = "", platform: str = "", **kw: Any) -> str:
    try:
        chat, current = _chat_thread()
        if not chat:
            return "⚠️ no chat in this session"
        parts = str(raw_args or "").split()
        days = keep_days()
        apply = False
        for p in parts:
            if p.replace(".", "", 1).isdigit():
                days = float(p)
            elif p.lower() in ("yes", "apply", "go"):
                apply = True
        res = sweep(chat, days=days, dry_run=not apply, protect_thread=current)
        return report_sweep(res)
    except Exception as exc:
        return f"⚠️ /topicsweep failed: {exc}"


# ── registration ───────────────────────────────────────────────────────────────
def register(ctx) -> None:
    ctx.register_command("topics", handler=_handle_topics,
                         description="List Telegram DM topics with age and activity")
    ctx.register_command("topicdel", handler=_handle_topicdel,
                         description="Delete the current Telegram DM topic (or /topicdel <id>)")
    ctx.register_command("topiclock", handler=_handle_topiclock,
                         description="Never sweep this topic: /topiclock [id] (no arg = current)")
    ctx.register_command("topicunlock", handler=_handle_topicunlock,
                         description="Allow the sweep to delete a topic again: /topicunlock [id]")
    ctx.register_command("topicsweep", handler=_handle_topicsweep,
                         description="Delete topics idle >= N days: /topicsweep <days> [yes]")
