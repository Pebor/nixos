"""Derived-image patch: keep Telegram DM topic labels short.

Why: a DM topic's name is the session title mirrored onto the topic
(``_rename_telegram_topic_for_session_title`` -> ``editForumTopic``). Titles are
descriptive ("Synchronizace Google Calendar s Radicale přes DAVx5"), so every
topic fills the sidebar. The full title must stay on the session — ``/sessions``
and ``session_search`` read it — so ONLY the label derived for Telegram is
shortened, in the single function that produces it.

What this patch does:
  1. adds ``_short_topic_label`` + its word lists at module level (drop a leading
     infinitive/imperative, cut on a word boundary, never end on a dangling
     preposition);
  2. rewrites ``_sanitize_telegram_topic_title`` to use it, with the length read
     from ``telegram.extra.topic_name_max_chars`` (default 24; 120 = old
     behaviour, i.e. a one-key kill switch).

Idempotent: re-running it on an already patched tree is a no-op. It never writes
on an anchor mismatch (a future upstream rewrite of that function fails loudly
instead of producing half-patched code).
"""
from __future__ import annotations

import os
import pathlib
import sys

# TOPIC_PATCH_TARGET exists so the patch can be dry-run against a copy first.
TARGET = pathlib.Path(os.environ.get("TOPIC_PATCH_TARGET") or "/opt/hermes/gateway/run_topics.py")
MARKER = "topic_name_max_chars"

HELPERS = '''

# ── short DM topic labels ──────────────────────────────────────────────────────────────────
# The topic label is the session title copied onto the topic, and long titles (Czech ones
# especially) eat the Telegram sidebar. The session keeps its full title — only this label is
# shortened: drop a leading filler verb, keep the key noun, cut on a word boundary.
_TOPIC_LABEL_MAX_DEFAULT = 24

# Leading filler verbs / imperatives: "Najít …", "Zavést …", "Research …". Nominalisations
# ("Synchronizace", "Audit", "Přepnutí", "Benchmark") are deliberately absent — they carry
# the meaning of the label.
_TOPIC_FILLER_LEAD = {
    "najít", "najit", "najdi", "hledat", "zkusit",
    "převést", "prevest", "zavést", "zavest", "zaveď",
    "zkrátit", "zkratit", "zkrať", "zmenšit", "zmensit",
    "zapnout", "zapni", "vypnout", "vypni", "nastavit", "nastav",
    "opravit", "oprav", "udělat", "udelat", "udělej",
    "vytvořit", "vytvorit", "vytvoř", "přidat", "pridat", "přidej",
    "odebrat", "odeber", "změnit", "zmenit", "změň",
    "zkontrolovat", "zkontroluj", "otestovat", "otestuj",
    "prozkoumat", "prozkoumej", "vyřešit", "vyresit", "vyřeš",
    "zjistit", "zjisti", "vysvětlit", "vysvetlit", "vysvětli",
    "popsat", "popiš", "implementovat", "nastudovat",
    "naplánovat", "naplanovat", "nachystat", "připravit", "pripravit",
    "research", "fix", "add", "find", "check", "update", "make", "build",
    "create", "review", "implement", "investigate", "compare", "set", "setup", "use",
}

# Words that must never END a cut label: "Převést tasks.pebor.me na" dangles.
_TOPIC_TRAIL_STOP = {
    "a", "i", "na", "do", "pro", "k", "ke", "s", "se", "si", "u", "v", "ve",
    "z", "ze", "o", "od", "po", "přes", "pres", "když", "kdyz", "že", "aby", "jak",
    "vs", "and", "or", "for", "of", "to", "with", "in", "on", "the", "at", "by",
    "from", "into", "is", "are",
}


def _short_topic_label(title: str, limit: int = _TOPIC_LABEL_MAX_DEFAULT) -> str:
    """Keyword-first label of at most *limit* chars (word boundary), never a dangling cut."""
    text = _collapse_title(title)
    words = text.split()
    if not words:
        return text
    if len(words) >= 3 and words[0].lower().rstrip(":") in _TOPIC_FILLER_LEAD:
        words = words[1:]
    label = ""
    for word in words:
        candidate = f"{label} {word}".strip()
        if label and len(candidate) > limit:
            break
        label = candidate
        if len(label) >= limit:
            break
    while True:
        parts = label.split()
        if len(parts) > 1 and parts[-1].lower().strip(",.:;") in _TOPIC_TRAIL_STOP:
            parts.pop()
            label = " ".join(parts)
            continue
        break
    return label.rstrip(" ,.:;-")
'''

OLD_SANITIZER = '''    def _sanitize_telegram_topic_title(self, title: str) -> str:
        """Bot API-safe forum topic name: names are 1-128 chars; keep room for multi-byte titles."""
        cleaned = _collapse_title(title)
        return cleaned if len(cleaned) <= 120 else cleaned[:117].rstrip() + "..."'''

NEW_SANITIZER = '''    def _sanitize_telegram_topic_title(self, title: str) -> str:
        """Bot API-safe, sidebar-friendly forum topic name.

        The topic label mirrors the session title, but the session keeps the FULL title
        (``/sessions`` and ``session_search`` read that) — only this label is shortened.
        Length: ``telegram.extra.topic_name_max_chars`` (default 24; 120 = old behaviour).
        """
        label = _short_topic_label(_collapse_title(title), self._topic_label_max_chars())
        return label if len(label) <= 120 else label[:117].rstrip() + "..."

    def _topic_label_max_chars(self) -> int:
        """``telegram.extra.topic_name_max_chars`` clamped to Bot API limits (default 24)."""
        try:
            config = getattr(self, "config", None)
            platforms = getattr(config, "platforms", None) or {}
            platform_cfg = platforms.get(Platform.TELEGRAM) if hasattr(platforms, "get") else None
            extra = (getattr(platform_cfg, "extra", None) or {}) if platform_cfg is not None else {}
            raw = extra.get("topic_name_max_chars")
            if raw not in (None, ""):
                return max(8, min(120, int(raw)))
        except Exception:
            logger.debug("Failed to read telegram.extra.topic_name_max_chars", exc_info=True)
        return _TOPIC_LABEL_MAX_DEFAULT'''


def main() -> int:
    src = TARGET.read_text(encoding="utf-8")
    if MARKER in src and "_short_topic_label" in src:
        print("already applied: topic label patch is present")
        return 0

    ok = True
    if "_short_topic_label" not in src:
        anchor = (
            'def _collapse_title(title: str) -> str:\n'
            '    return re.sub(r"\\s+", " ", str(title or "")).strip() or t("gateway.topic.default_title")\n'
        )
        hits = src.count(anchor)
        if hits != 1:
            print(f"FAIL: helper anchor matched {hits} times (expected 1)")
            ok = False
        else:
            src = src.replace(anchor, anchor + HELPERS, 1)
            print("OK: helper block inserted")

    hits = src.count(OLD_SANITIZER)
    if hits != 1:
        print(f"FAIL: sanitizer anchor matched {hits} times (expected 1)")
        ok = False
    else:
        src = src.replace(OLD_SANITIZER, NEW_SANITIZER, 1)
        print("OK: sanitizer rewritten")

    if not ok:
        print("nothing written")
        return 1
    try:
        compile(src, str(TARGET), "exec")
    except SyntaxError as exc:
        print(f"FAIL: patched source does not compile: {exc}")
        return 1
    TARGET.write_text(src, encoding="utf-8")
    print(f"written: {TARGET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
