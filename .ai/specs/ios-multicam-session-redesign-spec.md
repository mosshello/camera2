spec_id: ios-multicam-session-redesign-20260425
goal: Fix iOS dual-camera behavior so front and back camera previews can run simultaneously and the existing React Native layout modes render the expected camera feeds.
intent: Replace the current two-independent-session implementation with Apple's supported `AVCaptureMultiCamSession` design, while preserving the current JS/native module contract as much as practical.
status: draft

# Scope

## target_files

- `my-app/native/LocalPods/DualCamera/DualCameraView.h`
- `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- `my-app/native/LocalPods/DualCamera/DualCameraSessionManager.h`
- `my-app/native/LocalPods/DualCamera/DualCameraSessionManager.m`
- `my-app/native/LocalPods/DualCamera/DualCameraModule.h`
- `my-app/native/LocalPods/DualCamera/DualCameraModule.m`
- `my-app/native/LocalPods/DualCamera/DualCameraEventEmitter.h`
- `my-app/native/LocalPods/DualCamera/DualCameraEventEmitter.m`
- `my-app/App.js`

## out_of_scope

- Android behavior.
- Replacing the custom native camera implementation with `expo-camera`.
- Committing generated `my-app/ios/`.
- Full dual-camera composited video export that exactly records the PiP/split layout. Apple designs that with two video data outputs plus a compositor/`AVAssetWriter`; that is a larger media pipeline than the current `AVCaptureMovieFileOutput` implementation.
- Multi-device/external-camera support.

# Research Findings

- Apple states that, before the iOS 13 MultiCam API, iOS AVFoundation limited apps to one active camera at a time. The current code starts two independent `AVCaptureSession` instances, which matches the failure mode where one camera wins and the other does not stream.
  - Source: Apple WWDC19 "Introducing Multi-Camera Capture for iOS", lines 198-213: https://developer.apple.com/kr/videos/play/wwdc2019/249/
- Apple's supported model is `AVCaptureMultiCamSession`, one session containing multiple inputs, outputs, preview layers, and explicit `AVCaptureConnection` objects.
  - Source: Apple WWDC19, lines 213-224 and 238-241: https://developer.apple.com/kr/videos/play/wwdc2019/249/
- For MultiCam, Apple recommends avoiding implicit connection creation and using `addInputWithNoConnections`, `addOutputWithNoConnections`, preview layers created with no connection, and manual `AVCaptureConnection` wiring.
  - Sources:
    - `AVCaptureConnection`: https://developer.apple.com/documentation/avfoundation/avcaptureconnection
    - `AVCaptureVideoPreviewLayer init(sessionWithNoConnection:)`: https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/init%28sessionwithnoconnection%3A%29
    - `AVCaptureConnection init(inputPort:videoPreviewLayer:)`: https://developer.apple.com/documentation/avfoundation/avcaptureconnection/init%28inputport%3Avideopreviewlayer%3A%29
- MultiCam is hardware- and format-limited. The app must check device support with `AVCaptureMultiCamSession.isMultiCamSupported`, choose formats where `AVCaptureDeviceFormat.isMultiCamSupported` is true, and avoid configurations where `hardwareCost` is greater than 1.
  - Sources:
    - `AVCaptureMultiCamSession.isMultiCamSupported`: https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession/ismulticamsupported
    - `AVCaptureDevice.Format.isMultiCamSupported`: https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/ismulticamsupported
    - `AVCaptureSession.hardwareCost`: https://developer.apple.com/documentation/avfoundation/avcapturesession/hardwarecost
- Apple's AVMultiCamPiP sample architecture uses two camera inputs, two video preview layers, and two video data outputs; for a single recorded PiP movie, it composites frames before writing them.
  - Source: Apple AVMultiCamPiP sample: https://developer.apple.com/documentation/AVFoundation/avmulticampip-capturing-from-multiple-cameras
  - Source: Apple WWDC19, lines 247-249: https://developer.apple.com/kr/videos/play/wwdc2019/249/

# Current Code Problem

- `DualCameraView.m` owns `frontSession` and `backSession` as separate `AVCaptureSession` instances.
- The back session receives `AVCapturePhotoOutput` and `AVCaptureMovieFileOutput`; the front session only receives an input and preview layer.
- Both sessions are started in sequence with `[front startRunning]` then `[back startRunning]`.
- Preview layers are created with `layerWithSession:` and rely on implicit connections.
- There is no `AVCaptureMultiCamSession.isMultiCamSupported` gate, no supported-format selection, no `hardwareCost` check, and no runtime interruption/error handling.
- Result: the implementation can compile and show one camera, but it is not using the iOS-supported simultaneous front/back capture graph.

# Proposed Architecture

## Native session model

- Replace `frontSession` and `backSession` with one `AVCaptureMultiCamSession *multiCamSession`.
- Keep `AVCaptureDeviceInput *frontDeviceInput` and `AVCaptureDeviceInput *backDeviceInput`.
- Create `frontPreviewLayer` and `backPreviewLayer` with `initWithSessionWithNoConnection:` or `setSessionWithNoConnection:`.
- Add front and back inputs with `addInputWithNoConnections:`.
- Manually find each input's video port and connect it to the corresponding preview layer using `AVCaptureConnection`.
- Set front preview connection mirroring through the connection (`videoMirrored`) when supported, rather than layer-level transform.
- Keep UI layout logic mostly as-is: `back`, `front`, `lr`, `sx`, `pip_square`, and `pip_circle` should only reframe/hide the two preview views and layers.

## Capability and fallback

- Before building a multi-cam graph, check `[AVCaptureMultiCamSession isMultiCamSupported]`.
- If unsupported:
  - `back` and `front` single-camera modes may fall back to a normal single `AVCaptureSession`.
  - dual modes must emit a native error event explaining that simultaneous dual camera is not supported on this device.
- Pick active formats with `isMultiCamSupported == YES`, preferring stable 30 fps and moderate resolution to keep `hardwareCost <= 1.0`.
- If a connection cannot be added, stop configuration and emit a native error event instead of silently marking `_isConfigured = YES`.

## Capture behavior

- Preserve existing JS commands: `startSession`, `stopSession`, `takePhoto`, `startRecording`, `stopRecording`.
- For this fix, `takePhoto` and `startRecording` should target a single "primary" camera stream:
  - `back`: back camera
  - `front`: front camera
  - dual layouts: back camera by default unless JS later adds an explicit primary-camera prop
- Add separate photo outputs for front/back only if needed to make primary-camera still capture reliable.
- Video recording should remain single-stream unless the user approves a separate compositing feature. A saved video matching PiP/split layout requires a different pipeline: two `AVCaptureVideoDataOutput` branches, composition, and `AVAssetWriter`.

## Runtime resilience

- Register for `AVCaptureSessionRuntimeErrorNotification`, `AVCaptureSessionWasInterruptedNotification`, and `AVCaptureSessionInterruptionEndedNotification`.
- Emit session errors through `DualCameraEventEmitter`, so JS can show a real message instead of only logging to Xcode.
- Ensure session start/stop and configuration happen on a serial session queue, not the global concurrent queue.
- Keep UI updates on the main queue.

# verification_plan

- Static local checks:
  - `cd my-app && node -e "JSON.parse(require('fs').readFileSync('app.json','utf8')); console.log('app.json ok')"`
  - `rg -n "AVCaptureSession \\*frontSession|AVCaptureSession \\*backSession" my-app/native/LocalPods/DualCamera/DualCameraView.m`
    - expected after implementation: no matches.
  - `rg -n "AVCaptureMultiCamSession|addInputWithNoConnections|initWithSessionWithNoConnection|connectionWithInputPort|hardwareCost|isMultiCamSupported" my-app/native/LocalPods/DualCamera/DualCameraView.m`
    - expected after implementation: matches for the new MultiCam graph.
  - `git diff --check`
- Build verification:
  - `cd my-app && eas build --platform ios --profile production --clear-cache`
  - If the goal is direct device sideload testing before App Store/TestFlight, use `preview` instead of `production`.
  - Confirm EAS logs compile `DualCamera` and do not contain Xcode errors from `DualCameraView.m`.
- Runtime verification on a real iOS device that supports MultiCam:
  - `back` mode shows live back preview.
  - `front` mode shows live front preview.
  - `pip_square` and `pip_circle` show live back + front simultaneously.
  - `lr` and `sx` show live back + front simultaneously.
  - Switching modes does not recreate the session unnecessarily and does not freeze either preview.
  - `takePhoto` succeeds in `back` and `front` modes.
  - `startRecording` / `stopRecording` either succeeds for the primary stream or emits a specific native error event.
- Runtime verification on a device that does not support MultiCam:
  - single-camera modes still work or fail with a specific native message.
  - dual modes fail gracefully with a visible unsupported-device message.

# exit_criteria

- The implementation no longer attempts to run front and back cameras through two independent `AVCaptureSession` instances.
- Supported iOS devices show simultaneous live front/back preview in all dual layout modes.
- Unsupported devices do not silently show only one camera; they emit a clear unsupported-device/session-error state.
- Native configuration failures are surfaced through events instead of only `NSLog`.
- EAS iOS build succeeds from `my-app`.
- The final behavior is documented enough that composited dual recording is not confused with the live dual-preview fix.

# split_tasks

- Task 1: Rewrite native capture graph.
  - write_set: `DualCameraView.h`, `DualCameraView.m`
  - output: one `AVCaptureMultiCamSession`, explicit front/back preview connections, capability checks, serial session queue.
- Task 2: Surface native session errors.
  - write_set: `DualCameraEventEmitter.h`, `DualCameraEventEmitter.m`, `App.js`
  - output: JS receives and displays unsupported-device/session-runtime errors.
- Task 3: Preserve bridge command behavior.
  - write_set: `DualCameraModule.h`, `DualCameraModule.m`, `DualCameraSessionManager.h`, `DualCameraSessionManager.m`
  - output: existing JS commands still call into the registered native view safely.
- Task 4: Validate build/runtime.
  - write_set: none
  - output: EAS build result and device-mode test matrix.

# open_questions

- What iPhone/iPad model is the failing device? MultiCam support is hardware-gated.
- Should photo/video capture in dual layouts save only the primary stream, or should it save a composited image/video matching the on-screen PiP/split layout?
- Should the UI expose a primary-camera selector for dual layouts, or should back camera remain the default primary stream?
