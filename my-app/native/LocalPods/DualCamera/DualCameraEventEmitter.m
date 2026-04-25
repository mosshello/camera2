#import "DualCameraEventEmitter.h"

static DualCameraEventEmitter *sharedEmitter = nil;

@implementation DualCameraEventEmitter {
  BOOL _hasListeners;
}

RCT_EXPORT_MODULE()

- (instancetype)init {
  self = [super init];
  if (self) {
    sharedEmitter = self;
  }
  return self;
}

+ (instancetype)shared {
  return sharedEmitter;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onPhotoSaved", @"onPhotoError", @"onRecordingFinished", @"onRecordingError", @"onSessionError"];
}

- (void)startObserving { _hasListeners = YES; }
- (void)stopObserving  { _hasListeners = NO; }

+ (BOOL)requiresMainQueueSetup { return YES; }

- (void)sendPhotoSaved:(NSString *)uri {
  [self sendEventIfNeeded:@"onPhotoSaved" body:@{@"uri": uri ?: @""}];
}

- (void)sendPhotoError:(NSString *)error {
  [self sendEventIfNeeded:@"onPhotoError" body:@{@"error": error ?: @"Photo error"}];
}

- (void)sendRecordingFinished:(NSString *)uri {
  [self sendEventIfNeeded:@"onRecordingFinished" body:@{@"uri": uri ?: @""}];
}

- (void)sendRecordingError:(NSString *)error {
  [self sendEventIfNeeded:@"onRecordingError" body:@{@"error": error ?: @"Recording error"}];
}

- (void)sendSessionError:(NSString *)error code:(NSString *)code {
  [self sendEventIfNeeded:@"onSessionError" body:@{@"error": error ?: @"Camera session error", @"code": code ?: @"session_error"}];
}

- (void)sendEventIfNeeded:(NSString *)name body:(NSDictionary *)body {
  if (!_hasListeners) return;

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_hasListeners) {
      [self sendEventWithName:name body:body];
    }
  });
}

@end
