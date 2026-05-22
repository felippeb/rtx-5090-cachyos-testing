import torch
import os
from diffusers import FluxPipeline, FluxTransformer2DModel, GGUFQuantizationConfig
from pathlib import Path

MODEL_ID = "black-forest-labs/FLUX.1-schnell"
# Testing with Q4_K_S instead of Q2_K
GGUF_PATH = "/home/felippeb/.cache/huggingface/hub/models--city96--FLUX.1-schnell-gguf/snapshots/f495746ed9c5efcf4661f53ef05401dceadc17d2/flux1-schnell-Q4_K_S.gguf"

def test_generation(prompt):
    print(f"Loading transformer from {GGUF_PATH}...")
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

    print("Moving pipeline to GPU...")
    pipe = pipe.to("cuda")

    print(f"Generating image with prompt: {prompt}")
    
    image = pipe(
        prompt=prompt,
        num_inference_steps=4,
        guidance_scale=3.5,
        width=1024,
        height=1024,
    ).images[0]

    output_path = Path("/tmp/flux_q4_test.png")
    image.save(output_path, format="PNG")
    print(f"Success! Image saved to {output_path}")

if __name__ == "__main__":
    prompt = """A close-up, eye-level shot of a heavy-duty, black metal wood-fired oven or portable grill in the process of cooking. 
At the bottom of the dark, rectangular oven, wood is burning, creating bright orange flames and glowing red embers amidst a bed of grey ash. Wisps of white smoke rise from the fire, drifting upward through the cooking chamber.
Suspended in the center of the oven, held in place by a horizontal metal rod that spans the width of the device, is a cylindrical wire mesh basket. The basket is filled with pieces of meat, appearing to be chicken, which are being roasted by the heat from below.
The oven itself has thick, matte black walls with angled sides. On either side of the central fire area, long pieces of wood or wooden supports rest against the inner sides of the oven. The background is softly blurred, showing a warm-toned, sunlit wall, suggesting the cooking is taking place outdoors during the day."""
    try:
        test_generation(prompt)
    except Exception as e:
        print(f"Error: {e}")
