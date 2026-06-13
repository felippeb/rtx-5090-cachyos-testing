#!/usr/bin/env python3
"""HumanEval+ benchmark against a local llama-server.

Measures pass@1 for the HumanEval+ dataset (164 problems).
"""

import re
import sys
import time
import traceback
import textwrap
from pathlib import Path

import requests
from evalplus.data import get_human_eval_plus

BASE_URL = "http://localhost:10500"
TIMEOUT = 120


def extract_code(text):
    """Extract Python code from model response."""
    blocks = re.findall(r"```(?:python)?\n(.*?)```", text, re.DOTALL)
    if blocks:
        return blocks[-1].strip()
    return text.strip()


def build_completion(prompt, generated):
    """Combine the prompt stub with generated body into runnable code."""
    code = extract_code(generated)
    # If model returned the full function, use as-is
    if code.startswith("def ") or code.startswith("from ") or code.startswith("import ") or code.startswith("class "):
        return code
    # Otherwise treat as indented function body appended to prompt
    return prompt + "\n" + textwrap.indent(code, "    ") if not code.startswith("    ") else prompt + "\n" + code


def run_test(solution_code, test_code, entry_point, task_id):
    """Run HumanEval test for a single problem. Returns (passed, error_msg)."""
    namespace = {}
    try:
        exec(solution_code, namespace)
    except Exception as e:
        return False, f"compile_error: {e}"

    if entry_point not in namespace:
        return False, f"missing_function: {entry_point} not defined"

    try:
        exec(test_code, namespace)
        namespace["check"](namespace[entry_point])
        return True, ""
    except AssertionError as e:
        return False, f"assertion_error: {e}"
    except Exception as e:
        return False, f"runtime_error: {e}"


def load_previous_results(path="runs/humaneval_results.txt"):
    """Load previously completed task IDs so we can resume."""
    path = Path(path)
    if not path.exists():
        return set()
    done = set()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                done.add(line)
    return done


def save_result(path, task_id, passed, detail=""):
    """Append a result line."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    icon = "PASS" if passed else "FAIL"
    with open(path, "a") as f:
        f.write(f"{task_id} {icon} {detail}\n")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="HumanEval+ benchmark")
    parser.add_argument("--port", type=int, default=10500)
    parser.add_argument("--resume", action="store_true", help="Resume from previous partial run")
    parser.add_argument("--max-problems", type=int, default=None, help="Limit number of problems")
    args = parser.parse_args()

    base_url = f"http://localhost:{args.port}"
    results_path = Path("runs/humaneval_results.txt")
    done = load_previous_results(results_path) if args.resume else set()

    # Check server
    try:
        r = requests.get(f"{base_url}/health", timeout=5)
        r.raise_for_status()
    except Exception as e:
        print(f"ERROR: Server not responding at {base_url}: {e}")
        sys.exit(1)

    model_resp = requests.get(f"{base_url}/v1/models", timeout=5).json()
    model_name = model_resp["data"][0]["id"] if model_resp.get("data") else "unknown"

    problems = get_human_eval_plus()
    task_ids = sorted(problems.keys())
    if args.max_problems:
        task_ids = task_ids[: args.max_problems]

    total = len(task_ids)
    passed = 0
    failed = 0
    skipped = 0
    results = []

    print(f"\n{'='*60}")
    print(f"  HumanEval+ Benchmark")
    print(f"  Server: {base_url}")
    print(f"  Model:  {model_name}")
    print(f"  Problems: {total} ({len(done)} already done, resuming)" if args.resume else f"  Problems: {total}")
    print(f"{'='*60}\n")

    for i, task_id in enumerate(task_ids, 1):
        if task_id in done:
            skipped += 1
            continue

        prob = problems[task_id]
        prompt_text = prob["prompt"]
        test_code = prob["test"]
        entry_point = prob["entry_point"]

        user_prompt = f"Complete the following Python function. Return ONLY the function implementation in a single code block, no explanations or extra text.\n\n```python\n{prompt_text}\n```"

        payload = {
            "messages": [
                {"role": "system", "content": "You are a code completion assistant. Do NOT think step by step. Output only the requested code."},
                {"role": "user", "content": user_prompt},
            ],
            "max_tokens": 4096,
            "temperature": 0.2,
            "top_p": 0.95,
            "stream": False,
        }

        start = time.time()
        try:
            resp = requests.post(
                f"{base_url}/v1/chat/completions",
                json=payload,
                timeout=TIMEOUT,
            )
            resp.raise_for_status()
            data = resp.json()
            raw = data["choices"][0]["message"]["content"]
            elapsed = time.time() - start
            usage = data.get("usage", {})
            prompt_tok = usage.get("prompt_tokens", 0)
            completion_tok = usage.get("completion_tokens", 0)
            gen_tps = completion_tok / elapsed if elapsed > 0 else 0
        except Exception as e:
            elapsed = time.time() - start
            print(f"  [{i}/{total}] {task_id:<15} ❌ REQ_ERR ({elapsed:.1f}s) {e}")
            save_result(results_path, task_id, False, f"request_error: {e}")
            failed += 1
            continue

        # Build and test
        solution = build_completion(prompt_text, raw)
        ok, detail = run_test(solution, test_code, entry_point, task_id)

        status = "✅" if ok else "❌"
        tok_info = f"{prompt_tok}+{completion_tok}tok {gen_tps:.1f}t/s"
        detail_str = f" {detail}" if detail else ""

        if ok:
            passed += 1
        else:
            failed += 1

        print(f"  [{i}/{total}] {task_id:<15} {status} ({elapsed:.1f}s, {tok_info}){detail_str}")
        save_result(results_path, task_id, ok, detail)

        results.append({
            "task_id": task_id,
            "entry_point": entry_point,
            "passed": ok,
            "detail": detail,
            "elapsed": round(elapsed, 2),
            "prompt_tokens": prompt_tok,
            "completion_tokens": completion_tok,
            "gen_tps": round(gen_tps, 1),
        })

    # Summary
    score = (passed / (passed + failed) * 100) if (passed + failed) > 0 else 0
    print(f"\n{'='*60}")
    print(f"  RESULTS")
    print(f"{'='*60}")
    print(f"  Model:              {model_name}")
    print(f"  Passed:             {passed}/{passed + failed} ({score:.1f}%)")
    print(f"  Skipped (resume):   {skipped}")
    print(f"  Total time:         {sum(r['elapsed'] for r in results):.1f}s")
    print(f"  Avg time/problem:   {sum(r['elapsed'] for r in results) / max(len(results), 1):.1f}s")
    print(f"  Avg gen speed:      {sum(r['gen_tps'] for r in results) / max(len(results), 1):.1f} t/s")

    # Per-task list
    print(f"\n  Per-task results:")
    for r in results:
        status = "✅" if r["passed"] else "❌"
        print(f"    {r['task_id']:<15} {status}  {r['elapsed']}s  {r['detail']}")

    avg_tps = sum(r['gen_tps'] for r in results) / max(len(results), 1)
    print(f"\n  pass@1: {score:.1f}% ({passed}/{passed + failed})")
    print(f"  gen speed: {avg_tps:.1f} t/s avg")

    return score


if __name__ == "__main__":
    main()
