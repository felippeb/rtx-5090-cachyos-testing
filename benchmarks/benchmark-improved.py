#!/usr/bin/env python3
"""Benchmark with variance reporting — multiple runs, statistics, cache modes.

Usage:
    python3 benchmarks/benchmark-improved.py              # default: 5 runs
    python3 benchmarks/benchmark-improved.py --runs 10    # 10 runs
    python3 benchmarks/benchmark-improved.py --mode cold   # cold start only
    python3 benchmarks/benchmark-improved.py --mode warm   # warm cache
    python3 benchmarks/benchmark-improved.py --json        # JSON output
"""

import argparse
import json
import os
import subprocess
import sys
import time
from statistics import mean, median, stdev

BASE_URL = os.environ.get("INFERENCE_URL", "http://localhost:10500")

PROMPTS = {
    "code_review": (
        "Analyze the following code for bugs, performance issues, and security vulnerabilities. "
        "Provide a detailed review with line numbers and suggested fixes.\n\n"
        "```python\nimport os\nimport pickle\nimport subprocess\n\ndef load_user_data(filename):\n"
        "    with open(filename, 'rb') as f:\n        return pickle.load(f)\n\ndef execute_command(cmd):\n"
        "    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)\n"
        "    return result.stdout\n```\n\nReview each function separately."
    ),
    "explanation": (
        "Write a detailed explanation of how transformers work in deep learning, "
        "covering self-attention, multi-head attention, positional encoding, and the encoder-decoder architecture."
    ),
    "tool_use": (
        "You have access to these tools: search_web(query), read_file(path), calculate(expression). "
        "A user asks: 'What is the population of Tokyo multiplied by 2.5?' "
        "Plan your approach step by step, then execute."
    ),
}


def single_run(prompt_label, prompt_text, max_tokens=1024, temperature=0.6):
    """Run a single inference request and return timing metrics."""
    import requests

    payload = {
        "model": "llama",
        "messages": [{"role": "user", "content": prompt_text}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": 0.95,
        "stream": False,
    }

    start = time.time()
    try:
        resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=600)
        resp.raise_for_status()
        elapsed = time.time() - start
        data = resp.json()
    except Exception as e:
        return {"error": str(e)}

    timings = data.get("timings", {})
    usage = data.get("usage", {})

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

    # GPU snapshot
    gpu = {}
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,memory.used",
             "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip().split(",")
        gpu = {"power_w": int(out[0].strip()), "temp_c": int(out[1].strip()),
               "vram_mb": int(out[2].strip())}
    except Exception:
        pass

    return {
        "label": prompt_label,
        "prompt_tokens": prompt_n,
        "gen_tokens": completion_n,
        "prompt_tps": round(prompt_tps, 1),
        "gen_tps": round(gen_tps, 1),
        "ttft_s": round(ttft, 3),
        "wall_s": round(elapsed, 2),
        "draft_total": draft_n,
        "draft_accepted": draft_accepted,
        "acceptance_pct": round(acceptance, 1),
        **gpu,
    }


def warm_cache():
    """Send a small request to warm the KV cache."""
    import requests
    try:
        requests.post(f"{BASE_URL}/v1/chat/completions", json={
            "model": "llama",
            "messages": [{"role": "user", "content": "Hi"}],
            "max_tokens": 8,
        }, timeout=30)
    except Exception:
        pass


def compute_stats(values):
    """Compute median, p95, stdev for a list of values."""
    if len(values) < 2:
        return {"median": values[0] if values else 0, "p95": values[0] if values else 0,
                "stdev": 0, "min": values[0] if values else 0, "max": values[0] if values else 0}
    sorted_v = sorted(values)
    p95_idx = int(len(sorted_v) * 0.95)
    return {
        "median": round(median(values), 2),
        "p95": round(sorted_v[min(p95_idx, len(sorted_v) - 1)], 2),
        "stdev": round(stdev(values), 2),
        "min": round(min(values), 2),
        "max": round(max(values), 2),
        "mean": round(mean(values), 2),
    }


