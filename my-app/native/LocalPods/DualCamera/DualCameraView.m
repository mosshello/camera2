#import "DualCameraView.h"
#import "DualCameraEventEmitter.h"
#import "DualCameraSessionManager.h"

@interface DualCameraView () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>

@property (nonatomic, strong) AVCaptureSession *frontSession;
@property (nonatomic, strong) AVCaptureSession *backSession;
@property (nonatomic, strong) AVCaptureDeviceInput *frontDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *backDeviceInput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *frontPreviewLayer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *backPreviewLayer;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *movieOutput;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, assign) BOOL isConfigured;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, copy) NSString *currentLayout;

@end

@implementation DualCameraView

#pragma mark - Init

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = [UIColor blackColor];
    self.clipsToBounds = YES;
    _currentLayout = @"back";
    _layoutMode = @"back";
    _isConfigured = NO;
    _isRunning = NO;
    [self createPlaceholderViews];
    [[DualCameraSessionManager shared] registerView:self];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    self.backgroundColor = [UIColor blackColor];
    self.clipsToBounds = YES;
    _currentLayout = @"back";
    _layoutMode = @"back";
    _isConfigured = NO;
    _isRunning = NO;
    [self createPlaceholderViews];
    [[DualCameraSessionManager shared] registerView:self];
  }
  return self;
}

#pragma mark - Properties

- (void)setLayoutMode:(NSString *)layoutMode {
  _layoutMode = layoutMode;
  _currentLayout = layoutMode;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

#pragma mark - Placeholder Views

- (void)createPlaceholderViews {
  [_frontPreviewView removeFromSuperview];
  [_backPreviewView removeFromSuperview];

  UIView *bv = [[UIView alloc] init];
  bv.backgroundColor = [UIColor blackColor];
  bv.clipsToBounds = YES;
  bv.frame = self.bounds;
  [self addSubview:bv];
  _backPreviewView = bv;

  UIView *fv = [[UIView alloc] init];
  fv.backgroundColor = [UIColor blackColor];
  fv.clipsToBounds = YES;
  fv.frame = self.bounds;
  [self addSubview:fv];
  _frontPreviewView = fv;

  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

#pragma mark - Layout

- (void)layoutSubviews {
  [super layoutSubviews];
  [self updateLayout];
}

- (void)updateLayout {
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;

  if ([_currentLayout isEqualToString:@"back"]) {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;

  } else if ([_currentLayout isEqualToString:@"front"]) {
    _backPreviewView.hidden = YES;
    _frontPreviewView.hidden = NO;
    _frontPreviewView.frame = self.bounds;

  } else if ([_currentLayout isEqualToString:@"lr"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _backPreviewView.frame = CGRectMake(0, 0, w / 2, h);
    _frontPreviewView.frame = CGRectMake(w / 2, 0, w / 2, h);

  } else if ([_currentLayout isEqualToString:@"sx"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _frontPreviewView.frame = CGRectMake(0, 0, w, h / 2);
    _backPreviewView.frame = CGRectMake(0, h / 2, w, h / 2);

  } else if ([_currentLayout isEqualToString:@"pip_square"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
    CGFloat s = MIN(w, h) * 0.28;
    _frontPreviewView.frame = CGRectMake(w - s - 16, h - s - 160, s, s);
    _frontPreviewView.layer.cornerRadius = 12;
    _frontPreviewView.layer.masksToBounds = YES;

  } else if ([_currentLayout isEqualToString:@"pip_circle"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
    CGFloat s = 110;
    _frontPreviewView.frame = CGRectMake(w - s - 16, h - s - 160, s, s);
    _frontPreviewView.layer.cornerRadius = s / 2;
    _frontPreviewView.layer.masksToBounds = YES;

  } else {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
  }

  _frontPreviewLayer.frame = _frontPreviewView.bounds;
  _backPreviewLayer.frame = _backPreviewView.bounds;
}

#pragma mark - ObjC Bridge Methods

- (void)dc_startSession { [self internalStartSession]; }
- (void)dc_stopSession  { [self internalStopSession]; }
- (void)dc_takePhoto    { [self internalTakePhoto]; }
- (void)dc_startRecording { [self internalStartRecording]; }
- (void)dc_stopRecording  { [_movieOutput stopRecording]; }

#pragma mark - Session Lifecycle

- (void)internalStartSession {
  if (_isConfigured) {
    [self resumeIfNeeded];
    return;
  }

  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      if (granted) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [self configureAndStart];
        });
      }
    }];
  } else if (status == AVAuthorizationStatusAuthorized) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [self configureAndStart];
    });
  }
}

