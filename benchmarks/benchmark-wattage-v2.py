#!/usr/bin/env python3
"""Wattage benchmark v2: uses a realistic coding challenge to saturate GPU power.

Based on the Oquirrh Firewood Next.js site prompt — a complex multi-file coding
task that generates thousands of tokens over several minutes, actually pushing
the GPU to sustained power draw.
"""

import json
import subprocess
import sys
import time

BASE_URL = "http://localhost:10500"

# Realistic coding challenge: full Next.js site generation
# This is the kind of prompt that actually saturates a GPU for minutes
CODING_CHALLENGE = (
    "Build a Next.js 14 static website for \"Oquirrh Firewood\" — a family in "
    "Herriman, UT (along the Oquirrh Mountains) selling premium hickory and "
    "pecan BBQ smoking wood.\n"
    "Business Details:\n"
    "- Name: Oquirrh Firewood\n"
    "- Location: Herriman, UT (Oquirrh Mountains, NOT West Valley)\n"
    "- Phone: (801) 555-0000\n"
    "- Pickup only (NO delivery) — off I-215 or Mountain View Corridor\n"
    "- Customers come from across Wasatch Front: West Valley, SLC, Sandy, "
    "Draper, Eagle Mountain, Saratoga Springs, Provo, Orem, etc.\n"
    "- Payment: Cash or Venmo at pickup\n"
    "Pricing/Bundles:\n"
    "- BBQ Sampler — Hickory + Pecan Mix ($59)\n"
    "- Weekend Smoke Bundle — Hickory + Pecan Mix ($99)\n"
    "- Pitmaster Bundle — Hickory + Pecan Mix ($169)\n"
    "- Hickory Pure Bundle — 1/4 cord ($129)\n"
    "- Pecan Pure Bundle — 1/4 cord ($129)\n"
    "- Custom — Tell Us What You Need\n"
    "Technical Requirements:\n"
    "- Next.js 14 App Router with output: 'export' for static generation\n"
    "- Tailwind CSS with custom dark theme: ember (orange), wood (brown), "
    "smoke (gray) color palettes\n"
    "- 4 pages: /, /products, /about, /contact\n"
    "- Components: Navbar, Footer, Hero, ProductCard, ValueProps, "
    "AboutSection, ContactForm, FAQ\n"
    "- Formspree integration for order form (placeholder ID YOUR_FORMSPREE_ID)\n"
    "- JSON-LD structured data (LocalBusiness schema) with areaServed "
    "covering all Wasatch Front cities\n"
    "- Open Graph / Twitter Card meta tags\n"
    "- robots.txt, custom 404, favicon\n"
    "- Domain placeholder: oquirrhfirewood.com\n"
    "Content Notes:\n"
    "- Tone: Neighbor-to-neighbor, not commercial\n"
    "- Emphasize: Family BBQ enthusiasts sharing quality wood, fair prices, "
    "no middlemen\n"
    "- Herriman is along Oquirrh Mountains, easy pickup from Mountain View "
    "Corridor\n"
    "- NO delivery references — pickup only\n"
    "- Service area: West Valley, SLC, Sandy, Draper, Murray, Midvale, "
    "Eagle Mountain, Saratoga Springs, American Fork, Provo, Orem\n"
    "Deployment:\n"
    "- Cloudflare Pages (free, unlimited bandwidth, no commercial "
    "restrictions)\n"
    "- Set up Terraform in terraform/ directory with:\n"
    "  - Cloudflare provider (~> 4.0)\n"
    "  - Variables: cloudflare_email, cloudflare_api_key, account_id, "
    "project_name, domain, production_branch\n"
    "  - Resources: Pages project, custom domain, www CNAME record\n"
    "  - terraform.tfvars.example template\n"
    "  - .gitignore for tfstate/tfvars\n"
    "- DEPLOY.md with full deployment guide\n"
    "SEO:\n"
    "- Keywords: firewood Utah, BBQ wood Herriman, hickory firewood, pecan "
    "wood, Oquirrh firewood, smoking wood Utah, etc.\n"
    "- Area served in JSON-LD: all Wasatch Front cities listed above\n\n"
    "Create ALL files with complete, production-ready code. Include every "
    "component, every page, every config file. Do not skip any files or "
    "use placeholders for code content."
)


