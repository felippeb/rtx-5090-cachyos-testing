#!/usr/bin/env python3
"""
Run tool-eval-bench with reasoning ON vs OFF.

Patches the OpenAI-compatible adapter to inject <|think_on|> or <|think_off|>
into every chat completion request, so the Qwen3.6 chat template controls
whether the model generates thinking blocks.

Usage:
    python3 benchmarks/tool-bench-reasoning.py [--short]
"""

import sys
import os
import subprocess
import json
import time

# Add tool-eval-bench to path
TBE_PATH = "/home/felippeb/.local/share/uv/tools/tool-eval-bench/lib/python3.14/site-packages"
sys.path.insert(0, TBE_PATH)

BASE_URL = "http://localhost:10500"


def patch_adapter(reasoning_mode):
    """Monkey-patch the OpenAI adapter to inject thinking markers."""
    from tool_eval_bench.adapters import openai_compat
    original_chat = openai_compat.OpenAICompatibleAdapter.chat_completion

    async def patched_chat(
        self,
        *,
        model=None,
        messages=None,
        tools=None,
        tool_choice="auto",
        temperature=0.0,
        max_tokens=4096,
        timeout_seconds=60.0,
        api_key=None,
        base_url="",
        extra_params=None,
        stream=False,
        response_format=None,
        parallel_tool_calls=True,
    ):
        # Inject thinking marker as first system message
        if messages is not None:
            think_marker = "<|think_on|>" if reasoning_mode == "on" else "<|think_off|>"
            # Check if we already injected (avoid double-injection on retries)
            has_think = any(
                m.get("role") == "system" and think_marker in str(m.get("content", ""))
                for m in messages
            )
            if not has_think:
                messages.insert(0, {"role": "system", "content": think_marker})

        return await original_chat(
            self,
            model=model,
            messages=messages,
            tools=tools,
            tool_choice=tool_choice,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout_seconds=timeout_seconds,
            api_key=api_key,
            base_url=base_url,
            extra_params=extra_params,
            stream=stream,
            response_format=response_format,
            parallel_tool_calls=parallel_tool_calls,
        )

    openai_compat.OpenAICompatibleAdapter.chat_completion = patched_chat


def run_bench(reasoning_mode, short=False):
    """Run tool-eval-bench with the patched adapter."""
    patch_adapter(reasoning_mode)

    from tool_eval_bench.cli.bench import main as bench_main

    args = []
    if short:
        args.append("--short")
    args.extend([
        "--backend", "llamacpp",
        "--timeout", "120",
    ])

    # Override sys.argv for the CLI
    old_argv = sys.argv
    sys.argv = ["tool-eval-bench"] + args

    try:
        # Set env vars that tool-eval-bench reads
        os.environ["TOOL_EVAL_BASE_URL"] = BASE_URL
        os.environ["TOOL_EVAL_API_KEY"] = ""

        print(f"\n{'='*60}")
        print(f"  Running tool-eval-bench (reasoning={reasoning_mode})")
        print(f"{'='*60}\n")

        bench_main()
    except SystemExit as e:
        if e.code not in (0, None):
            print(f"\n  WARNING: tool-eval-bench exited with code {e.code}")
    finally:
        sys.argv = old_argv


def main():
    import requests

    # Check server
    try:
        r = requests.get(f"{BASE_URL}/v1/models", timeout=5)
        if r.status_code != 200:
            raise Exception("Server not responding")
    except Exception:
        print(f"ERROR: Server not at {BASE_URL}")
        print("Start it first: ./scripts/service-switcher.sh nvfp4-mtp")
        sys.exit(1)

    short = "--short" in sys.argv

    # Phase 1: OFF
    run_bench("off", short=short)

    # Phase 2: ON  
    run_bench("on", short=short)


if __name__ == "__main__":
    main()
