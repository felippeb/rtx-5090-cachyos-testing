#!/usr/bin/env python3
"""Wattage benchmark: sweep nvidia-smi power limits and measure throughput + power efficiency."""

import json
import subprocess
import sys
import time

BASE_URL = "http://localhost:10500"

# Same prompts as benchmark.py
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


def get_power_limit():
    """Get current power limit in watts."""
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=power.limit", "--format=csv,noheader,nounits"],
        text=True, timeout=5
    ).strip()
    return int(float(out))


def set_power_limit(watts):
    """Set GPU power limit via nvidia-smi (requires root)."""
    subprocess.run(
        ["nvidia-smi", "-pl", str(watts)],
        check=True, capture_output=True, text=True, timeout=10
    )


def get_gpu_stats():
    """Get current power draw, temp, clocks."""
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=power.draw,temperature.gpu,clocks.gr,clocks.sm,memory.used",
         "--format=csv,noheader,nounits"],
        text=True, timeout=5
    ).strip().split(",")
    return {
        "power_w": float(out[0].strip()),
        "temp_c": int(out[1].strip()),
        "clock_mhz": int(out[2].strip()),
        "mem_clock_mhz": int(out[3].strip()),
        "vram_mb": int(out[4].strip()),
    }


def benchmark_run(prompt_label, prompt_text, max_tokens, temp=0.6):
    """Run a single benchmark request and return metrics."""
    import requests

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

    return {
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


def run_benchmarks_at_power(power_limit_w):
    """Run all benchmark tests at a given power limit and collect metrics."""
    import requests

    print(f"\n{'#'*70}")
    print(f"  POWER LIMIT: {power_limit_w}W")
    print(f"{'#'*70}")

    # Set power limit
    set_power_limit(power_limit_w)
    time.sleep(3)  # Let GPU settle

    # Get initial GPU state
    gpu_before = get_gpu_stats()
    print(f"  GPU state: {gpu_before['power_w']:.1f}W, {gpu_before['temp_c']}°C, "
          f"clock {gpu_before['clock_mhz']}MHz, VRAM {gpu_before['vram_mb']}MB")

    results = []

    # Warmup request
    print("  Running warmup...")
    benchmark_run("warmup", PROMPT_GENERIC, 256)
    time.sleep(2)

    # Actual benchmarks
    for label, prompt, tokens in [
        ("Code analysis (512)", PROMPT_CODE, 512),
        ("Code analysis (2K)", PROMPT_CODE, 2048),
        ("Generic explanation (4K)", PROMPT_GENERIC, 4096),
    ]:
        # Sample power during the run
        gpu_before_run = get_gpu_stats()
        result = benchmark_run(label, prompt, tokens)
        gpu_after_run = get_gpu_stats()

        if "error" not in result:
            # Average power around the run
            avg_power = (gpu_before_run["power_w"] + gpu_after_run["power_w"]) / 2
            result["power_limit_w"] = power_limit_w
            result["avg_power_draw_w"] = round(avg_power, 1)
            result["gpu_temp_c"] = gpu_after_run["temp_c"]
            result["clock_mhz"] = gpu_after_run["clock_mhz"]
            # Efficiency: tokens per watt
            if avg_power > 0:
                result["gen_tps_per_watt"] = round(result["gen_tps"] / avg_power, 3)
                result["prompt_tps_per_watt"] = round(result["prompt_tps"] / avg_power, 3)
            print(f"  {label}: prompt={result['prompt_tps']} t/s, gen={result['gen_tps']} t/s, "
                  f"power={avg_power:.0f}W, eff={result.get('gen_tps_per_watt', 'N/A')} t/s/W")
        else:
            result["power_limit_w"] = power_limit_w
            print(f"  {label}: ERROR - {result['error']}")

        results.append(result)
        time.sleep(1)

    return results


def main():
    import requests

    # Power limits to test: from min (400W) to default (575W)
    POWER_LIMITS = [400, 425, 450, 475, 500, 525, 550, 575]

    original_limit = get_power_limit()
    print(f"Original power limit: {original_limit}W")
    print(f"Testing power limits: {POWER_LIMITS}")
    print(f"llama.cpp server: {BASE_URL}")

    # Check server is up
    try:
        r = requests.get(f"{BASE_URL}/health", timeout=5)
        print(f"Server health: {r.text.strip()}")
    except Exception as e:
        print(f"ERROR: Cannot reach server at {BASE_URL}: {e}")
        sys.exit(1)

    # GPU info
    gpu_info = get_gpu_stats()
    print(f"GPU: power={gpu_info['power_w']}W, temp={gpu_info['temp_c']}°C, "
          f"clock={gpu_info['clock_mhz']}MHz, VRAM={gpu_info['vram_mb']}MB")

    all_results = []

    try:
        for power_w in POWER_LIMITS:
            results = run_benchmarks_at_power(power_w)
            all_results.extend(results)
    finally:
        # Restore original power limit
        print(f"\nRestoring power limit to {original_limit}W...")
        try:
            set_power_limit(original_limit)
            print(f"Power limit restored to {get_power_limit()}W")
        except Exception as e:
            print(f"WARNING: Failed to restore power limit: {e}")
            print(f"Run manually: sudo nvidia-smi -pl {original_limit}")

    # Print summary table
    print(f"\n{'='*100}")
    print(f"  WATTAGE BENCHMARK SUMMARY")
    print(f"{'='*100}")

    # Group by test label
    labels = ["Code analysis (512)", "Code analysis (2K)", "Generic explanation (4K)"]
    for label in labels:
        print(f"\n  {label}")
        print(f"  {'Power Limit':>12} {'Draw':>6} {'Prompt t/s':>11} {'Gen t/s':>9} {'TTFT':>7} "
              f"{'Gen t/s/W':>10} {'Clock':>7} {'Temp':>6}")
        print(f"  {'-'*76}")
        for r in all_results:
            if r.get("label") == label and "error" not in r:
                print(f"  {r['power_limit_w']:>10}W {r.get('avg_power_draw_w', 0):>5.0f}W "
                      f"{r['prompt_tps']:>10.1f} {r['gen_tps']:>8.1f} {r['ttft']:>6.2f}s "
                      f"{r.get('gen_tps_per_watt', 0):>9.3f} {r.get('clock_mhz', 0):>6}MHz "
                      f"{r.get('gpu_temp_c', 0):>4}°C")
            elif r.get("label") == label and "error" in r:
                print(f"  {r['power_limit_w']:>10}W {'ERR':>6} {'ERR':>11} {'ERR':>9} {'ERR':>7} {'ERR':>10}")

    # JSON output
    output_file = f"benchmarks/wattage-results-{time.strftime('%Y%m%d-%H%M%S')}.json"
    with open(output_file, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nDetailed results saved to {output_file}")


if __name__ == "__main__":
    main()
