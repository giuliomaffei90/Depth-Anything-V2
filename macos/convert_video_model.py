# /// script
# requires-python = "==3.12.*"
# dependencies = ["torch==2.5.1", "torchvision==0.20.1", "coremltools==8.3.0", "numpy<2", "einops", "easydict",
#                 "opencv-python-headless", "tqdm"]
# ///
"""Converts Video-Depth-Anything-Small to Core ML: one 32-frame window (the model's INFER_LEN) at a fixed size.

Usage: uv run convert_video_model.py OUT.mlpackage [--width 518 --height 294]
Input `frames` is [1, 32, 3, H, W] RGB in 0…1 (ImageNet normalisation is baked in), output `depth` is [1, 32, H, W]
relative depth (disparity, larger = nearer), exactly VideoDepthAnything.forward.
"""
import argparse, subprocess, sys, tempfile, urllib.request
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

COMMIT = "4f5ae23172ba60fd7bc11ef671cca678842c7072"
WEIGHTS = "https://huggingface.co/depth-anything/Video-Depth-Anything-Small/resolve/main/video_depth_anything_vits.pth"

parser = argparse.ArgumentParser()
parser.add_argument("out")
parser.add_argument("--width", type=int, default=518)
parser.add_argument("--height", type=int, default=294)
args = parser.parse_args()
assert args.width % 14 == 0 and args.height % 14 == 0, "sizes must be multiples of 14"

work = Path(tempfile.mkdtemp(prefix="vda-"))
subprocess.run(["git", "clone", "-q", "https://github.com/DepthAnything/Video-Depth-Anything.git", work / "repo"], check=True)
subprocess.run(["git", "-C", work / "repo", "checkout", "-q", COMMIT], check=True)
urllib.request.urlretrieve(WEIGHTS, work / "vits.pth")
sys.path.insert(0, str(work / "repo"))
from video_depth_anything.video_depth import VideoDepthAnything  # noqa: E402

model = VideoDepthAnything(encoder="vits", features=64, out_channels=[48, 96, 192, 384])
model.load_state_dict(torch.load(work / "vits.pth", map_location="cpu"), strict=True)
model.eval()

# The size is fixed, so DINOv2's bicubic positional-embedding resize (which Core ML lacks) becomes a constant.
dino = model.pretrained
with torch.no_grad():
    pos = dino.interpolate_pos_encoding(torch.zeros(1, 1 + (args.height // 14) * (args.width // 14), dino.embed_dim),
                                        args.height, args.width)
dino.interpolate_pos_encoding = lambda x, w, h: pos.to(x.dtype)


class Window(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 1, 3, 1, 1))

    def forward(self, frames):
        return self.model((frames - self.mean) / self.std)


example = torch.rand(1, 32, 3, args.height, args.width)
with torch.no_grad():
    window = Window().eval()
    reference = window(example).numpy()
    traced = torch.jit.trace(window, example)

mlmodel = ct.convert(traced, inputs=[ct.TensorType(name="frames", shape=example.shape)],
                     outputs=[ct.TensorType(name="depth")], minimum_deployment_target=ct.target.macOS14,
                     compute_precision=ct.precision.FLOAT16)
mlmodel.short_description = "Video-Depth-Anything-Small (Apache-2.0), one 32-frame window"
mlmodel.save(args.out)

converted = ct.models.MLModel(args.out).predict({"frames": example.numpy()})["depth"]
err = np.abs(converted - reference).mean() / np.abs(reference).mean()
print(f"Saved {args.out}, mean relative error vs PyTorch {err:.4f}")
assert err < 0.05
