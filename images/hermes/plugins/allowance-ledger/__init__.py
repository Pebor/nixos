"""allowance-ledger — what every API call really cost against the OpenCode Go limit.

Why this exists: ``/zen/go/v1/usage`` returns only three percentages per key. The
per-request number — ``usage.opencode.allowance`` — is in the response body, but
Hermes normalizes usage for hooks and pops ``raw_usage`` before plugins see it, so
the raw number is not reachable from here today (would need the payload widened in
core). This plugin therefore does two things:

1. logs one JSONL line per API call with the token buckets + the peak/off-peak flag,
   and computes ``allowance_est`` from the published Go price table
   (``/opt/data/usage/prices.json``) — the same arithmetic the provider uses, with
   ``counted_factor`` 0.75 measured against real ``usage.opencode.allowance`` values;
2. injects a one-line notice into the turn while a DeepSeek peak window is open
   (01:00-04:00 / 06:00-10:00 UTC, Mon-Fri = 2x price).

If ``allowance`` is ever present in the payload (core widened), it is stored next to
``allowance_est`` and the report prefers it.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

LEDGER = Path(os.getenv("ALLOWANCE_LEDGER", "/opt/data/usage/allowance-ledger.jsonl"))
PRICES = Path(os.getenv("ALLOWANCE_PRICES", "/opt/data/usage/prices.json"))
DEBUG = Path(os.getenv("ALLOWANCE_DEBUG", "/opt/data/usage/allowance-payload-sample.json"))
_lock = threading.Lock()
_sample_written = False
_prices_cache: tuple[float, dict] = (0.0, {})

# per-process accounting (the ledger is the durable copy; these drive the footer and /cost)
_turn_cost: dict[str, float] = {}
_turn_calls: dict[str, int] = {}
_turn_tokens: dict[str, int] = {}
_turn_model: dict[str, str] = {}
_session_cost: dict[str, float] = {}
_session_pct: dict[str, float] = {}
_seeded: set[str] = set()
# today's running totals (Prague calendar day), seeded from the ledger once per process
_day_cost = 0.0
_day_pct = 0.0
_day_key = ""


def _prices() -> dict:
    """Price table, re-read when the file changes (one source of truth on disk)."""
    global _prices_cache
    try:
        mtime = PRICES.stat().st_mtime
    except OSError:
        return _prices_cache[1]
    if mtime != _prices_cache[0]:
        try:
            _prices_cache = (mtime, json.loads(PRICES.read_text(encoding="utf-8")))
        except Exception:
            pass
    return _prices_cache[1]


def _peak(ts: float) -> tuple[bool, float | None]:
    """(is_peak_now, epoch when the current peak window ends)."""
    table = _prices().get("peak_hours_utc_mon_fri") or [[1, 4], [6, 10]]
    dt = _dt.datetime.fromtimestamp(ts, _dt.timezone.utc)
    if dt.weekday() >= 5:  # weekend = off-peak all day
        return False, None
    for start, end in table:
        if int(start) <= dt.hour < int(end):
            ends = dt.replace(hour=int(end), minute=0, second=0, microsecond=0)
            return True, ends.timestamp()
    return False, None


def _estimate(model: str, tokens: dict, is_peak: bool) -> tuple[float | None, float | None]:
    """(list_cost, allowance_est) from the published table; None for an unknown model."""
    table = _prices()
    entry = (table.get("models") or {}).get(model or "")
    if not entry:
        return None, None
    rate = entry.get("peak" if is_peak else "offpeak") or {}
    inp = tokens.get("in") or 0
    out = tokens.get("out") or 0  # reasoning is already inside completion tokens
    cache = tokens.get("cache_read") or 0
    cost = (
        inp * float(rate.get("in") or 0)
        + out * float(rate.get("out") or 0)
        + cache * float(rate.get("cache_read") or 0)
    ) / 1_000_000
    return cost, cost * float(table.get("counted_factor") or 0.75)


def _dig(obj: Any, key: str, depth: int = 0):
    """First value for ``key`` anywhere in a nested dict/list (payload shape varies
    between streaming and non-streaming paths, so never assume a fixed path)."""
    if depth > 6 or obj is None:
        return None
    if isinstance(obj, dict):
        if obj.get(key) is not None:
            return obj[key]
        for value in obj.values():
            found = _dig(value, key, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, (list, tuple)):
        for item in obj:
            found = _dig(item, key, depth + 1)
            if found is not None:
                return found
    return None


def _num(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _write_sample(payload: Any) -> None:
    """One payload sample per process, written only when the raw allowance is missing,
    so a future core/provider shape change is diagnosable without a debugger."""
    global _sample_written
    if _sample_written:
        return
    _sample_written = True
    try:
        DEBUG.parent.mkdir(parents=True, exist_ok=True)
        DEBUG.write_text(
            json.dumps({"ts": time.time(), "keys": _keys(payload), "payload": payload},
                       ensure_ascii=False, default=str)[:200000],
            encoding="utf-8",
        )
    except Exception:
        pass


def _keys(obj: Any, depth: int = 0) -> Any:
    if depth > 4:
        return "..."
    if isinstance(obj, dict):
        return {str(k): _keys(v, depth + 1) for k, v in list(obj.items())[:40]}
    if isinstance(obj, (list, tuple)):
        return [f"<list {len(obj)}>"] + [_keys(obj[0], depth + 1)] if obj else []
    return type(obj).__name__


def _append(record: dict) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
    with _lock:
        with open(LEDGER, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def _on_post_api_request(**kw) -> None:
    try:
        response = kw.get("response")
        usage = kw.get("usage") or {}
        ts = _num(kw.get("ended_at")) or time.time()
        is_peak, _ = _peak(ts)
        tokens = {
            "in": _num(_dig(usage, "input_tokens")) or _num(_dig(usage, "prompt_tokens")) or 0,
            "out": _num(_dig(usage, "output_tokens")) or _num(_dig(usage, "completion_tokens")) or 0,
            "cache_read": _num(_dig(usage, "cache_read_tokens")) or 0,
            "cache_write": _num(_dig(usage, "cache_write_tokens")) or 0,
            "reasoning": _num(_dig(usage, "reasoning_tokens")) or 0,
        }
        model = kw.get("model") or _dig(response, "model") or ""
        raw_allowance = _num(_dig(response, "allowance"))
        list_cost, allowance_est = _estimate(str(model), tokens, is_peak)
        record = {
            "ts": round(ts, 3),
            "session": kw.get("session_id") or "",
            "platform": kw.get("platform") or "",
            "model": model,
            "provider": kw.get("provider") or "",
            "call": kw.get("api_call_count"),
            "req": kw.get("api_request_id") or "",
            "peak": is_peak,
            "allowance": raw_allowance,
            "allowance_est": None if allowance_est is None else round(allowance_est, 8),
            "list_cost": None if list_cost is None else round(list_cost, 8),
            **tokens,
        }
        if raw_allowance is None:
            _write_sample(response if response is not None else usage)

        # in-process totals for the per-message footer and /cost. Seeds run BEFORE the
        # line lands in the ledger, otherwise the seed already counts this call.
        cost = raw_allowance if raw_allowance is not None else (allowance_est or 0.0)
        sid = kw.get("session_id") or ""
        with _lock:
            _seed(sid)
            _seed_day()
            _turn_cost[sid] = _turn_cost.get(sid, 0.0) + cost
            _turn_calls[sid] = _turn_calls.get(sid, 0) + 1
            _turn_tokens[sid] = _turn_tokens.get(sid, 0) + tokens["in"] + tokens["out"] + tokens["cache_read"]
            _turn_model[sid] = str(model)
            _session_cost[sid] = _session_cost.get(sid, 0.0) + cost
            _session_pct[sid] = _session_pct.get(sid, 0.0) + _quota_pct(cost, str(model))
            global _day_cost, _day_pct
            _day_cost += cost
            _day_pct += _quota_pct(cost, str(model))
        _append(record)
    except Exception:
        return None


def _seed(sid: str) -> None:
    """Load a session's already-ledgered spend once per process (caller holds _lock)."""
    if not sid or sid in _seeded:
        return
    _seeded.add(sid)
    total = pct = 0.0
    try:
        if LEDGER.exists():
            with LEDGER.open(encoding="utf-8") as fh:
                for line in fh:
                    if sid not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("session") == sid:
                        value = float(rec.get("allowance") or rec.get("allowance_est") or 0)
                        total += value
                        pct += _quota_pct(value, rec.get("model") or "")
    except Exception:
        pass
    _session_cost[sid] = _session_cost.get(sid, 0.0) + total
    _session_pct[sid] = _session_pct.get(sid, 0.0) + pct


