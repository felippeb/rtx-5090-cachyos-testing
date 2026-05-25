#!/usr/bin/env python3
"""
Benchmark: Qwen3.6-27B NVFP4-MTP (131K) - Reasoning ON vs OFF
Reproduces discussion #221 methodology on our local hardware.

Runs the server directly (no sudo needed).
"""

import json
import subprocess
import sys
import time
import requests
import os
import signal
from dataclasses import dataclass, asdict

BASE_URL = "http://localhost:10500"
WARMUP_SECONDS = 3
MAX_WAIT_START = 90

# Base server command (reasoning OFF - no --reasoning flag)
SERVER_BIN = "/opt/llama-mtp/build/bin/llama-server"
MODEL_PATH = "/opt/models-mtp/qwen3.6-27b-nvfp4-mtp/qwen3.6-27b-text-nvfp4-mtp.gguf"
MMPROJ_PATH = "/opt/models-mtp/qwen3.6-27b-nvfp4-mtp/mmproj-F16.gguf"
CHAT_TPL = "/opt/llama-mtp/chat_template.jinja"

BASE_ARGS = [
    SERVER_BIN,
    "-m", MODEL_PATH,
    "--mmproj", MMPROJ_PATH,
    "-fitt", "8192",
    "-c", "131072",
    "-n", "32768",
    "-fa", "on",
    "-ngl", "99",
    "-np", "1",
    "-t", "16",
    "-tb", "16",
    "-ctk", "bf16",
    "-ctv", "bf16",
    "-ctkd", "q4_1",
    "-ctvd", "q4_1",
    "-ctxcp", "16",
    "-cram", "8192",
    "--cache-idle-slots",
    "--no-warmup",
    "--spec-type", "draft-mtp",
    "--spec-draft-n-max", "2",
    "--temp", "0.6",
    "--top-p", "0.95",
    "--top-k", "20",
    "--min-p", "0.0",
    "--presence-penalty", "1.5",
    "--repeat-penalty", "1.0",
    "--jinja",
    "--chat-template-file", CHAT_TPL,
    "--host", "0.0.0.0",
    "--port", "10500",
]

# ─── Test Prompts ──────────────────────────────────────────────────────
PROMPTS = [
    ("Code review (security)", """Analyze the following code for bugs, performance issues, and security vulnerabilities. Provide a detailed review with suggested fixes.

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

Review each function separately. List all security vulnerabilities found.""", 4096),

    ("Code gen (binary search)", """Write a Python function that implements binary search on a sorted list.
The function should handle edge cases (empty list, target not in list,
single element list) and return the index of the target or -1 if not found.
Include type hints and a docstring. Do NOT use the bisect module.""", 2048),

    ("HumanEval-style (peak elem)", """Implement a function `find_peak_element(nums: list[int]) -> int` that finds a peak element in a list.
A peak element is strictly greater than its neighbors. The array may have multiple peaks; return the index of any one.
The first and last elements are guaranteed to be -infinity (nums[-1] = nums[n] = -∞).
Your solution must run in O(log n) time. Do not use linear scan.""", 2048),

    ("Math (train word problem)", """A train leaves station A at 60 mph. Another train leaves station B at 80 mph.
The stations are 420 miles apart and both trains leave at the same time, heading toward each other.
How long will it take for them to meet? Show your work step by step.""", 1024),

    ("Math (water jug puzzle)", """You have a 10-liter jug and a 6-liter jug. You need to measure exactly 4 liters of water.
You have an unlimited supply of water from a tap. What is the minimum number of steps (fill, empty, pour) needed?
Show each step and explain your reasoning.""", 2048),

    ("Science (sky color)", """Explain why the sky appears blue during the day but red/orange during sunset.
Include the physics of Rayleigh scattering and how path length through the atmosphere affects the observed color.
Be concise but accurate.""", 1024),
]


@dataclass
class BenchmarkResult:
    label: str
    reasoning_mode: str
    success: bool = False
    completion_tokens: int = 0
    prompt_tokens: int = 0
    total_tokens: int = 0
    prompt_ms: float = 0.0
    predicted_ms: float = 0.0
    wall_time_s: float = 0.0
    prompt_tps: float = 0.0
    gen_tps: float = 0.0
    ttft_s: float = 0.0
    finish_reason: str = ""
    has_thinking_block: bool = False
    error: str = ""
    power_w: int = -1
    gpu_temp: int = -1
    vram_mb: int = -1


def get_gpu_stats():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,memory.used",
             "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip().split(",")
        return {"power_w": int(out[0].strip()), "gpu_temp": int(out[1].strip()), "vram_mb": int(out[2].strip())}
    except Exception:
        return {"power_w": -1, "gpu_temp": -1, "vram_mb": -1}


