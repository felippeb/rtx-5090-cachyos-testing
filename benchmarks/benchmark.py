#!/usr/bin/env python3
"""Benchmark: matches README metrics — prompt eval, gen speed, drafts, TTFT."""

import json
import subprocess
import sys
import time

BASE_URL = "http://localhost:10500"

PROMPT_CODE = (
    "Analyze the following code for bugs, performance issues, and security vulnerabilities. "
    "Provide a detailed review with line numbers and suggested fixes.\n\n"
    "```python\n"
    "import os\nimport pickle\nimport subprocess\n\ndef load_user_data(filename):\n    with open(filename, 'rb') as f:\n        return pickle.load(f)\n\ndef execute_command(cmd):\n    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)\n    return result.stdout\n\ndef process_batch(items):\n    results = []\n    for item in items:\n        path = os.path.join('/data', item['name'])\n        data = load_user_data(path)\n        output = execute_command(f\"echo {item['value']}\")\n        results.append({'path': path, 'output': output})\n    return results\n"
    "```\n\n"
    "Review each function separately. Include complexity analysis."
)

PROMPT_GENERIC = (
    "Write a detailed explanation of how transformers work in deep learning, "
    "covering self-attention, multi-head attention, positional encoding, and the encoder-decoder architecture. "
    "Explain the mathematical intuition behind each component."
)


def benchmark(prompt_label, prompt_text, max_tokens, temp=0.6):
    payload = {
        "model": "qwen3.6-27b",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": max_tokens,
        "temperature": temp,
        "top_p": 0.95,
        "top_k": 20,
        "stream": False,
    }

    try:
        start = time.time()
        resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=600)
        resp.raise_for_status()
        elapsed = time.time() - start
        data = resp.json()
    except Exception as e:
        return {"label": prompt_label, "error": str(e)}

    timings = data.get("timings", {})
    usage = data.get("usage", {})
    model = data.get("model", "unknown")

    prompt_n = usage.get("prompt_tokens", 0)
    completion_n = usage.get("completion_tokens", 0)

    prompt_ms = timings.get("prompt_ms", 0)
    predicted_ms = timings.get("predicted_ms", 0)

    draft_n = timings.get("draft_n", 0)
    draft_accepted = timings.get("draft_n_accepted", 0)

    prompt_tps = (prompt_n / (prompt_ms / 1000)) if prompt_ms > 0 else 0
    gen_tps = (completion_n / (predicted_ms / 1000)) if predicted_ms > 0 else 0
    ttft = prompt_ms / 1000
    acceptance = (draft_accepted / draft_n * 100) if draft_n > 0 else 0

    result = {
        "label": prompt_label,
        "model": model,
        "prompt_tokens": prompt_n,
        "gen_tokens": completion_n,
        "prompt_tps": round(prompt_tps, 1),
        "gen_tps": round(gen_tps, 1),
        "ttft": round(ttft, 3),
        "total_time": round(elapsed, 2),
        "draft_total": draft_n,
        "draft_accepted": draft_accepted,
        "acceptance_pct": round(acceptance, 1),
    }

    print(f"\n{'='*60}")
    print(f"  {prompt_label} ({max_tokens} tokens requested)")
    print(f"{'='*60}")
    print(f"  Prompt tokens:       {prompt_n}")
    print(f"  Generated tokens:    {completion_n}")
    print(f"  Prompt eval speed:   ~{result['prompt_tps']} t/s")
    print(f"  Token generation:    {result['gen_tps']} t/s")
    print(f"  Time to first token: {result['ttft']}s")
    print(f"  Total wall time:     {result['total_time']}s")
    if draft_n > 0:
        print(f"  Draft tokens:        {draft_accepted}/{draft_n} accepted ({result['acceptance_pct']}%)")

    # GPU stats
    try:
        gpu = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,memory.used", "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip().split(",")
        power, temp_g, mem = [x.strip() for x in gpu]
        print(f"  Power draw:          {power}W")
        print(f"  GPU temp:            {temp_g}°C")
        print(f"  VRAM used:           ~{mem} MB")
        result["power_w"] = int(power)
        result["gpu_temp"] = int(temp_g)
        result["vram_mb"] = int(mem)
    except Exception:
        pass

    return result


def gpu_vram():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip()
        used, total = out.split(",")
        return f"~{int(used.strip())} MB / ~{int(total.strip())} MB"
    except Exception:
        return "N/A"


if __name__ == "__main__":
    import requests

    print("Benchmarking llama.cpp server at", BASE_URL)
    print(f"VRAM available: {gpu_vram()}")

    results = []
    results.append(benchmark("Code analysis (512)", PROMPT_CODE, 512))
    results.append(benchmark("Code analysis (2K)", PROMPT_CODE, 2048))
    results.append(benchmark("Generic explanation (4K)", PROMPT_GENERIC, 4096))

    print(f"\n{'='*60}")
    print("  RESULTS SUMMARY")
    print(f"{'='*60}")
    print(f"{'Test':<30} {'Prompt t/s':>11} {'Gen t/s':>9} {'TTFT':>7} {'Accept%':>9}")
    print(f"{'-'*68}")
    for r in results:
        if "error" in r:
            print(f"{r['label']:<30} {'ERR':>11} {'ERR':>9} {'ERR':>7} {'ERR':>9}")
        else:
            print(
                f"{r['label']:<30} {r['prompt_tps']:>11} {r['gen_tps']:>9} "
                f"{r['ttft']:>6.2f}s {r['acceptance_pct']:>8.1f}%"
            )
