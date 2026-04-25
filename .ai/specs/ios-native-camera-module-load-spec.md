spec_id: ios-native-camera-module-load-20260425
goal: Diagnose and fix the iOS runtime state where the app shows "原生模块未加载，请重新构建" because the custom camera native modules are absent from `NativeModules`.
intent: Ensure the installed iOS binary contains and registers the local DualCamera Objective-C pod expected by `my-app/App.js`.
status: draft

# Scope

## target_files

- `my-app/app.json`
- `my-app/eas.json`
- `my-app/plugin/withDualCamera.js`
- `my-app/native/LocalPods/DualCamera/DualCamera.podspec`
- `my-app/native/LocalPods/DualCamera/*.h`
- `my-app/native/LocalPods/DualCamera/*.m`
- `my-app/App.js` only for temporary diagnostics or fallback messaging if needed

## out_of_scope

- Rewriting the camera UI.
- Replacing the custom iOS camera module with `expo-camera`.
- Android camera behavior.
- Publishing OTA updates before a verified native iOS rebuild.
- Committing generated `ios/` output unless the user explicitly chooses a bare/prebuild workflow.

# Current Evidence

- `my-app/App.js` renders the reported error when `NativeModules.CameraPermissionModule` is missing.
- `CameraPermissionModule`, `DualCameraModule`, `DualCameraEventEmitter`, and `DualCameraView` are custom Objective-C modules, not modules supplied by `expo-camera`.
- `my-app` has no committed `ios/` directory, so iOS native inclusion depends on Expo prebuild/config-plugin execution.
- `my-app/app.json` includes `./plugin/withDualCamera` and has `newArchEnabled: false`, which is compatible with the current bridge-style `RCT_EXPORT_MODULE` Objective-C code.
- The repository root also contains a separate Expo app config that does not include the custom plugin or native local pod.

# Likely Root Causes To Test

1. The iOS build was produced from the repository root instead of `my-app/`.
2. The app was opened in Expo Go or an older development client/binary that was built before the native module existed.
3. EAS/prebuild did not run `my-app/plugin/withDualCamera.js`, so `ios/LocalPods/DualCamera` and the `pod 'DualCamera'` Podfile entry were not generated.
4. The Podfile patch landed outside the app target or CocoaPods did not install the local pod.
5. Less likely: the pod compiles but the Objective-C bridge classes are stripped or not registered at runtime.

# Verification Plan

- `cd my-app && npm ci`
  - status: completed locally
  - result: dependencies installed; npm reported 12 audit findings unrelated to this native-module load issue.
- `cd my-app && node -e "JSON.parse(require('fs').readFileSync('app.json','utf8')); console.log('app.json ok')"`
  - status: completed locally
  - result: `app.json ok`
- `cd my-app && npx expo prebuild --platform ios --clean --no-install`
  - status: pending
  - purpose: verify that the config plugin copies `native/LocalPods/DualCamera` and patches `ios/Podfile`.
  - note: generated `ios/` should remain uncommitted unless explicitly approved.
- Inspect generated files:
  - `ios/LocalPods/DualCamera/CameraPermissionModule.m` exists.
  - `ios/Podfile` contains `pod 'DualCamera', :path => './LocalPods/DualCamera'` inside the application target.
- EAS build verification:
  - run from `my-app/`, not the repository root.
  - use a native rebuild, for example `eas build -p ios --profile preview --clear-cache`.
  - confirm build logs show the local `DualCamera` pod during CocoaPods install.
- Runtime verification:
  - install the newly produced `.ipa`.
  - confirm the unavailable screen no longer appears.
  - confirm camera permission prompt/status and camera preview load on a real iOS device.

# exit_criteria

- The iOS binary exposes `NativeModules.CameraPermissionModule`.
- The iOS binary exposes `NativeModules.DualCameraModule`.
- `requireNativeComponent('DualCameraView')` resolves without throwing.
- Camera permission flow reaches `authorized`, `not_determined`, or `denied` based on actual iOS permission state, not `unavailable`.
- The build process is documented enough that future native JS changes are followed by a native rebuild, not only an OTA/Metro update.

# split_tasks

- Task 1: Confirm the exact build entrypoint and artifact source.
  - write_set: none
  - output: whether the installed build came from `my-app`, root app, Expo Go, development client, preview, or production.
- Task 2: Verify config-plugin prebuild output.
  - write_set: generated `my-app/ios/` only if explicitly approved
  - output: Podfile and local pod presence.
- Task 3: Harden native integration if prebuild output is wrong.
  - write_set: `my-app/plugin/withDualCamera.js`, possibly `my-app/native/LocalPods/DualCamera/DualCamera.podspec`
  - output: deterministic Podfile modification and pod installation.
- Task 4: Rebuild and device-test iOS.
  - write_set: none
  - output: EAS build log evidence and runtime result.

# open_questions

- Was the iOS package built from `f:\coding\camera2` or `f:\coding\camera2\my-app`?
- Was the screenshot from Expo Go, an EAS development client, an EAS preview build, or a production/TestFlight build?
- Was this JS installed through an OTA update or Metro after the native module was added?
- Do the EAS build logs contain `DualCamera` during the CocoaPods install step?
