import os
import boto3
import litserve as ls
import torch
import torch.nn as nn


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


class InferenceEngine(ls.LitAPI):
    def setup(self, device):

        local_path = "model.pth"
        
        ckpt = torch.load(local_path, map_location="cpu")

        self.in_features = ckpt.get("in_features")

        self.model = SimpleRegressor(in_features=self.in_features)
        self.model.load_state_dict(ckpt["state_dict"])
        self.model.eval()

        # If you want to use GPU when available:
        self.device = device
        self.model.to(self.device)

    def predict(self, request):
        # Expect either:
        # 1) {"input": [1,2,3,4]}            -> single sample
        # 2) {"input": [[1,2,3,4], ...]}     -> batch
        payload = request.get("input", None)
        if payload is None:
            raise ValueError("Request must contain key 'input'.")

        x = torch.tensor(payload, dtype=torch.float32)

        # Ensure shape (N, in_features)
        if x.ndim == 1:
            x = x.unsqueeze(0)  # (4,) -> (1,4)

        if x.ndim != 2 or x.shape[1] != self.in_features:
            raise ValueError(f"Expected input shape (N, {self.in_features}), got {tuple(x.shape)}")

        x = x.to(self.device)

        with torch.no_grad():
            y = self.model(x)  # (N, 1)

        # Return as list of floats: (N,)
        return {"output": y.squeeze(-1).detach().cpu().tolist()}


if __name__ == "__main__":
    server = ls.LitServer(InferenceEngine(max_batch_size=1), accelerator="auto")
    server.run(host="0.0.0.0", port=8080, generate_client_file=False)