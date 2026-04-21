#import "DualCameraEventEmitter.h"

@implementation DualCameraEventEmitter {
  BOOL _hasListeners;
}

RCT_EXPORT_MODULE()

+ (instancetype)shared {
  static DualCameraEventEmitter *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[DualCameraEventEmitter alloc] init];
  });
  return instance;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onPhotoSaved", @"onPhotoError", @"onRecordingFinished", @"onRecordingError"];
}

- (void)startObserving { _hasListeners = YES; }
- (void)stopObserving  { _hasListeners = NO; }

+ (BOOL)requiresMainQueueSetup { return YES; }

- (void)sendPhotoSaved:(NSString *)uri {
  if (_hasListeners) [self sendEventWithName:@"onPhotoSaved" body:@{@"uri": uri}];
}

- (void)sendPhotoError:(NSString *)error {
  if (_hasListeners) [self sendEventWithName:@"onPhotoError" body:@{@"error": error}];
}

- (void)sendRecordingFinished:(NSString *)uri {
  if (_hasListeners) [self sendEventWithName:@"onRecordingFinished" body:@{@"uri": uri}];
}

- (void)sendRecordingError:(NSString *)error {
  if (_hasListeners) [self sendEventWithName:@"onRecordingError" body:@{@"error": error}];
}

@end
