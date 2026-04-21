#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

@class DualCameraEventEmitter;

NS_ASSUME_NONNULL_BEGIN

@interface DualCameraView : UIView

@property (nonatomic, copy) NSString *layoutMode;

- (void)dc_startSession;
- (void)dc_stopSession;
- (void)dc_takePhoto;
- (void)dc_startRecording;
- (void)dc_stopRecording;

@end

NS_ASSUME_NONNULL_END
