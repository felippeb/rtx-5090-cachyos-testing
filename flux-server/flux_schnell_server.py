import os
import tempfile
import base64
import logging
import time
from pathlib import Path
from contextlib import asynccontextmanager

import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from diffusers import FluxPipeline, FluxTransformer2DModel, GGUFQuantizationConfig

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("flux-server")

MODEL_ID = "black-forest-labs/FLUX.1-schnell"
GGUF_PATH = os.environ.get(
    "FLUX_GGUF_PATH",
    "/home/felippeb/.cache/huggingface/hub/models--city96--FLUX.1-schnell-gguf/snapshots/f495746ed9c5efcf4661f53ef05401dceadc17d2/flux1-schnell-Q2_K.gguf",
)
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Loading FLUX.1-schnell GGUF on {DEVICE}...")
    start = time.time()

    transformer = FluxTransformer2DModel.from_single_file(
        GGUF_PATH,
        quantization_config=GGUFQuantizationConfig(compute_dtype=torch.bfloat16),
        torch_dtype=torch.bfloat16,
    )

    pipe = FluxPipeline.from_pretrained(
        MODEL_ID,
        transformer=transformer,
        torch_dtype=torch.bfloat16,
    )
    if torch.cuda.is_available():
        pipe = pipe.to("cuda")
        pipe.enable_vae_tiling()
        logger.info("FLUX running on GPU only")
    else:
        pipe = pipe.to("cpu")
        logger.info("FLUX running on CPU only")

    logger.info(f"Model loaded in {time.time() - start:.1f}s")
    app.state.pipe = pipe
    yield

app = FastAPI(title="FLUX.1-schnell Image Generation", lifespan=lifespan)

OUTPUT_DIR = Path("/tmp/flux-outputs")
OUTPUT_DIR.mkdir(exist_ok=True)

class GenerateRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=1000, description="Image generation prompt")
    width: int = Field(default=1024, ge=256, le=2048, description="Image width (must be multiple of 16)")
    height: int = Field(default=1024, ge=256, le=2048, description="Image height (must be multiple of 16)")
    num_inference_steps: int = Field(default=4, ge=1, le=8, description="FLUX.1-schnell needs only 4 steps")
    guidance_scale: float = Field(default=3.5, ge=0.1, le=20.0)
    seed: int | None = Field(default=None, description="Random seed for reproducibility")
    return_base64: bool = Field(default=False, description="Return base64 instead of file path")

class GenerateResponse(BaseModel):
    image_path: str | None = None
    image_base64: str | None = None
    seed: int | None = None
    steps: int = 0
    generation_time: float = 0.0

@app.get("/health")
async def health():
    return {"status": "ok", "model": MODEL_ID, "device": DEVICE}

@app.get("/models")
async def list_models():
    return {
        "object": "list",
        "data": [{
            "id": MODEL_ID,
            "object": "model",
            "type": "image-generation",
            "max_resolution": "2048x2048",
            "default_steps": 4,
        }]
    }

@app.post("/generate", response_model=GenerateResponse)
async def generate(req: GenerateRequest):
    if req.width % 16 != 0 or req.height % 16 != 0:
        raise HTTPException(status_code=400, detail="Width and height must be multiples of 16")

    start = time.time()
    generator = torch.Generator(device=DEVICE)
    if req.seed is not None:
        generator.manual_seed(req.seed)
    else:
        req.seed = torch.randint(0, 2**32, (1,)).item()
        generator.manual_seed(req.seed)

    image = app.state.pipe(
        prompt=req.prompt,
        num_inference_steps=req.num_inference_steps,
        guidance_scale=req.guidance_scale,
        generator=generator,
        width=req.width,
        height=req.height,
    ).images[0]

    filename = f"flux_{int(time.time())}_{req.seed}.png"
    filepath = OUTPUT_DIR / filename
    image.save(filepath, format="PNG")

    elapsed = time.time() - start
    logger.info(f"Generated {filepath} in {elapsed:.1f}s")

    resp = GenerateResponse(
        seed=req.seed,
        steps=req.num_inference_steps,
        generation_time=round(elapsed, 2),
    )

    if req.return_base64:
        resp.image_base64 = base64.b64encode(filepath.read_bytes()).decode("utf-8")
    else:
        resp.image_path = str(filepath)

    return resp

@app.post("/generate/file")
async def generate_file(req: GenerateRequest):
    resp = await generate(req)
    if resp.image_path and Path(resp.image_path).exists():
        return FileResponse(resp.image_path, media_type="image/png", filename=Path(resp.image_path).name)
    raise HTTPException(status_code=500, detail="Image file not found")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=10501)
