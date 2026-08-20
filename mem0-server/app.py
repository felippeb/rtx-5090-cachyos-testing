import os
from typing import Any, Dict, List, Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from mem0 import Memory
from pydantic import BaseModel

DATA_DIR = os.environ.get("MEM0_DATA_DIR", os.path.expanduser("~/.local/share/rtx-testing/mem0"))
LLM_BASE = os.environ.get("MEM0_LLM_BASE_URL", "http://localhost:10500/v1")
LLM_MODEL = os.environ.get("MEM0_LLM_MODEL", "qwen3.8-27b-text-nvfp4-mtp")
EMB_BASE = os.environ.get("MEM0_EMB_BASE_URL", "http://localhost:8080/v1")
EMB_MODEL = os.environ.get("MEM0_EMB_MODEL", "nomic-embed-text")

os.makedirs(DATA_DIR, exist_ok=True)

CONFIG = {
    "llm": {
        "provider": "openai",
        "config": {
            "model": LLM_MODEL,
            "openai_base_url": LLM_BASE,
            "api_key": "local",
            "temperature": 0.2,
        },
    },
    "embedder": {
        "provider": "openai",
        "config": {"model": EMB_MODEL, "openai_base_url": EMB_BASE, "api_key": "local"},
    },
    "vector_store": {
        "provider": "qdrant",
        "config": {
            "path": os.path.join(DATA_DIR, "qdrant"),
            "on_disk": True,
            "embedding_model_dims": 768,
        },
    },
    "history_db_path": os.path.join(DATA_DIR, "history.db"),
}

memory = Memory.from_config(CONFIG)
app = FastAPI(title="mem0 local")


class Message(BaseModel):
    role: str
    content: str


class MemoryCreate(BaseModel):
    messages: List[Message]
    user_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None


class SearchRequest(BaseModel):
    query: str
    user_id: Optional[str] = None
    limit: int = 10
    threshold: float = 0.1


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/memories")
def add_memory(req: MemoryCreate):
    if not req.user_id:
        raise HTTPException(400, "user_id is required")
    result = memory.add(
        [m.model_dump() for m in req.messages],
        user_id=req.user_id,
        metadata=req.metadata or {},
    )
    return result


@app.get("/memories")
def list_memories(user_id: str = Query(...), limit: int = Query(20)):
    return memory.get_all(filters={"user_id": user_id}, top_k=limit)


@app.delete("/memories/{memory_id}")
def delete_memory(memory_id: str):
    try:
        return memory.delete(memory_id)
    except ValueError as e:
        raise HTTPException(404, str(e))


@app.post("/search")
def search_memories(req: SearchRequest):
    if not req.user_id:
        raise HTTPException(400, "user_id is required")
    return memory.search(
        req.query,
        filters={"user_id": req.user_id},
        top_k=req.limit,
        threshold=req.threshold,
    )


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)