- (void)configureAndStart {
  AVCaptureSession *back = [[AVCaptureSession alloc] init];
  back.sessionPreset = AVCaptureSessionPresetHigh;
  self.backSession = back;

  AVCaptureSession *front = [[AVCaptureSession alloc] init];
  front.sessionPreset = AVCaptureSessionPresetHigh;
  self.frontSession = front;

  AVCaptureDevice *frontDev = nil;
  AVCaptureDevice *backDev = nil;

  AVCaptureDeviceDiscoverySession *disc = [AVCaptureDeviceDiscoverySession
    discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
    mediaType:AVMediaTypeVideo
    position:AVCaptureDevicePositionUnspecified];

  for (AVCaptureDevice *dev in disc.devices) {
    if (dev.position == AVCaptureDevicePositionFront) frontDev = dev;
    if (dev.position == AVCaptureDevicePositionBack)  backDev  = dev;
  }

  if (!frontDev || !backDev) {
    NSLog(@"[DualCamera] Cameras not found");
    return;
  }

  NSError *err = nil;

  AVCaptureDeviceInput *bi = [AVCaptureDeviceInput deviceInputWithDevice:backDev error:&err];
  if (!err && [back canAddInput:bi]) {
    [back addInput:bi];
    self.backDeviceInput = bi;
  } else if (err) {
    NSLog(@"[DualCamera] Back input error: %@", err);
  }

  AVCapturePhotoOutput *photo = [[AVCapturePhotoOutput alloc] init];
  if ([back canAddOutput:photo]) {
    [back addOutput:photo];
    self.photoOutput = photo;
  }

  AVCaptureMovieFileOutput *movie = [[AVCaptureMovieFileOutput alloc] init];
  if ([back canAddOutput:movie]) {
    [back addOutput:movie];
    self.movieOutput = movie;
  }

  AVCaptureDeviceInput *fi = [AVCaptureDeviceInput deviceInputWithDevice:frontDev error:&err];
  if (!err && [front canAddInput:fi]) {
    [front addInput:fi];
    self.frontDeviceInput = fi;
  } else if (err) {
    NSLog(@"[DualCamera] Front input error: %@", err);
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self.frontPreviewLayer removeFromSuperlayer];
    [self.backPreviewLayer removeFromSuperlayer];

    AVCaptureVideoPreviewLayer *bl = [AVCaptureVideoPreviewLayer layerWithSession:back];
    bl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    bl.frame = self.backPreviewView.bounds;
    [self.backPreviewView.layer addSublayer:bl];
    self.backPreviewLayer = bl;

    AVCaptureVideoPreviewLayer *fl = [AVCaptureVideoPreviewLayer layerWithSession:front];
    fl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    fl.frame = self.frontPreviewView.bounds;
    fl.transform = CGAffineTransformMakeScale(-1, 1);
    [self.frontPreviewView.layer addSublayer:fl];
    self.frontPreviewLayer = fl;

    [self updateLayout];
  });

  [front startRunning];
  [back startRunning];

  self.isConfigured = YES;
  self.isRunning = YES;
}

- (void)resumeIfNeeded {
  if (!_isConfigured || _isRunning) return;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self.frontSession startRunning];
    [self.backSession startRunning];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.isRunning = YES;
    });
  });
}

- (void)internalStopSession {
  if (!_isConfigured || !_isRunning) return;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self.frontSession stopRunning];
    [self.backSession stopRunning];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.isRunning = NO;
    });
  });
}

#pragma mark - Capture

- (void)internalTakePhoto {
  if (!_photoOutput) {
    [self emitError:@"Photo output not available"];
    return;
  }
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
  settings.flashMode = AVCaptureFlashModeOff;
  [_photoOutput capturePhotoWithSettings:settings delegate:self];
}

- (void)internalStartRecording {
  if (!_movieOutput) {
    [self emitRecordingError:@"Movie output not available"];
    return;
  }
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_%ld.mov", (long)[[NSDate date] timeIntervalSince1970]]];
  [_movieOutput startRecordingToOutputFileURL:[NSURL fileURLWithPath:path] recordingDelegate:self];
}

#pragma mark - Event Emission

- (void)emitPhotoSaved:(NSString *)uri {
  [[DualCameraEventEmitter shared] sendPhotoSaved:uri];
}

- (void)emitError:(NSString *)error {
  [[DualCameraEventEmitter shared] sendPhotoError:error];
}

- (void)emitRecordingFinished:(NSString *)uri {
  [[DualCameraEventEmitter shared] sendRecordingFinished:uri];
}

- (void)emitRecordingError:(NSString *)error {
  [[DualCameraEventEmitter shared] sendRecordingError:error];
}

#pragma mark - AVCapturePhotoCaptureDelegate

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {

  if (error) {
    [self emitError:error.localizedDescription];
    return;
  }

  NSData *data = [photo fileDataRepresentation];
  if (!data) {
    [self emitError:@"Failed to get photo data"];
    return;
  }

  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
  NSError *writeErr = nil;
  [data writeToFile:path options:NSDataWritingAtomic error:&writeErr];
  if (writeErr) {
    [self emitError:writeErr.localizedDescription];
  } else {
    [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
  }
}

#pragma mark - AVCaptureFileOutputRecordingDelegate

- (void)captureOutput:(AVCaptureFileOutput *)output
    didFinishRecordingToOutputFileAtURL:(NSURL *)fileURL
    fromConnections:(NSArray<AVCaptureConnection *> *)connections
               error:(NSError *)error {
  if (error) {
    [self emitRecordingError:error.localizedDescription];
  } else {
    [self emitRecordingFinished:fileURL.absoluteString];
  }
}

- (void)dealloc {
  [_frontSession stopRunning];
  [_backSession stopRunning];
}

@end
