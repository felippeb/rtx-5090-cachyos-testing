import torch
import os
from diffusers import FluxPipeline, FluxTransformer2DModel, GGUFQuantizationConfig
from pathlib import Path

MODEL_ID = "black-forest-labs/FLUX.1-schnell"
GGUF_PATH = "/home/felippeb/.cache/huggingface/hub/models--city96--FLUX.1-schnell-gguf/snapshots/f495746ed9c5efcf4661f53ef05401dceadc17d2/flux1-schnell-Q2_K.gguf"

def test_generation():
    print("Loading transformer...")
    transformer = FluxTransformer2DModel.from_single_file(
        GGUF_PATH,
        quantization_config=GGUFQuantizationConfig(compute_dtype=torch.bfloat16),
        torch_dtype=torch.bfloat16,
    )

    print("Loading pipeline...")
    pipe = FluxPipeline.from_pretrained(
        MODEL_ID,
        transformer=transformer,
        torch_dtype=torch.bfloat16,
    )

    print("Enabling CPU offload...")
    pipe.enable_model_cpu_offload()

    prompt = "A futuristic cyberpunk city with neon lights, high detail, 4k"
    print(f"Generating image with prompt: {prompt}")
    
    image = pipe(
        prompt=prompt,
        num_inference_steps=4,
        guidance_scale=3.5,
        width=1024,
        height=1024,
    ).images[0]

    output_path = Path("/tmp/flux_test.png")
    image.save(output_path, format="PNG")
    print(f"Success! Image saved to {output_path}")

if __name__ == "__main__":
    try:
        test_generation()
    except Exception as e:
        print(f"Error: {e}")
