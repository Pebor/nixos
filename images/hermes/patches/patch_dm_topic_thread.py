"""Derived-image patch: a FRESH Telegram DM message keeps its thread id.

Bug (reported 2026-10-22): a message sent from "All Messages" is wrapped by
Telegram in a NEW topic, so it arrives with ``message_thread_id`` set but
``is_topic_message=False``. The adapter's gate dropped the thread id, the
gateway's topic-recovery then pinned the turn onto the user's last-active topic
— the new topic was never used, and a deleted topic swallowed the reply.

Fix: in a private chat, a FRESH (non-reply) message keeps its
``message_thread_id`` even when ``is_topic_message`` is False. Replies keep the
old strict behaviour — a reply-UI anchor is not a durable thread id
(upstream #3206). Same rule in both places that derive the thread: the routing
gate (``_effective_message_thread_id``) and the session source
(``_source_from_message_for_auth``), because gating and auth must agree.

Idempotent: a tree that already carries MARKER is left alone; an anchor
mismatch (upstream rewrote the function) exits non-zero so the BUILD fails
instead of shipping half-patched code.
"""
from __future__ import annotations

import pathlib
import sys

ADAPTER = pathlib.Path("/opt/hermes/plugins/platforms/telegram/adapter.py")
MARKER = "DM fresh message keeps its thread id"

src = ADAPTER.read_text()
if MARKER in src:
    print("patch already applied:", ADAPTER)
    sys.exit(0)

# --- 1) _effective_message_thread_id gate -----------------------------------
old1 = """        if raw is not None:
            if is_forum_group or (is_group and is_topic_message) or (chat_type == "private" and is_topic_message):
                return str(raw)
            return None
        return cls._GENERAL_TOPIC_THREAD_ID if is_forum_group else None"""
new1 = """        if raw is not None:
            if is_forum_group or (is_group and is_topic_message) or (chat_type == "private" and is_topic_message):
                return str(raw)
            if chat_type == "private" and not getattr(message, "reply_to_message", None):
                # DM fresh message keeps its thread id: Telegram opened a new
                # topic for it, is_topic_message is just not set on the update.
                return str(raw)
            return None
        return cls._GENERAL_TOPIC_THREAD_ID if is_forum_group else None"""

# --- 2) _source_from_message_for_auth gate ----------------------------------
old2 = """        thread_id = None
        if thread_id_raw is not None and (
            (chat_type == "forum" and (is_topic_message or is_forum_group)) or (chat_type == "dm" and is_topic_message)):
            thread_id = str(thread_id_raw)"""
new2 = """        thread_id = None
        if thread_id_raw is not None and (
            (chat_type == "forum" and (is_topic_message or is_forum_group)) or (chat_type == "dm" and is_topic_message)
            or (chat_type == "dm" and not getattr(message, "reply_to_message", None))):
            thread_id = str(thread_id_raw)"""

ok = True
for i, (old, new) in enumerate([(old1, new1), (old2, new2)], 1):
    n = src.count(old)
    if n != 1:
        print(f"FAIL: patch block {i} matched {n} times (expected 1)")
        ok = False
    else:
        src = src.replace(old, new)
        print(f"OK: patch block {i} applied")

if not ok:
    sys.exit(1)

ADAPTER.write_text(src)
print("patched:", ADAPTER)
