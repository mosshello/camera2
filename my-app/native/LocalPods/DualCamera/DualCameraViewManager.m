#import "DualCameraViewManager.h"
#import "DualCameraView.h"

@implementation DualCameraViewManager

RCT_EXPORT_MODULE()

- (UIView *)view {
  return [[DualCameraView alloc] init];
}

RCT_CUSTOM_VIEW_PROPERTY(layoutMode, NSString, DualCameraView) {
  view.layoutMode = json ? [RCTConvert NSString:json] : @"back";
}

@end
