# Depth Anything for Mac

A native SwiftUI app with three alike workspaces, switched from the toolbar or with ⌘1 / ⌘2 / ⌘3:

- **Photos** runs Depth Anything V2 on images, like `run.py`: add images or folders, see the relative depth map
  alone or side by side with the original (for checking), in the Spectral or grayscale palette, and export the depth
  maps as one PNG or the whole batch.
- **Videos** runs [Video Depth Anything](https://github.com/DepthAnything/Video-Depth-Anything) on videos, with its
  32-frame windows and keyframe alignment, so the depth stays consistent from frame to frame: preview it in a player
  (alone or side by side for checking, either palette) and export the depth as one MPEG-4 movie or the whole batch,
  with the original audio.
- **Cinematic** extracts the depth an iPhone records in Cinematic mode (the clip's disparity track, read with Apple's
  Cinematic framework, no model), with the same player and export as Videos.

Photos use [Apple's Core ML port of Depth-Anything-V2-Small](https://huggingface.co/apple/coreml-depth-anything-v2-small)
(Float16, ~50 MB); videos use Video-Depth-Anything-Small (Apache-2.0), converted to Core ML by
`convert_video_model.py` (Float16, ~57 MB). The app itself needs no Python, PyTorch or checkpoints.

## Requirements

macOS 14 or later (Liquid Glass design on macOS 26 and later). To build: Xcode command-line tools, and
[uv](https://docs.astral.sh/uv/) for the one-off video model conversion.

## Build

```bash
macos/build.sh
open "macos/build/Depth Anything.app"
```

The first build downloads the photo model into `macos/Models/` and converts the video model there (it fetches
PyTorch and the checkpoint into a temporary environment, which takes a few minutes).

## Known limitations

- Small model only, at its fixed 518×392 input; Base/Large and `--input-size` need their own Core ML conversion.
- Video model: Small only, at a fixed 518×294 input (frames are stretched to it, so portrait clips lose detail);
  no metric depth, streaming mode, NPZ/EXR output or frame-rate/length limits.
- A video's depth is kept in memory while it's estimated (~600 KB per frame), so very long clips need a lot of RAM.
- Cinematic clips must keep their depth when shared: export from Photos with "Include all photo data" / AirDrop
  with "All Photos Data", otherwise the disparity track is stripped. The map is the iPhone's low-resolution one,
  normalised over the whole clip.
- No metric depth / point clouds (`metric_depth/`) for photos.
- Images are read at up to 4096 px on the long side.
