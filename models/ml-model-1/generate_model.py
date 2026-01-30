import torch
import torch.nn as nn

class SimpleRegressor(nn.Module):
    def __init__(self, in_features: int = 4):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(in_features, 8),
            nn.ReLU(),
            nn.Linear(8, 1),
        )

    def forward(self, x):
        return self.net(x)

def main():
    torch.manual_seed(0)
    model = SimpleRegressor(in_features=4).eval()

    ckpt = {
        "model_class": "SimpleRegressor",
        "in_features": 4,
        "state_dict": model.state_dict(),
    }

    torch.save(ckpt, "model.pth")  # regular pickle-based PyTorch checkpoint
    print("Saved model.pth (non-TorchScript)")

if __name__ == "__main__":
    main()