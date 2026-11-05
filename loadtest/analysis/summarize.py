"""Summarise a run's per-request log (requests-*.jsonl, run.json) as markdown tables.

  python summarize.py results/<run> [--skip 30] [--minutes]

Per step of the STEPS profile (or the whole run without one): concurrent users,
completed requests per second, error share, time to first token (streams) and
total time percentiles, the gateway's own overhead header. The first --skip
seconds of every step are left out (users still starting, queues filling).
--minutes adds a per-minute timeline (for long, steady runs). Requests are
attributed to the interval in which they started.
"""

from __future__ import annotations

import argparse
import contextlib
import glob
import json
import os
import time
from collections import Counter


def load(run_dir: str) -> tuple[dict, list[dict]]:
    with open(os.path.join(run_dir, "run.json")) as fh:
        meta = json.load(fh)
    records = []
    for path in glob.glob(os.path.join(run_dir, "requests-*.jsonl")):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    with contextlib.suppress(json.JSONDecodeError):  # a line cut short by a stop
                        records.append(json.loads(line))
    records.sort(key=lambda r: r["t"])
    return meta, records


def pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, max(0, int(round(q / 100 * len(values) + 0.5)) - 1))]


def steps_of(meta: dict, records: list[dict]) -> list[tuple[str, float, float]]:
    """(label, start, end) per step; one window over the whole run without STEPS."""
    if meta.get("steps"):
        out, t = [], meta["start"]
        for part in meta["steps"].split(","):
            users, seconds = (int(x) for x in part.split(":"))
            out.append((str(users), t, t + seconds))
            t += seconds
        return out
    end = records[-1]["t"] if records else meta["start"]
    return [("-", meta["start"], end + 1)]


def error_class(r: dict) -> str:
    err = r.get("error", "")
    if r.get("status") and r["status"] != 200:
        return str(r["status"])
    return err.split(":")[0][:40] or "other"


def summarise(rows: list[dict], seconds: float) -> dict:
    ok = [r for r in rows if not r.get("error")]
    streams = [r for r in ok if r["kind"] == "stream"]
    chats = [r for r in ok if r["kind"] == "chat"]
    errors = Counter(error_class(r) for r in rows if r.get("error"))

    def f(v):
        return "" if v is None else f"{v / 1000:.2f}"

    return {
        "req/s": f"{len(rows) / seconds:.1f}" if seconds > 0 else "",
        "requests": len(rows),
        "errors": f"{100 * (len(rows) - len(ok)) / len(rows):.2f}%" if rows else "",
        "error classes": ", ".join(f"{k}x{v}" for k, v in errors.most_common(3)),
        "TTFT p50 s": f(pct([r["ttft_ms"] for r in streams if "ttft_ms" in r], 50)),
        "TTFT p95 s": f(pct([r["ttft_ms"] for r in streams if "ttft_ms" in r], 95)),
        "TTFT p99 s": f(pct([r["ttft_ms"] for r in streams if "ttft_ms" in r], 99)),
        "stream p95 s": f(pct([r["total_ms"] for r in streams], 95)),
        "chat p95 s": f(pct([r["total_ms"] for r in chats], 95)),
        "overhead p50 ms": _ms(pct([r["overhead_ms"] for r in ok if "overhead_ms" in r], 50)),
        "overhead p95 ms": _ms(pct([r["overhead_ms"] for r in ok if "overhead_ms" in r], 95)),
    }


def _ms(v):
    return "" if v is None else f"{v:.0f}"


def table(rows: list[dict]) -> str:
    if not rows:
        return "(no requests)\n"
    head = list(rows[0])
    lines = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    lines += ["| " + " | ".join(str(r[h]) for h in head) + " |" for r in rows]
    return "\n".join(lines) + "\n"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir")
    p.add_argument("--skip", type=float, default=30, help="seconds left out at the start of every step")
    p.add_argument("--minutes", action="store_true", help="add a per-minute timeline")
    a = p.parse_args()
    meta, records = load(a.run_dir)

    out = []
    for label, start, end in steps_of(meta, records):
        lo = start + a.skip
        rows = [r for r in records if lo <= r["t"] < end]
        out.append({"users": label, "from (UTC)": _utc(lo), **summarise(rows, end - lo)})
    print(f"## {os.path.basename(os.path.normpath(a.run_dir))}\n")
    print(
        f"model {meta.get('model')}, stream ratio {meta.get('stream_ratio')}, prompt {meta.get('prompt_chars')} chars, "
        f"think time {meta.get('wait')} s, steps {meta.get('steps') or '-'}\n"
    )
    print(table(out))

    if a.minutes and records:
        t0 = int(records[0]["t"] // 60 * 60)
        timeline = []
        for m in range(t0, int(records[-1]["t"]) + 1, 60):
            rows = [r for r in records if m <= r["t"] < m + 60]
            timeline.append({"minute (UTC)": _utc(m), **summarise(rows, 60)})
        print(table(timeline))


def _utc(t: float) -> str:
    return time.strftime("%H:%M:%S", time.gmtime(t))


if __name__ == "__main__":
    main()
