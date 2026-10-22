# Depth Anything for Mac

A native SwiftUI app that runs Depth Anything V2 on images, like `run.py`: add images or folders, see the
relative depth map alone or side by side with the original, in the Spectral or grayscale palette, and export
one PNG or the whole batch.

It uses [Apple's Core ML port of Depth-Anything-V2-Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)
(Float16, ~50 MB) on the Neural Engine, so it needs no Python, PyTorch or checkpoints.

## Requirements

macOS 14 or later (Liquid Glass design on macOS 26 and later), Xcode command-line tools to build.

## Build

```bash
macos/build.sh
open "macos/build/Depth Anything.app"
```

The first build downloads the model into `macos/Models/`.

## Known limitations

- Small model only, at its fixed 518×392 input; Base/Large and `--input-size` need their own Core ML conversion.
- No video (`run_video.py`) or metric depth / point clouds (`metric_depth/`).
- Images are read at up to 4096 px on the long side.
