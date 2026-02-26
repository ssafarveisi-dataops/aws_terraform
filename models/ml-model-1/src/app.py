import os
from contextlib import asynccontextmanager
from typing import List, Union

import boto3
import torch
import uvicorn
import torch.nn as nn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


# ----------------------------
# Model definition
# ----------------------------
class SimpleRegressor(nn.Module):
    def __init__(self, in_features: int):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_features, 8),
            nn.ReLU(),
            nn.Linear(8, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


# ----------------------------
# Request / response schemas
# ----------------------------
Vector = List[float]
Batch = List[Vector]
InputType = Union[Vector, Batch]


class PredictRequest(BaseModel):
    input: InputType = Field(
        ...,
        description="Either a single sample [f1,f2,...] or a batch [[...],[...]]",
    )


class PredictResponse(BaseModel):
    output: List[float]


# ----------------------------
# Lifespan: model loading
# ----------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    bucket = os.environ.get("S3_BUCKET")
    prefix = os.environ.get("S3_PREFIX")
    openapi_key = os.environ.get("OPENAPI_KEY")
    
    print(f"The OpenAPI key is: {openapi_key}")

    if not bucket or not prefix:
        raise RuntimeError("Missing required env vars: S3_BUCKET and/or S3_PREFIX")

    s3 = boto3.client("s3")
    local_path = "/tmp/model.pth"
    key = f"{prefix.rstrip('/')}/model.pth"

    try:
        s3.download_file(bucket, key, local_path)
    except Exception as e:
        raise RuntimeError(f"Failed to download model from s3://{bucket}/{key}: {e}")

    try:
        ckpt = torch.load(local_path, map_location="cpu")
        in_features = ckpt["in_features"]

        model = SimpleRegressor(in_features=in_features)
        model.load_state_dict(ckpt["state_dict"])
        model.eval()
    except Exception as e:
        raise RuntimeError(f"Failed to load checkpoint: {e}")

    app.state.model = model
    app.state.in_features = in_features

    yield

    # cleanup
    app.state.model = None
    app.state.in_features = None


# ----------------------------
# Build FastAPI app with ROOT_PATH
# ----------------------------
def create_app() -> FastAPI:
    root_path = os.environ.get("ROOT_PATH", "").strip()

    if root_path:
        # must NOT start or end with '/'
        if root_path.startswith("/") or root_path.endswith("/"):
            raise RuntimeError(
                "ROOT_PATH must NOT start or end with '/'. Example: ROOT_PATH=poc-deployment/ml-model-1"
            )
        # FastAPI expects leading slash in root_path
        root_path_final = f"/{root_path}"
    else:
        root_path_final = ""

    return FastAPI(
        title="Simple Regressor API",
        version="1.0.0",
        lifespan=lifespan,
        root_path=root_path_final,  # <-- important for ALB prefix
    )


app = create_app()


# ----------------------------
# Endpoints
# ----------------------------
@app.get("/health")
def health():
    if getattr(app.state, "model", None) is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"status": "ok"}


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    model: nn.Module | None = getattr(app.state, "model", None)
    in_features: int | None = getattr(app.state, "in_features", None)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    try:
        x = torch.tensor(req.input, dtype=torch.float32)

        if x.ndim == 1:
            x = x.unsqueeze(0)

        if x.ndim != 2 or x.shape[1] != in_features:
            raise ValueError(f"Expected shape (N, {in_features}), got {tuple(x.shape)}")

        with torch.no_grad():
            y = model(x)

        out = y.squeeze(-1).detach().cpu().tolist()
        if isinstance(out, float):
            out = [out]

        return PredictResponse(output=out)

    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Inference error: {e}")

if __name__ == "__main__":
    config = uvicorn.Config("app:app", port=8080, host="0.0.0.0", log_level="info")
    server = uvicorn.Server(config)
    server.run()