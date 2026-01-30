import os
import boto3
import litserve as ls
import torch

class InferenceEngine(ls.LitAPI):
    def setup(self, device):
        s3 = boto3.client("s3")
        bucket = os.environ["S3_BUCKET"]
        prefix = os.environ["S3_PREFIX"]

        s3.download_file(bucket, prefix + "/model.pt", "/tmp/model.pt")
        self.model = torch.load("/tmp/model.pt")
        self.model.eval()

    def predict(self, request):
        x = torch.tensor(request["input"]).float()
        with torch.no_grad():
            return {"output": self.model(x).tolist()}

if __name__ == "__main__":
    server = ls.LitServer(InferenceEngine(max_batch_size=1), accelerator="auto")
    server.run(host="0.0.0.0", port=8080, generate_client_file=False)