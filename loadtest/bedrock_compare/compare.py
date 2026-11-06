"""Gateway overhead against a direct Amazon Bedrock call: the same requests both ways.

Runs on the driver (inside the VPC). For every concurrency level it repeats
rounds; each round sends `concurrency` parallel requests for every combination
of path (direct Bedrock Converse/ConverseStream, or the gateway's OpenAI
chat completions) and mode (streaming or not), in a shuffled order, so drift
in Bedrock latency hits both paths alike. Both paths draw from the same short
prompts; every prompt carries a unique prefix, so the gateway's response cache
never answers.

  python compare.py --gateway-url http://... --gateway-model <prefix>-bedrock \\
      --bedrock-model amazon.nova-micro-v1:0 --samples 300 --concurrency 1,8 --out results/compare

Environment: API_KEY (gateway virtual key), AWS credentials/region for Bedrock.
Output: one JSON line per request in <out>/compare.jsonl and <out>/run.json:
path, stream, concurrency, ttft_ms (first content), total_ms, status,
overhead_ms (x-litellm-overhead-duration-ms), input/output tokens, error.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import boto3
import requests

PROMPTS = (
    "Name three primary colours.",
    "Give one synonym for 'quick'.",
    "What is the capital of Australia?",
    "Write a haiku about a lighthouse.",
    "Explain what a load balancer does in one sentence.",
)


def bedrock_call(client, model: str, prompt: str, stream: bool, max_tokens: int) -> dict:
    kwargs = {
        "modelId": model,
        "messages": [{"role": "user", "content": [{"text": prompt}]}],
        "inferenceConfig": {"maxTokens": max_tokens, "temperature": 0},
    }
    start = time.perf_counter()
    rec: dict = {}
    if not stream:
        resp = client.converse(**kwargs)
        rec["total_ms"] = (time.perf_counter() - start) * 1000
        usage = resp.get("usage", {})
    else:
        resp = client.converse_stream(**kwargs)
        usage = {}
        for event in resp["stream"]:
            if "contentBlockDelta" in event and "ttft_ms" not in rec:
                rec["ttft_ms"] = (time.perf_counter() - start) * 1000
            if "metadata" in event:
                usage = event["metadata"].get("usage", {})
        rec["total_ms"] = (time.perf_counter() - start) * 1000
    rec.update(status=200, input_tokens=usage.get("inputTokens"), output_tokens=usage.get("outputTokens"))
    return rec


def gateway_call(session, url: str, key: str, model: str, prompt: str, stream: bool, max_tokens: int) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": stream,
    }
    if stream:
        body["stream_options"] = {"include_usage": True}
    start = time.perf_counter()
    rec: dict = {}
    with session.post(
        f"{url}/v1/chat/completions",
        json=body,
        headers={"Authorization": f"Bearer {key}"},
        stream=stream,
        timeout=300,
    ) as resp:
        rec["status"] = resp.status_code
        if resp.headers.get("x-litellm-overhead-duration-ms"):
            rec["overhead_ms"] = float(resp.headers["x-litellm-overhead-duration-ms"])
        if resp.status_code != 200:
            rec["error"] = f"HTTP {resp.status_code} {resp.text[:200]}"
            rec["total_ms"] = (time.perf_counter() - start) * 1000
            return rec
        usage = {}
        if not stream:
            usage = resp.json().get("usage") or {}
        else:
            for line in resp.iter_lines(chunk_size=None):
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if data == b"[DONE]":
                    break
                event = json.loads(data)
                if event.get("usage"):
                    usage = event["usage"]
                for choice in event.get("choices") or []:
                    if (choice.get("delta") or {}).get("content") and "ttft_ms" not in rec:
                        rec["ttft_ms"] = (time.perf_counter() - start) * 1000
        rec["total_ms"] = (time.perf_counter() - start) * 1000
    rec.update(input_tokens=usage.get("prompt_tokens"), output_tokens=usage.get("completion_tokens"))
    return rec


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--gateway-url", required=True)
    p.add_argument("--gateway-model", required=True)
    p.add_argument("--bedrock-model", required=True)
    p.add_argument("--region", default=os.environ.get("AWS_REGION"))
    p.add_argument("--samples", type=int, default=300, help="requests per path, mode and concurrency level")
    p.add_argument("--concurrency", default="1,8")
    p.add_argument("--max-tokens", type=int, default=64)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    key = os.environ["API_KEY"]
    os.makedirs(a.out, exist_ok=True)
    levels = [int(c) for c in a.concurrency.split(",")]
    with open(os.path.join(a.out, "run.json"), "w") as fh:
        json.dump({"start": time.time(), **vars(a)}, fh, indent=1)

    local = threading.local()

    def clients():
        if not hasattr(local, "bedrock"):
            local.bedrock = boto3.client("bedrock-runtime", region_name=a.region)
            local.session = requests.Session()
        return local.bedrock, local.session

    lock = threading.Lock()
    log = open(os.path.join(a.out, "compare.jsonl"), "a", buffering=1)  # noqa: SIM115

    def one(path: str, stream: bool, conc: int, prompt: str) -> None:
        bedrock, session = clients()
        rec = {"t": time.time(), "path": path, "stream": stream, "concurrency": conc}
        try:
            if path == "direct":
                rec.update(bedrock_call(bedrock, a.bedrock_model, prompt, stream, a.max_tokens))
            else:
                rec.update(gateway_call(session, a.gateway_url, key, a.gateway_model, prompt, stream, a.max_tokens))
        except Exception as exc:  # noqa: BLE001 - every failure is recorded, the run goes on
            rec.update(status=0, error=f"{type(exc).__name__}: {exc}"[:200])
        with lock:
            log.write(json.dumps(rec) + "\n")

    combos = [(path, stream) for path in ("direct", "gateway") for stream in (False, True)]
    with ThreadPoolExecutor(max_workers=max(levels)) as pool:
        for conc in levels:
            for _ in range(-(-a.samples // conc)):
                random.shuffle(combos)
                for path, stream in combos:
                    prompts = [f"[{uuid.uuid4().hex[:8]}] {random.choice(PROMPTS)}" for _ in range(conc)]
                    list(pool.map(lambda pr, pa=path, st=stream, c=conc: one(pa, st, c, pr), prompts))
    log.close()
    print(os.path.join(a.out, "compare.jsonl"))


if __name__ == "__main__":
    main()
