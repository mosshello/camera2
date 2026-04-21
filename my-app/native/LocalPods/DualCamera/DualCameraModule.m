#import "DualCameraModule.h"
#import "DualCameraSessionManager.h"

@implementation DualCameraModule

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_METHOD(startSession) {
  [[DualCameraSessionManager shared] startSession];
}

RCT_EXPORT_METHOD(stopSession) {
  [[DualCameraSessionManager shared] stopSession];
}

RCT_EXPORT_METHOD(takePhoto) {
  [[DualCameraSessionManager shared] takePhoto];
}

RCT_EXPORT_METHOD(startRecording) {
  [[DualCameraSessionManager shared] startRecording];
}

RCT_EXPORT_METHOD(stopRecording) {
  [[DualCameraSessionManager shared] stopRecording];
}

@end
