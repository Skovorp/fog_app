# FeralDemo v2 — live streaming inference

Landscape, fullscreen iPhone app. Records live video at 24 fps from the back
camera, streams it through V-JEPA on-device, and visualizes per-frame scores
as a sliding color bar at the bottom of the screen.

## Flow

1. **RecordScreen** — black screen, white "Start" button.
2. **LiveRecordingScreen** — camera preview fills the screen. A sliding color
   bar at the bottom shows one square per captured frame:
   - **grey** = frame not yet inferred
   - **green** = score close to 0
   - **red** = score close to 1
   Each processed square also has its `0..100` percent drawn in white for
   debugging.
   A red **Stop** pill in the top-right ends the session and returns to idle.
3. **ErrorScreen** — fallback if camera permission is denied or the model
   fails to load.

## Inference policy

- One inference at a time. Never queues a second chunk while one is running.
- When the current chunk finishes, the next chunk is the **latest 64 captured
  frames that haven't been processed yet**. If the model is slow, the
  intermediate frames are skipped and stay grey forever.

This is implemented in `FrameBuffer.swift` (~110 lines).

## Layout

```
v2/
├── README.md
├── project.yml                 ← xcodegen spec (landscape, fullscreen)
└── FeralDemo/
    ├── App.swift               ← @main + AppState + AppPhase
    ├── RecordScreen.swift      ← idle / start
    ├── LiveRecordingScreen.swift ← camera + bar + stop
    ├── CameraPreviewView.swift ← AVCaptureVideoPreviewLayer wrapper
    ├── CameraSession.swift     ← continuous 24-fps capture (no auto-stop)
    ├── FrameBuffer.swift       ← scheduling + score state
    ├── FrameBarView.swift      ← Canvas-based sliding color bar
    ├── Preprocess.swift        ← CVPixelBuffer → MLMultiArray
    ├── Inference.swift         ← MLModel wrapper
    ├── FeralModel.mlpackage    ← symlink to ../v1/FeralDemo/FeralModel.mlpackage
    └── Info.plist              ← landscape-only, fullscreen, NSCameraUsageDescription
```

## Generate the Xcode project

```bash
cd /Users/ksc/feral_analysis/yc_demo/v2
xcodegen
open FeralDemo.xcodeproj
```

`PRODUCT_BUNDLE_IDENTIFIER` is `com.razza.feraldemov2` so v1 and v2 can both be
installed on the same phone.

## Simulator vs device

- **Simulator** doesn't have AVCaptureSession. The screen falls back to a
  synthetic frame stream — frames stream in at 24 Hz with no pixel buffer; once
  every 64 frames, that prior chunk is retroactively stamped with random scores
  so you can verify the bar's sliding/coloring/percent-overlay behavior.
- **Physical iPhone** is required to actually exercise the camera and run
  CoreML.

## Decisions worth knowing

- **Square width 16 pt, bar height 70 pt** — fits ~52 squares (~2.2 s) on an
  iPhone 12 landscape, leaving room for the 8 pt percent text.
- **Buffers retained for the latest 128 frames + the inflight inference
  window**, dropped otherwise. Keeps memory bounded across long recordings.
- **`output.alwaysDiscardsLateVideoFrames = true`** — if the main thread
  briefly lags, we drop frames rather than stall the capture queue. The bar
  reflects what was actually delivered.
- **Sensor-native rotation (0°)** — the app is locked to landscape via
  Info.plist; if you hold the phone with the home indicator on the *left*, the
  preview will be upside down. Easy fix later: observe device orientation and
  flip rotationAngle to 180.