def wait_server_ready(timeout=60):
    for i in range(timeout):
        try:
            r = requests.get(f"{BASE_URL}/v1/models", timeout=2)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


# No server restarts needed — reasoning is controlled per-request via chat template


def run_request(prompt_label, prompt_text, reasoning_mode, max_tokens=4096, temp=0.0):
    """Send a chat completion request.

    Reasoning is controlled via the chat template's enable_thinking parameter,
    passed through llama.cpp's custom_template_kwargs or n_ctx slot properties.
    When enable_thinking=false, the template emits <think>\n\n</think>\n\n
    (empty block) which tells the model to answer directly without reasoning.
    """
    payload = {
        "model": "qwen3.6-27b-text-nvfp4-mtp.gguf",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": max_tokens,
        "temperature": temp,
        "top_p": 0.95,
        "top_k": 20,
        "stream": False,
    }

    # Control reasoning via <|think_off|> / <|think_on|> markers in system message.
    # The chat template (lines 161-164) strips these and sets ns.enable_thinking
    # which controls whether the generation prompt opens with <think> or </think>\n\n.
    # This is the mechanism from discussion #221 (enable_thinking=false).
    if reasoning_mode == "on":
        payload["messages"] = [
            {"role": "system", "content": "<|think_on|>"},
            {"role": "user", "content": prompt_text},
        ]
    else:
        payload["messages"] = [
            {"role": "system", "content": "<|think_off|>"},
            {"role": "user", "content": prompt_text},
        ]

    result = BenchmarkResult(label=prompt_label, reasoning_mode=reasoning_mode)

    try:
        start = time.time()
        resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=300)
        result.wall_time_s = round(time.time() - start, 2)

        if resp.status_code != 200:
            result.error = f"HTTP {resp.status_code}: {resp.text[:200]}"
            result.success = False
            return result

        data = resp.json()
    except requests.exceptions.Timeout:
        result.error = "Request timed out (>300s) - runaway thinking"
        result.success = False
        result.finish_reason = "timeout"
        return result
    except Exception as e:
        result.error = str(e)
        result.success = False
        return result

    timings = data.get("timings", {})
    usage = data.get("usage", {})

    prompt_n = usage.get("prompt_tokens", 0)
    completion_n = usage.get("completion_tokens", 0)
    total_n = usage.get("total_tokens", 0)
    prompt_ms = timings.get("prompt_ms", 0)
    predicted_ms = timings.get("predicted_ms", 0)

    result.prompt_tokens = prompt_n
    result.completion_tokens = completion_n
    result.total_tokens = total_n
    result.prompt_ms = prompt_ms
    result.predicted_ms = predicted_ms
    result.prompt_tps = round(prompt_n / (prompt_ms / 1000), 1) if prompt_ms > 0 else 0
    result.gen_tps = round(completion_n / (predicted_ms / 1000), 1) if predicted_ms > 0 else 0
    result.ttft_s = round(prompt_ms / 1000, 3)
    result.finish_reason = data.get("finish_reason", "")

    content = ""
    choices = data.get("choices", [])
    if choices:
        msg = choices[0].get("message", {})
        content = msg.get("content", "")
        reasoning_content = msg.get("reasoning_content", "")
        result.has_thinking_block = (
            "<think" in content.lower() or
            "</think>" in content or
            bool(reasoning_content)
        )

    gpu = get_gpu_stats()
    result.power_w = gpu["power_w"]
    result.gpu_temp = gpu["gpu_temp"]
    result.vram_mb = gpu["vram_mb"]
    result.success = True

    return result


def run_phase(reasoning_mode, tests):
    """Run all test prompts against the running server."""
    results = []
    print("  Warming up...")
    run_request("_warmup", "Say hello in one word.", reasoning_mode, max_tokens=16)
    time.sleep(WARMUP_SECONDS)

    for label, prompt, max_tok in tests:
        print(f"  Running: {label} (reasoning={reasoning_mode})...")
        r = run_request(label, prompt, reasoning_mode, max_tokens=max_tok)
        results.append(r)
        if r.success:
            think_tag = " [THINKING]" if r.has_thinking_block else ""
            print(f"    OK {r.completion_tokens} tok | {r.wall_time_s}s | {r.gen_tps} t/s | finish={r.finish_reason}{think_tag}")
        else:
            print(f"    FAIL {r.error}")
        time.sleep(1)

    return results