def run_benchmark(num_runs, mode="all", output_json=False):
    """Run benchmark suite with variance reporting."""
    import requests

    print(f"Benchmarking at {BASE_URL}")
    print(f"Mode: {mode} | Runs: {num_runs}")
    vram = gpu_vram()
    print(f"VRAM: {vram}")
    print()

    all_results = {}

    for prompt_name, prompt_text in PROMPTS.items():
        print(f"─── {prompt_name} ({num_runs} runs) ───")

        if mode in ("warm", "all"):
            warm_cache()

        run_results = []
        for i in range(num_runs):
            result = single_run(prompt_name, prompt_text)
            if "error" not in result:
                run_results.append(result)
                print(f"  Run {i+1}/{num_runs}: gen={result['gen_tps']} t/s, "
                      f"ttft={result['ttft_s']}s, wall={result['wall_s']}s")
            else:
                print(f"  Run {i+1}/{num_runs}: ERROR — {result['error']}")

            if mode == "cold" and i < num_runs - 1:
                # Simulate cold start by hitting /health or waiting
                time.sleep(0.5)

        # Aggregate stats
        if run_results:
            gen_tps_values = [r["gen_tps"] for r in run_results]
            ttft_values = [r["ttft_s"] for r in run_results]
            prompt_tps_values = [r["prompt_tps"] for r in run_results]

            stats = {
                "gen_tps": compute_stats(gen_tps_values),
                "ttft_s": compute_stats(ttft_values),
                "prompt_tps": compute_stats(prompt_tps_values),
                "runs_completed": len(run_results),
                "runs_total": num_runs,
            }

            print(f"  ── Statistics ──")
            print(f"  Gen t/s:   median={stats['gen_tps']['median']}, "
                  f"p95={stats['gen_tps']['p95']}, "
                  f"σ={stats['gen_tps']['stdev']}")
            print(f"  TTFT:      median={stats['ttft_s']['median']}s, "
                  f"p95={stats['ttft_s']['p95']}s, "
                  f"σ={stats['ttft_s']['stdev']}s")
            print()

            all_results[prompt_name] = {"runs": run_results, "statistics": stats}
        else:
            print(f"  All runs failed!")
            all_results[prompt_name] = {"runs": [], "statistics": {}}

    # Summary table
    if not output_json:
        print("=" * 70)
        print("  SUMMARY")
        print("=" * 70)
        print(f"{'Prompt':<20} {'Gen t/s (med)':>15} {'TTFT (med)':>13} "
              f"{'Gen σ':>8} {'Runs':>6}")
        print("-" * 70)
        for name, data in all_results.items():
            s = data.get("statistics", {})
            if s:
                print(f"{name:<20} {s['gen_tps']['median']:>15} "
                      f"{s['ttft_s']['median']:>12}s {s['gen_tps']['stdev']:>8} "
                      f"{s['runs_completed']:>{len(str(num_runs))}}/{num_runs}")
            else:
                print(f"{name:<20} {'N/A':>15} {'N/A':>13} {'N/A':>8} 0/{num_runs}")

    # Save JSON if requested
    if output_json:
        out_dir = os.path.join(os.path.dirname(__file__), "..", "runs")
        os.makedirs(out_dir, exist_ok=True)
        ts = time.strftime("%Y%m%d-%H%M%S")
        out_path = os.path.join(out_dir, f"benchmark-{ts}.json")
        # Make serializable
        export = {}
        for name, data in all_results.items():
            export[name] = {
                "statistics": data["statistics"],
                "individual_runs": data["runs"],
            }
        with open(out_path, "w") as f:
            json.dump(export, f, indent=2)
        print(f"\nJSON saved to: {out_path}")

    return all_results


def gpu_vram():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            text=True, timeout=5
        ).strip()
        used, total = out.split(",")
        return f"{int(used.strip())} MB / {int(total.strip())} MB"
    except Exception:
        return "N/A"


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Benchmark with variance reporting")
    ap.add_argument("--runs", type=int, default=5, help="Number of runs per prompt (default: 5)")
    ap.add_argument("--mode", choices=["cold", "warm", "all"], default="all",
                    help="Cache mode: cold, warm, or all")
    ap.add_argument("--json", action="store_true", help="Output JSON to runs/ directory")
    ap.add_argument("--url", default=BASE_URL, help=f"Inference URL (default: {BASE_URL})")
    args = ap.parse_args()

    BASE_URL = args.url
    run_benchmark(args.runs, args.mode, args.json)