def _money(value: float, places: int = 4) -> str:
    return f"{value:.{places}f}"


def _pct(value: float) -> str:
    """Percent of a model's monthly allowance: 3 decimals while it is small, else 2."""
    places = 3 if value < 0.1 else 2
    return f"{value:.{places}f} %"


def _model_limit(model: str) -> float:
    entry = (_prices().get("models") or {}).get(model or "") or {}
    return float(entry.get("monthly") or 0)


def _quota_pct(cost: float, model: str) -> float:
    """Cost as a share of that model's monthly limit — the unit /usage counts in."""
    limit = _model_limit(model)
    return (cost / limit * 100) if limit else 0.0


def _turn_counters(session_id: str) -> tuple[float, int]:
    return _turn_cost.get(session_id, 0.0), _turn_calls.get(session_id, 0)


_TZ = None
_DZ = ""


def _local_day() -> tuple[str, float]:
    """Prague calendar day + its UTC epoch start (the ledger stores UTC epochs)."""
    global _TZ
    if _TZ is None:
        try:
            from zoneinfo import ZoneInfo
            _TZ = ZoneInfo("Europe/Prague")
        except Exception:
            _TZ = _dt.timezone(_dt.timedelta(hours=1))
    now = _dt.datetime.now(_TZ)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return now.strftime("%Y-%m-%d"), start.timestamp()