def print_results(all_results):
    on_results = [r for r in all_results if r.reasoning_mode == "on"]
    off_results = [r for r in all_results if r.reasoning_mode == "off"]

    print("\n" + "=" * 120)
    print("  REASONING ON vs OFF - Qwen3.6-27B NVFP4-MTP (131K context)")
    print("=" * 120)
    print(f"{'Test':<35} {'Mode':>6} {'GenTok':>7} {'PromptTok':>10} "
          f"{'Gen TPS':>8} {'TTFT':>7} {'Wall(s)':>8} {'Finish':>12} {'Think?':>7}")
    print("-" * 120)

    for r in all_results:
        think = "yes" if r.has_thinking_block else "no"
        finish = r.finish_reason if r.finish_reason else ("error" if not r.success else "stop")
        print(
            f"{r.label:<35} {r.reasoning_mode:>6} {r.completion_tokens:>7} "
            f"{r.prompt_tokens:>10} {r.gen_tps:>8.1f} {r.ttft_s:>6.2f}s "
            f"{r.wall_time_s:>7.2f}s {finish:>12} {think:>7}"
        )

    print("\n" + "=" * 120)
    print("  SUMMARY")
    print("=" * 120)

    if on_results and off_results:
        on_tokens = sum(r.completion_tokens for r in on_results if r.success)
        off_tokens = sum(r.completion_tokens for r in off_results if r.success)
        on_time = sum(r.wall_time_s for r in on_results if r.success)
        off_time = sum(r.wall_time_s for r in off_results if r.success)

        token_ratio = on_tokens / off_tokens if off_tokens > 0 else 0
        time_ratio = on_time / off_time if off_time > 0 else 0

        print(f"\n  Total completion tokens: ON={on_tokens} vs OFF={off_tokens} ({token_ratio:.1f}x more with thinking)")
        print(f"  Total wall time:         ON={on_time:.1f}s vs OFF={off_time:.1f}s ({time_ratio:.1f}x slower with thinking)")

        on_success = sum(1 for r in on_results if r.success)
        off_success = sum(1 for r in off_results if r.success)
        print(f"  Successful requests:     ON={on_success}/{len(on_results)} vs OFF={off_success}/{len(off_results)}")

        on_hit_max = sum(1 for r in on_results if r.finish_reason in ("length", "timeout"))
        off_hit_max = sum(1 for r in off_results if r.finish_reason in ("length", "timeout"))
        print(f"  Hit max_tokens/timeout:  ON={on_hit_max}/{len(on_results)} vs OFF={off_hit_max}/{len(off_results)}")

        on_thinking = sum(1 for r in on_results if r.has_thinking_block)
        print(f"  Had thinking blocks:     ON={on_thinking}/{len(on_results)}")

    print("\n" + "-" * 120)
    if on_results and off_results:
        on_tokens = sum(r.completion_tokens for r in on_results if r.success)
        off_tokens = sum(r.completion_tokens for r in off_results if r.success)
        token_ratio = on_tokens / off_tokens if off_tokens > 0 else 0
        if token_ratio > 3.0:
            verdict = f"THINKING IS A TAX - {token_ratio:.0f}x tokens for no clear gain (matches discussion #221)"
        elif token_ratio > 1.5:
            verdict = f"THINKING COSTS {token_ratio:.1f}x tokens - marginal benefit needs scrutiny"
        else:
            verdict = f"Token overhead modest ({token_ratio:.1f}x) - check quality manually"
        print(f"  VERDICT: {verdict}")
    print("=" * 120)


def main():
    print("=" * 60)
    print("  Qwen3.6-27B NVFP4-MTP (131K) - Reasoning ON vs OFF")
    print("  Reproducing discussion #221 on local hardware")
    print("=" * 60)

    # Check server is available
    if not wait_server_ready(5):
        print("\n  ERROR: Server not responding at", BASE_URL)
        print("  Start it first: ./scripts/service-switcher.sh nvfp4-mtp")
        sys.exit(1)
    print("  Server OK at", BASE_URL)

    tests = PROMPTS
    all_results = []

    # Phase 1: Reasoning OFF (via <|think_off|> in system prompt)
    print("\n" + "-" * 60)
    print("  PHASE 1: Reasoning OFF (<|think_off|> template marker)")
    print("-" * 60)

    off_results = run_phase("off", tests)
    all_results.extend(off_results)

    if not off_results:
        print("  FAILED Phase 1 - aborting")
        sys.exit(1)

    # Phase 2: Reasoning ON (via <|think_on|> in system prompt)
    print("\n" + "-" * 60)
    print("  PHASE 2: Reasoning ON (<|think_on|> template marker)")
    print("-" * 60)

    on_results = run_phase("on", tests)
    all_results.extend(on_results)

    # Print Results
    print_results(all_results)

    # Save results
    out_dir = os.path.dirname(os.path.abspath(__file__))
    ts = time.strftime("%Y%m%d-%H%M%S")
    out_file = os.path.join(out_dir, f"reasoning-bench-{ts}.json")

    with open(out_file, "w") as f:
        json.dump([asdict(r) for r in all_results], f, indent=2)
    print(f"\n  Results saved: {out_file}")
    print("\n  Server is still running. No restart needed.")


if __name__ == "__main__":
    main()
