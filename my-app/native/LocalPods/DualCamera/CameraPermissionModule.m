#import "CameraPermissionModule.h"
#import <AVFoundation/AVFoundation.h>

@implementation CameraPermissionModule

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return NO; }

RCT_EXPORT_METHOD(getCameraAuthorizationStatus:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  switch (status) {
    case AVAuthorizationStatusAuthorized:     resolve(@"authorized");     break;
    case AVAuthorizationStatusDenied:           resolve(@"denied");           break;
    case AVAuthorizationStatusRestricted:      resolve(@"restricted");       break;
    case AVAuthorizationStatusNotDetermined:    resolve(@"not_determined");  break;
    default:                                    resolve(@"unknown");          break;
  }
}

RCT_EXPORT_METHOD(requestCameraPermission:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
    resolve(@(granted));
  }];
}

@end
