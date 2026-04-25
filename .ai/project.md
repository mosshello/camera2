status: draft
last-verified: 2026-04-25

# Project Context

## Stack Summary

- Root repository contains an Expo/React Native app scaffold.
- `my-app/` contains the active camera app opened in the IDE.
- `my-app/package.json` uses Expo SDK `~54.0.33`, React Native `0.81.5`, `expo-camera`, and `expo-media-library`.
- `my-app/app.json` disables the React Native new architecture and declares the custom iOS config plugin `./plugin/withDualCamera`.

## Key Modules

- `my-app/App.js`: React Native UI and runtime checks for `NativeModules.CameraPermissionModule`, `NativeModules.DualCameraModule`, `NativeModules.DualCameraEventEmitter`, and `requireNativeComponent('DualCameraView')`.
- `my-app/plugin/withDualCamera.js`: Expo config plugin that copies `native/LocalPods/DualCamera` into `ios/LocalPods/DualCamera` during iOS prebuild and patches the generated Podfile with a local `DualCamera` pod.
- `my-app/native/LocalPods/DualCamera/`: Objective-C native iOS camera module, view manager, event emitter, permission module, and podspec.
- `my-app/eas.json`: EAS build profiles for development, preview, and production.

## ADRs

- Custom iOS camera behavior is implemented as a local CocoaPods pod instead of relying solely on `expo-camera`.
- The app depends on Expo prebuild/config-plugin execution for iOS native module inclusion.
- React Native new architecture is disabled in `my-app/app.json`, which aligns with the current Objective-C bridge modules using `RCT_EXPORT_MODULE`.
- `my-app/plugin/withDualCamera.js` intentionally fails prebuild when native sources or the generated Podfile are missing, so EAS does not produce an iOS binary without the required native camera module.

## External Contracts

- iOS builds must run from `my-app/` or otherwise use `my-app/app.json`, `my-app/plugin/withDualCamera.js`, and `my-app/native/LocalPods/DualCamera`.
- Generated iOS projects must include a `pod 'DualCamera', :path => './LocalPods/DualCamera'` entry inside the app target in `ios/Podfile`.
- Runtime JS expects native module names exported by Objective-C: `CameraPermissionModule`, `DualCameraModule`, `DualCameraEventEmitter`, and `DualCameraView`.

## Change Notes

- 2026-04-25: Hardened `my-app/plugin/withDualCamera.js` to copy the local DualCamera pod recursively, patch the app target deterministically after `use_expo_modules!`, avoid duplicate pod entries, and fail early on missing native sources or Podfile. Local Windows verification cannot generate the iOS native project; use macOS/Linux or EAS for final iOS prebuild/build validation.
