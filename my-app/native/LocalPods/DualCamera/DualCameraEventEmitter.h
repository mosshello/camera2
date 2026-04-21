#import <React/RCTEventEmitter.h>

@interface DualCameraEventEmitter : RCTEventEmitter <RCTBridgeModule>

+ (instancetype)shared;

- (void)sendPhotoSaved:(NSString *)uri;
- (void)sendPhotoError:(NSString *)error;
- (void)sendRecordingFinished:(NSString *)uri;
- (void)sendRecordingError:(NSString *)error;

@end
