#import "DualCameraSessionManager.h"
#import "DualCameraView.h"
#import "DualCameraEventEmitter.h"

@implementation DualCameraSessionManager {
  DualCameraView *_registeredView;
}

+ (instancetype)shared {
  static DualCameraSessionManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[DualCameraSessionManager alloc] init];
  });
  return instance;
}

- (void)registerView:(DualCameraView *)view {
  _registeredView = view;
}

- (void)startSession    { [_registeredView dc_startSession]; }
- (void)stopSession     { [_registeredView dc_stopSession]; }
- (void)takePhoto       { [_registeredView dc_takePhoto]; }
- (void)startRecording  { [_registeredView dc_startRecording]; }
- (void)stopRecording   { [_registeredView dc_stopRecording]; }

@end