def _seed_day() -> None:
    """Accumulate today's spend once per process (one ledger scan), then keep it live."""
    global _day_cost, _day_pct, _day_key
    day, start = _local_day()
    if _day_key == day:
        return
    cost = pct = 0.0
    try:
        if LEDGER.exists():
            with LEDGER.open(encoding="utf-8") as fh:
                for line in fh:
                    if '"ts":' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if float(rec.get("ts") or 0) < start:
                        continue
                    value = float(rec.get("allowance") or rec.get("allowance_est") or 0)
                    cost += value
                    pct += _quota_pct(value, rec.get("model") or "")
    except Exception:
        pass
    _day_cost, _day_pct, _day_key = cost, pct, day


def _today_totals() -> tuple[float, float]:
    _seed_day()
    return _day_cost, _day_pct


def _session_label(session_id: str) -> str:
    """Footer line: this turn's quota share + the running total for this conversation."""
    turn, calls = _turn_counters(session_id)
    if turn <= 0:
        return ""
    model = _turn_model.get(session_id, "")
    parts = [f"+{_pct(_quota_pct(turn, model))}"]
    if calls > 1:
        parts.append(f"{calls} calls")
    parts.append(f"session {_pct(_session_pct.get(session_id, 0.0))}")
    return " · ".join(parts)


def _strip_footer(text: str) -> str:
    """Drop a footer line this plugin already appended.

    The gateway reloads plugins in place on `hermes plugins enable/disable`, and a reload can
    leave the previous registration's transform active next to the new one — two appends per
    reply. Stripping first makes the transform idempotent, so however many copies run the reply
    carries exactly one footer line.
    """
    parts = text.rstrip().split("\n\n")
    while len(parts) > 1:
        last = parts[-1].strip()
        if last.startswith("+") and "%" in last and "session" in last and "\n" not in last:
            parts.pop()
        else:
            break
    return "\n\n".join(parts)


def _on_transform_llm_output(response_text=None, session_id="", platform="", **kw):
    """Append the quota share this turn burned (and today's total) to the reply.

    Percent of the monthly allowance, not dollars: he pays a flat fee, so the number that
    matters is how fast the allowance moves. Cron/oneshot sessions get nothing.
    """
    try:
        text = response_text or ""
        sid = session_id or ""
        if not text.strip() or not sid or sid.startswith("local-"):
            return None
        if platform and platform not in ("telegram", "api_server", "cli", "tui", "desktop"):
            return None
        line = _session_label(sid)
        if not line:
            return None
        return f"{_strip_footer(text)}\n\n{line}"
    except Exception:
        return None


