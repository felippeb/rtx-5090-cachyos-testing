#!/usr/bin/env python3
"""
NVFP4 (W4A4 FP4 E2M1) quantization script for RTX 5090 (SM120).

Uses llm-compressor with NVFP4 scheme to quantize a HuggingFace model.
Output uses compressed-tensors format and can be served with:
    vllm serve <output_dir> --quantization compressed-tensors
"""

import argparse
import json
import os
import time
from pathlib import Path

import torch
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer

from llmcompressor import oneshot
from llmcompressor.modifiers.quantization import QuantizationModifier


def prepare_calibration_dataset(dataset_name, num_samples, seq_length, tokenizer):
    """Load, tokenize, and prepare calibration dataset."""
    from datasets import Dataset

    if dataset_name == "ultrachat":
        ds = load_dataset(
            "HuggingFaceH4/ultrachat_200k",
            split=f"train_sft[:{num_samples * 3}]",
        )
        ds = ds.select_columns(["messages"])
        ds = ds.shuffle(seed=42).select(range(min(num_samples, len(ds))))
    elif dataset_name == "pile":
        ds = load_dataset(
            "mit-han-lab/pile-uncopyrighted", split="train", streaming=True
        )
        texts = []
        for i, entry in enumerate(ds):
            if i >= num_samples * 3:
                break
            if len(entry["text"]) > 500:
                texts.append({"text": entry["text"]})
        ds = Dataset.from_list(texts[:num_samples])
    else:
        ds = load_dataset(dataset_name, split="train")
        ds = ds.shuffle(seed=42).select(range(min(num_samples, len(ds))))

    # Tokenize
    if dataset_name == "ultrachat":
        def preprocess(example):
            messages = [
                {"role": m["role"], "content": [{"type": "text", "text": m["content"]}]
                }
                for m in example["messages"]
            ]
            return tokenizer.apply_chat_template(
                messages,
                tokenize=True,
                return_dict=True,
                add_generation_prompt=False,
                tokenizer_kwargs={
                    "return_tensors": "pt",
                    "padding": False,
                    "truncation": True,
                    "max_length": seq_length,
                    "add_special_tokens": False,
                },
            )
    else:
        def preprocess(example):
            return tokenizer(
                example["text"],
                truncation=True,
                max_length=seq_length,
                return_tensors="pt",
            )

    ds = ds.map(preprocess, batched=False, remove_columns=ds.column_names)
    return ds


def main():
    parser = argparse.ArgumentParser(
        description="NVFP4 Quantization for RTX 5090 (SM120)"
    )
    parser.add_argument(
        "--model_name",
        type=str,
        default="Qwen/Qwen3.6-27B-A3B",
        help="HuggingFace model ID or local path",
    )
    parser.add_argument(
        "--output_dir",
        type=str,
        default=None,
        help="Output directory (default: <model_name>_NVFP4)",
    )
    parser.add_argument(
        "--num_samples",
        type=int,
        default=128,
        help="Number of calibration samples (default: 128)",
    )
    parser.add_argument(
        "--seq_length",
        type=int,
        default=2048,
        help="Max sequence length for calibration (default: 2048)",
    )
    parser.add_argument(
        "--dataset",
        type=str,
        default="ultrachat",
        choices=["ultrachat", "pile"],
        help="Calibration dataset",
    )
    parser.add_argument(
        "--device_map",
        type=str,
        default="auto",
        help="Device map for model loading",
    )
    parser.add_argument(
        "--moe_calibrate_all",
        action="store_true",
        help="Enable MoE all-experts calibration",
    )
    args = parser.parse_args()

    if args.output_dir is None:
        model_slug = args.model_name.rstrip("/").split("/")[-1] + "-NVFP4"
        args.output_dir = f"./{model_slug}"

    print("=" * 60)
    print("NVFP4 Quantization Pipeline")
    print("=" * 60)
    print(f"Model       : {args.model_name}")
    print(f"Output      : {args.output_dir}")
    print(f"Cal samples : {args.num_samples}")
    print(f"Seq length  : {args.seq_length}")
    print(f"Dataset     : {args.dataset}")
    print(f"MoE cal     : {args.moe_calibrate_all}")
    print("-" * 60)

    start_time = time.time()

    # 1. Load model and tokenizer
    print("[1/4] Loading model and tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(
        args.model_name,
        trust_remote_code=True,
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model_name,
        torch_dtype=torch.bfloat16,
        device_map=args.device_map,
        trust_remote_code=True,
    )
    print(f"    Model loaded: {model.config.model_type}")
    num_params = sum(p.numel() for p in model.parameters())
    print(f"    Parameters: {num_params / 1e9:.2f}B")

    # 2. Build quantization recipe
    print("[2/4] Building NVFP4 quantization recipe...")
    recipe = QuantizationModifier(
        targets="Linear",
        scheme="NVFP4",
        ignore=[
            "re:.*lm_head",
            "re:visual.*",
            "re:model.visual.*",
            "re:.*mlp.gate$",
            "re:.*embed_tokens$",
            "re:.*shared_expert_gate$",
            "re:.*linear_attn.*",
        ],
    )
    print("    Scheme: NVFP4 (E2M1, group_size=16, two-level scaling)")

    # 3. Load and tokenize calibration data
    print("[3/4] Loading and tokenizing calibration data...")
    ds = prepare_calibration_dataset(
        args.dataset, args.num_samples, args.seq_length, tokenizer
    )
    print(f"    Calibration samples: {len(ds)}")

    # 4. Quantize
    print("[4/4] Running NVFP4 quantization (oneshot)...")

    def data_collator(batch):
        return {key: torch.tensor(value) for key, value in batch[0].items()}

    oneshot(
        model=model,
        recipe=recipe,
        dataset=ds,
        max_seq_length=seq_length,
        num_calibration_samples=args.num_samples,
        data_collator=data_collator,
        moe_calibrate_all_experts=args.moe_calibrate_all,
    )

    # Save quantized model
    print("Saving quantized model...")
    Path(args.output_dir).mkdir(parents=True, exist_ok=True)

    model.save_pretrained(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)

    # Ensure compressed-tensors format is recorded
    if not os.path.exists(os.path.join(args.output_dir, "quantization_config.json")):
        vllm_quant_config = {
            "quantization": "compressed-tensors",
            "format": "compressed-tensors",
            "model_name": args.model_name,
        }
        with open(
            os.path.join(args.output_dir, "quantization_config.json"), "w"
        ) as f:
            json.dump(vllm_quant_config, f, indent=2)

    elapsed = time.time() - start_time
    print("=" * 60)
    print(f"Done! Quantized model saved to: {args.output_dir}")
    print(f"Time elapsed: {elapsed:.1f}s ({elapsed / 60:.1f} min)")
    print("=" * 60)
    print()
    print("Serve with vLLM:")
    print(f"  vllm serve {args.output_dir} --quantization compressed-tensors")


if __name__ == "__main__":
    main()
