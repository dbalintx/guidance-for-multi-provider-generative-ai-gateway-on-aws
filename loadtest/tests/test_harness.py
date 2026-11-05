"""Offline tests: the fake upstream speaks the OpenAI chat API, the locust
scenario parses its stream, the summary computes the step tables."""

import json
import time

import server
import summarize
from locustfile import parse_sse, parse_steps

INSTANT = server.Profile(ttft_ms=0, itl_ms=0, tokens_min=5, tokens_max=5, jitter=0, tokens_per_chunk=1)


async def test_non_streaming_completion(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post(
        "/v1/chat/completions", json={"model": "m", "messages": [{"role": "user", "content": "x" * 40}]}
    )
    assert resp.status == 200
    body = await resp.json()
    assert body["object"] == "chat.completion"
    assert body["usage"] == {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
    assert len(body["choices"][0]["message"]["content"].split()) == 5


async def test_stream_parses_with_the_scenario_parser(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post(
        "/v1/chat/completions",
        json={"model": "m", "stream": True, "stream_options": {"include_usage": True}, "messages": []},
    )
    assert resp.headers["Content-Type"].startswith("text/event-stream")
    lines = (await resp.text()).splitlines()
    first, chunks, tokens, done = parse_sse(lines)
    assert first is not None and chunks == 5 and tokens == 5 and done


async def test_path_profile_overrides_length(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/p/0/0/3/v1/chat/completions", json={"stream": True, "messages": []})
    _, chunks, tokens, done = parse_sse((await resp.text()).splitlines())
    assert (chunks, tokens, done) == (3, None, True)  # no usage chunk unless asked


async def test_max_tokens_caps_the_response(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/v1/chat/completions", json={"max_tokens": 2, "messages": []})
    assert (await resp.json())["usage"]["completion_tokens"] == 2


async def test_invalid_json_is_a_400(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/v1/chat/completions", data=b"{nope")
    assert resp.status == 400


def test_parse_sse_handles_spaced_json_and_truncation():
    spaced = 'data: {"choices": [{"delta": {"content": " hi"}}]}'
    empty = 'data: {"choices": [{"delta": {"role": "assistant", "content": ""}}]}'
    first, chunks, tokens, done = parse_sse([empty, spaced, spaced])
    assert chunks == 2 and first is not None and tokens is None and not done


def test_parse_steps():
    assert parse_steps("10:60, 20:120") == [(10, 60), (20, 120)]


def test_summary_per_step(tmp_path):
    start = time.time()
    (tmp_path / "run.json").write_text(json.dumps({"start": start, "steps": "1:10,2:10"}))
    rows = [
        {"t": start + 5, "kind": "stream", "status": 200, "ttft_ms": 100, "total_ms": 1000},
        {"t": start + 15, "kind": "stream", "status": 200, "ttft_ms": 300, "total_ms": 3000},
        {"t": start + 16, "kind": "chat", "status": 502, "error": "HTTP 502", "total_ms": 5},
    ]
    (tmp_path / "requests-1.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n{truncated")
    meta, records = summarize.load(str(tmp_path))
    assert len(records) == 3
    steps = summarize.steps_of(meta, records)
    second = summarize.summarise([r for r in records if steps[1][1] <= r["t"] < steps[1][2]], 10)
    assert second["requests"] == 2 and second["errors"] == "50.00%" and second["error classes"] == "502x1"
    assert second["TTFT p95 s"] == "0.30"


def test_memory_trend_slope_per_task():
    import collect_metrics

    rows = [
        {"task": "a", "minute": "2026-01-01 10:00", "mem_mib": 100, "cpu_pct": 10},
        {"task": "a", "minute": "2026-01-01 10:30", "mem_mib": 125, "cpu_pct": 20},
        {"task": "a", "minute": "2026-01-01 11:00", "mem_mib": 150, "cpu_pct": 30},
        {"task": "b", "minute": "2026-01-01 10:00", "mem_mib": 90, "cpu_pct": 5},
    ]
    a, b = collect_metrics.memory_trend(rows)
    assert (a["slope_mib_per_h"], a["max_mib"], a["cpu_avg_pct"]) == (50.0, 150, 20.0)
    assert b["slope_mib_per_h"] == 0.0