def get_power_limit():
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=power.limit", "--format=csv,noheader,nounits"],
        text=True, timeout=5
    ).strip()
    return int(float(out))


def set_power_limit(watts):
    subprocess.run(
        ["nvidia-smi", "-pl", str(watts)],
        check=True, capture_output=True, text=True, timeout=10
    )


def get_gpu_stats():
    out = subprocess.check_output(
        ["nvidia-smi",
         "--query-gpu=power.draw,temperature.gpu,clocks.gr,clocks.sm,memory.used",
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



def benchmark_coding_challenge(max_tokens=16384, temp=0.6):
    """Run the full coding challenge and collect metrics + power samples."""
    import threading
    import requests

    payload = {
        "model": "qwen3.6-27b",
        "messages": [{"role": "user", "content": CODING_CHALLENGE}],
        "max_tokens": max_tokens,
        "temperature": temp,
        "top_p": 0.95,
        "top_k": 20,
        "stream": False,
    }

    # Start power monitoring in background
    power_samples = []
    stop_event = threading.Event()

    def monitor_power_bg():
        while not stop_event.is_set():
            try:
                stats = get_gpu_stats()
                stats["ts"] = time.time()
                power_samples.append(stats)
            except Exception:
                pass
            stop_event.wait(1)

    monitor_thread = threading.Thread(target=monitor_power_bg, daemon=True)
    monitor_thread.start()

    start = time.time()
    try:
        resp = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, timeout=1800)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        stop_event.set()
        monitor_thread.join(timeout=5)
        return {"error": str(e), "power_samples": list(power_samples)}
    finally:
        stop_event.set()
        monitor_thread.join(timeout=5)

    elapsed = time.time() - start
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
    acceptance = (draft_accepted / draft_n * 100) if draft_n > 0 else 0

    # Compute power stats from samples (snapshot the list)
    samples_snapshot = list(power_samples)
    if samples_snapshot:
        powers = [s["power_w"] for s in samples_snapshot]
        temps = [s["temp_c"] for s in samples_snapshot]
        avg_power = sum(powers) / len(powers)
        max_power = max(powers)
        avg_temp = sum(temps) / len(temps)
        max_temp = max(temps)
    else:
        avg_power = max_power = avg_temp = max_temp = 0

    return {
        "prompt_tokens": prompt_n,
        "gen_tokens": completion_n,
        "prompt_tps": round(prompt_tps, 1),
        "gen_tps": round(gen_tps, 1),
        "ttft": round(prompt_ms / 1000, 3),
        "total_time": round(elapsed, 2),
        "draft_total": draft_n,
        "draft_accepted": draft_accepted,
        "acceptance_pct": round(acceptance, 1),
        "avg_power_w": round(avg_power, 1),
        "max_power_w": round(max_power, 1),
        "avg_temp_c": round(avg_temp, 1),
        "max_temp_c": max_temp,
        "gen_tps_per_watt": round(gen_tps / avg_power, 3) if avg_power > 0 else 0,
        "power_samples_count": len(samples_snapshot),
        "power_samples": samples_snapshot,
    }


def main():
    import requests

    POWER_LIMITS = [400, 425, 450, 475, 500, 525, 550, 575]
    original_limit = get_power_limit()

    print(f"Original power limit: {original_limit}W")
    print(f"Testing power limits: {POWER_LIMITS}")
    print(f"Challenge: Full Next.js 14 static site (Oquirrh Firewood)")
    print(f"Max tokens per run: 16384")

    # Check server
    try:
        r = requests.get(f"{BASE_URL}/health", timeout=5)
        print(f"Server health: {r.text.strip()}")
    except Exception as e:
        print(f"ERROR: Cannot reach server: {e}")
        sys.exit(1)

    gpu = get_gpu_stats()
    print(f"GPU: {gpu['power_w']}W, {gpu['temp_c']}°C, {gpu['clock_mhz']}MHz\n")

    all_results = []

    try:
        for power_w in POWER_LIMITS:
            print(f"\n{'#'*70}")
            print(f"  POWER LIMIT: {power_w}W")
            print(f"{'#'*70}")

            set_power_limit(power_w)
            time.sleep(5)  # Let GPU settle to new power state

            gpu_state = get_gpu_stats()
            print(f"  GPU: {gpu_state['power_w']}W, {gpu_state['temp_c']}°C, "
                  f"{gpu_state['clock_mhz']}MHz")

            # Cool-down period between runs
            print("  Cooling down (10s)...")
            time.sleep(10)

            print("  Running coding challenge...")
            result = benchmark_coding_challenge()

            if "error" not in result:
                result["power_limit_w"] = power_w
                print(f"  Done in {result['total_time']}s")
                print(f"  Tokens: {result['prompt_tokens']} prompt + "
                      f"{result['gen_tokens']} gen = "
                      f"{result['prompt_tokens'] + result['gen_tokens']} total")
                print(f"  Speed: {result['prompt_tps']} t/s prompt, "
                      f"{result['gen_tps']} t/s gen")
                print(f"  Power: avg={result['avg_power_w']}W, "
                      f"max={result['max_power_w']}W")
                print(f"  Temp: avg={result['avg_temp_c']}°C, "
                      f"max={result['max_temp_c']}°C")
                print(f"  Efficiency: {result['gen_tps_per_watt']} gen t/s/W")
                print(f"  Draft acceptance: {result['acceptance_pct']}%")
                all_results.append(result)
            else:
                result["power_limit_w"] = power_w
                print(f"  ERROR: {result['error']}")
                all_results.append(result)
    finally:
        print(f"\nRestoring power limit to {original_limit}W...")
        try:
            set_power_limit(original_limit)
            print(f"Restored to {get_power_limit()}W")
        except Exception as e:
            print(f"WARNING: Failed to restore: {e}")
            print(f"Run: sudo nvidia-smi -pl {original_limit}")

    # Summary
    print(f"\n{'='*90}")
    print(f"  CODING CHALLENGE WATTAGE RESULTS")
    print(f"{'='*90}")
    print(f"  {'Limit':>6} {'Avg Draw':>9} {'Max Draw':>9} {'Gen t/s':>8} "
          f"{'t/s/W':>7} {'Avg Temp':>9} {'Max Temp':>9} {'Time':>7} {'Tokens':>7}")
    print(f"  {'-'*82}")

    for r in all_results:
        if "error" not in r:
            total_tokens = r["prompt_tokens"] + r["gen_tokens"]
            print(f"  {r['power_limit_w']:>4}W {r['avg_power_w']:>7.1f}W "
                  f"{r['max_power_w']:>7.1f}W {r['gen_tps']:>7.1f} "
                  f"{r['gen_tps_per_watt']:>6.3f} {r['avg_temp_c']:>7.1f}°C "
                  f"{r['max_temp_c']:>7}°C {r['total_time']:>6.1f}s "
                  f"{total_tokens:>6}")
        else:
            print(f"  {r['power_limit_w']:>4}W {'ERR':>9} {'ERR':>9} {'ERR':>8} "
                  f"{'ERR':>7} {'ERR':>9} {'ERR':>9} {'ERR':>7} {'ERR':>7}")

    # Save results (strip raw power samples for cleaner JSON)
    output_file = f"benchmarks/wattage-v2-results-{time.strftime('%Y%m%d-%H%M%S')}.json"
    clean_results = []
    for r in all_results:
        cr = {k: v for k, v in r.items() if k != "power_samples"}
        cr["power_timeline"] = [
            {"ts": s["ts"], "w": s["power_w"], "temp": s["temp_c"], "clk": s["clock_mhz"]}
            for s in r.get("power_samples", [])
        ]
        clean_results.append(cr)

    with open(output_file, "w") as f:
        json.dump(clean_results, f, indent=2)
    print(f"\nResults saved to {output_file}")


if __name__ == "__main__":
    main()
