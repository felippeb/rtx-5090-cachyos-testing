#!/usr/bin/env python3
"""Benchmark vLLM NVFP4 server — same structure as AWQ benchmark."""

import json
import subprocess
import sys
import time

BASE_URL = "http://localhost:10500"

PROMPT_CODE = """Analyze the following code for bugs, performance issues, and security vulnerabilities. Provide a detailed review with line numbers and suggested fixes.

```python
import os
import pickle
import subprocess

def load_user_data(filename):
    with open(filename, 'rb') as f:
        return pickle.load(f)

def execute_command(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout

def process_batch(items):
    results = []
    for item in items:
        path = os.path.join('/data', item['name'])
        data = load_user_data(path)
        output = execute_command(f"echo {item['value']}")
        results.append({'path': path, 'output': output})
    return results
```

Review each function separately. Include complexity analysis."""

PROMPT_GENERIC = (
    "Write a detailed explanation of how transformers work in deep learning, "
    "covering self-attention, multi-head attention, positional encoding, and the encoder-decoder architecture. "
    "Explain the mathematical intuition behind each component."
)


def benchmark(prompt_label, prompt_text, max_tokens, temp=0.6, stream=True):
    import requests

    # vLLM doesn't return MTP draft metrics — those are llama.cpp specific
    # We measure TTFT, prompt t/s, generation t/s manually
    payload = {
        "model": "sakamakismile/Qwen3.6-27B-NVFP4",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": max_tokens,
        "temperature": temp,
        "top_p": 0.95,
        "top_k": 20,
        "stream": stream,
    }

    if not stream:
        payload.pop("stream")

    try:
        start = time.time()

        if stream:
            # Streaming: measure TTFT from first chunk
            resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=600, stream=True)
            resp.raise_for_status()

            ttft = None
            tokens_seen = 0
            first_token_time = None

            buf = b""
            for chunk in resp.iter_content(chunk_size=1024):
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith(b"data: "):
                        data_str = line[6:].decode("utf-8")
                        if data_str == "[DONE]":
                            break
                        chunk_data = json.loads(data_str)
                        delta = chunk_data["choices"][0].get("delta", {})
                        if delta.get("content"):
                            if first_token_time is None:
                                first_token_time = time.time()
                            tokens_seen += 1

            elapsed = time.time() - start
            ttft = first_token_time - start if first_token_time else elapsed
            gen_elapsed = elapsed - ttft
            gen_tps = tokens_seen / gen_elapsed if gen_elapsed > 0 else 0
            prompt_n = len(prompt_text.split())  # rough estimate
            prompt_ms_approx = ttft * 1000
            prompt_tps = prompt_n / ttft if ttft > 0 else 0
        else:
            # Non-streaming: use response timings if available
            pre_start = time.time()
            resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=600)
            resp.raise_for_status()
            elapsed = time.time() - pre_start
            data = resp.json()

            timings = data.get("timings", {})
            usage = data.get("usage", {})
            prompt_n = usage.get("prompt_tokens", 0)
            completion_n = usage.get("completion_tokens", 0)

            prompt_ms = timings.get("prompt", 0)
            predicted_ms = timings.get("predicted", 0)

            prompt_tps = (prompt_n / (prompt_ms / 1000)) if prompt_ms > 0 else 0
            gen_tps = (completion_n / (predicted_ms / 1000)) if predicted_ms > 0 else 0
            ttft = prompt_ms / 1000
            tokens_seen = completion_n

        result = {
            "label": prompt_label,
            "model": "Qwen3.6-27B-NVFP4",
            "prompt_tokens": prompt_n,
            "gen_tokens": tokens_seen,
            "prompt_tps": round(prompt_tps, 1),
            "gen_tps": round(gen_tps, 1),
            "ttft": round(ttft, 3),
            "total_time": round(elapsed, 2),
        }

        print(f"\n{'='*60}")
        print(f"  {prompt_label} ({max_tokens} tokens)")
        print(f"{'='*60}")
        print(f"  Prompt tokens:       {prompt_n}")
        print(f"  Generated tokens:    {tokens_seen}")
        print(f"  Prompt eval speed:   ~{result['prompt_tps']} t/s")
        print(f"  Token generation:    {result['gen_tps']} t/s")
        print(f"  Time to first token: {result['ttft']}s")
        print(f"  Total wall time:     {result['total_time']}s")

        # GPU stats
        try:
            gpu = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,memory.used", "--format=csv,noheader,nounits"],
                text=True, timeout=5,
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

    except Exception as e:
        print(f"  ERROR: {e}")
        return {"label": prompt_label, "error": str(e)}


if __name__ == "__main__":
    print("Benchmarking vLLM NVFP4 server at", BASE_URL)

    results = []
    results.append(benchmark("Code analysis (256)", PROMPT_CODE, 256))
    results.append(benchmark("Code analysis (512)", PROMPT_CODE, 512))
    results.append(benchmark("Code analysis (1024)", PROMPT_CODE, 1024))
    results.append(benchmark("Generic (256)", PROMPT_GENERIC, 256))
    results.append(benchmark("Generic (1024)", PROMPT_GENERIC, 1024))

    print(f"\n{'='*60}")
    print("  RESULTS SUMMARY — vLLM Qwen3.6-27B-NVFP4")
    print(f"{'='*60}")
    print(f"{'Test':<30} {'Prompt t/s':>11} {'Gen t/s':>9} {'TTFT':>7}")
    print(f"-" * 68)
    for r in results:
        if "error" in r:
            print(f"{r['label']:<30} {'ERR':>11} {'ERR':>9} {'ERR':>7}")
        else:
            print(
                f"{r['label']:<30} {r['prompt_tps']:>11} {r['gen_tps']:>9} "
                f"{r['ttft']:>6.2f}s"
            )

    # Save results
    import os
    ts = time.strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"vllm-nvfp4-bench-{ts}")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to {out_dir}/results.json")