def _handle_cost(raw_args: str = "", session_id: str = "", platform: str = "", **kw):
    """`/cost` — quota share of this conversation, of today, and where the account stands."""
    try:
        sid = session_id or ""
        session_cost = 0.0
        session_pct = 0.0
        calls = 0
        tokens = {"in": 0, "out": 0, "cache": 0}
        if LEDGER.exists():
            with LEDGER.open(encoding="utf-8") as fh:
                for line in fh:
                    if sid and sid not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("session") != sid:
                        continue
                    value = float(rec.get("allowance") or rec.get("allowance_est") or 0)
                    session_cost += value
                    session_pct += _quota_pct(value, rec.get("model") or "")
                    calls += 1
                    tokens["in"] += int(rec.get("in") or 0)
                    tokens["out"] += int(rec.get("out") or 0)
                    tokens["cache"] += int(rec.get("cache_read") or 0)

        day_cost, day_pct = _today_totals()
        lines = [f"💸 **This session** — {_pct(session_pct)} of quota · {calls} requests"]
        lines.append(f"📅 today {_pct(day_pct)} ({_money(day_cost, 2)} $)")
        if calls:
            bits = (f"   input {tokens['in']:,} · cache {tokens['cache']:,} · output {tokens['out']:,}"
                    .replace(",", " "))
            lines.append(bits)
        usage = _provider_usage()
        if usage:
            month = (usage.get("monthly") or {}).get("percent")
            week = (usage.get("weekly") or {}).get("percent")
            roll = (usage.get("rolling") or {}).get("percent")
            if month is not None:
                lines.append(f"📊 account: month {month:.0f} % · weekly {week or 0:.0f} % · 5h {roll or 0:.0f} %")
        return "\n".join(lines)
    except Exception as exc:  # a broken command must not take the turn down
        return f"💸 /cost failed: {exc}"


def _provider_usage() -> dict:
    """The account percentages (needs a key in .env or the environment); None when unavailable."""
    try:
        import urllib.request
        key = os.environ.get("OPENCODE_GO_API_KEY", "").strip()
        if not key:
            env = Path("/opt/data/.env")
            for line in env.read_text(encoding="utf-8").splitlines():
                if line.startswith("OPENCODE_GO_API_KEY="):
                    key = line.split("=", 1)[1].strip()
                    break
        if not key:
            return {}
        req = urllib.request.Request(
            "https://opencode.ai/zen/go/v1/usage",
            headers={"Authorization": f"Bearer {key}", "Accept": "application/json",
                     "User-Agent": "hermes-allowance-ledger/1.1"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            return (json.loads(resp.read().decode()) or {}).get("usage") or {}
    except Exception:
        return {}


def _on_pre_llm_call(**kw):
    """Turn start: reset the per-turn counters, and while a peak window is open hand the turn
    a one-line note so he hears about 2x pricing in the conversation it is costing."""
    try:
        sid = kw.get("session_id") or ""
        with _lock:
            if sid:
                _turn_cost[sid] = 0.0
                _turn_calls[sid] = 0
                _turn_tokens[sid] = 0
        now = time.time()
        is_peak, ends = _peak(now)
        if not is_peak or not ends:
            return None
        left = max(0, int((ends - now) // 60))
        ends_utc = _dt.datetime.fromtimestamp(ends, _dt.timezone.utc).strftime("%H:%M")
        return {
            "context": (
                f"[peak pricing] OpenCode Go peak window is open: DeepSeek tokens cost 2x "
                f"until {ends_utc} UTC (~{left} min left). Mention it in one short line with "
                f"the ⏱ marker if the user is about to do something token-heavy."
            )
        }
    except Exception:
        return None


def register(ctx) -> None:
    ctx.register_hook("post_api_request", _on_post_api_request)
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
    ctx.register_hook("transform_llm_output", _on_transform_llm_output)
    ctx.register_command(
        "cost", handler=_handle_cost,
        description="What this session cost and where the monthly quota stands",
    )
