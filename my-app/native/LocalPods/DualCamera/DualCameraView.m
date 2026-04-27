#import "DualCameraView.h"
#import "DualCameraEventEmitter.h"
#import "DualCameraSessionManager.h"
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface DualCameraView () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureSession *singleSession;
@property (nonatomic, strong) AVCaptureDeviceInput *frontDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *backDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *singleDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *frontPreviewLayer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *backPreviewLayer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *singlePreviewLayer;
@property (nonatomic, strong) AVCapturePhotoOutput *frontPhotoOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *backPhotoOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *singlePhotoOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *backMovieOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *frontMovieOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *singleMovieOutput;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) AVCaptureDevicePosition singleCameraPosition;
@property (nonatomic, assign) BOOL usingMultiCam;
@property (nonatomic, assign) BOOL isConfigured;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, copy) NSString *currentLayout;

// Dual compositing state
@property (nonatomic, strong) NSMutableDictionary *pendingDualPhotos;
@property (nonatomic, assign) BOOL pendingDualPhotosFront;
@property (nonatomic, assign) BOOL pendingDualPhotosBack;
@property (nonatomic, strong) NSString *backRecordingPath;
@property (nonatomic, strong) NSString *frontRecordingPath;
@property (nonatomic, assign) BOOL backRecordingFinished;
@property (nonatomic, assign) BOOL frontRecordingFinished;
@property (nonatomic, assign) BOOL isDualRecordingActive; // prevents layout change during dual recording
@property (nonatomic, strong) AVAssetExportSession *videoExportSession; // keep alive until export completes
@property (nonatomic, strong) dispatch_queue_t compositingQueue;

// canvasSizeAtRecording — only declared here (not in .h), used internally
@property (nonatomic, assign) CGSize canvasSizeAtRecording;

@end

@implementation DualCameraView

#pragma mark - Init

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    [self commonInit];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    [self commonInit];
  }
  return self;
}

- (void)commonInit {
  self.backgroundColor = [UIColor blackColor];
  self.clipsToBounds = YES;
  _currentLayout = @"back";
  _layoutMode = @"back";
  _singleCameraPosition = AVCaptureDevicePositionBack;
  _sessionQueue = dispatch_queue_create("com.zhengning.dualcamera.session", DISPATCH_QUEUE_SERIAL);
  _isConfigured = NO;
  _isRunning = NO;
  _usingMultiCam = NO;
  _pendingDualPhotos = [NSMutableDictionary dictionary];
  _compositingQueue = dispatch_queue_create("com.zhengning.dualcamera.compositing", DISPATCH_QUEUE_SERIAL);
  // Default values for layout/PiP/zoom properties (declared in .h for React Native)
  _dualLayoutRatio = 0.5;
  _pipSize = 0.28;
  _pipPositionX = 0.85;
  _pipPositionY = 0.80;
  _frontZoomFactor = 1.0;
  _backZoomFactor = 1.0;
  _canvasSizeAtRecording = CGSizeZero;
  [self createPlaceholderViews];
  [[DualCameraSessionManager shared] registerView:self];
}

#pragma mark - Properties

- (void)setLayoutMode:(NSString *)layoutMode {
  NSString *nextLayout = layoutMode ?: @"back";
  _layoutMode = nextLayout;
  _currentLayout = nextLayout;

  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });

  dispatch_async(self.sessionQueue, ^{
    if (self.isConfigured && !self.usingMultiCam) {
      if ([self isDualLayout:nextLayout]) {
        [self emitSessionError:@"This device does not support simultaneous front and back camera preview." code:@"multicam_unsupported"];
      } else {
        [self reconfigureSingleSessionForCurrentLayout];
      }
    }
  });
}

- (void)setDualLayoutRatio:(CGFloat)ratio {
  _dualLayoutRatio = MAX(0.1, MIN(0.9, ratio));
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

- (void)setPipSize:(CGFloat)size {
  _pipSize = MAX(0.05, MIN(0.5, size));
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

- (void)setPipPositionX:(CGFloat)px {
  _pipPositionX = MAX(0, MIN(1, px));
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

- (void)setPipPositionY:(CGFloat)py {
  _pipPositionY = MAX(0, MIN(1, py));
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

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
  CGFloat ratio = self.dualLayoutRatio > 0 ? self.dualLayoutRatio : 0.5;

  _frontPreviewView.layer.masksToBounds = YES;
  _backPreviewView.layer.masksToBounds = YES;

  if ([_currentLayout isEqualToString:@"back"]) {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;

  } else if ([_currentLayout isEqualToString:@"front"]) {
    _backPreviewView.hidden = YES;
    _frontPreviewView.hidden = NO;
    _frontPreviewView.frame = self.bounds;

  } else if ([_currentLayout isEqualToString:@"lr"]) {
    // LR: portrait canvas, split left/right vertically
    // back on left (ratio), front on right (1-ratio)
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    CGFloat leftW  = w * ratio;
    CGFloat rightW = w * (1 - ratio);
    _backPreviewView.frame  = CGRectMake(0, 0, leftW, h);
    _frontPreviewView.frame = CGRectMake(leftW, 0, rightW, h);

  } else if ([_currentLayout isEqualToString:@"sx"]) {
    // SX: portrait canvas, split top/bottom horizontally
    // front on top (1-ratio), back on bottom (ratio)
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    CGFloat topH    = h * (1 - ratio);
    CGFloat bottomH = h * ratio;
    _frontPreviewView.frame = CGRectMake(0, 0, w, topH);
    _backPreviewView.frame  = CGRectMake(0, topH, w, bottomH);

  } else if ([_currentLayout isEqualToString:@"pip_square"] || [_currentLayout isEqualToString:@"pip_circle"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;

    // PiP: size relative to canvas width, position as normalized center
    CGFloat s = w * self.pipSize;
    CGFloat cx = w * self.pipPositionX;
    CGFloat cy = h * self.pipPositionY;
    // Clamp so pip stays within canvas
    cx = MAX(s / 2, MIN(w - s / 2, cx));
    cy = MAX(s / 2, MIN(h - s / 2, cy));
    _frontPreviewView.frame = CGRectMake(cx - s / 2, cy - s / 2, s, s);

    if ([_currentLayout isEqualToString:@"pip_circle"]) {
      _frontPreviewView.layer.cornerRadius = s / 2;
    } else {
      _frontPreviewView.layer.cornerRadius = 8;
    }

  } else {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
  }

  // Update preview layer frames to match view frames (nil-safe: layers may not exist yet on first layout)
  if (_frontPreviewLayer) _frontPreviewLayer.frame = _frontPreviewView.bounds;
  if (_backPreviewLayer) _backPreviewLayer.frame = _backPreviewView.bounds;
  if (_singlePreviewLayer) _singlePreviewLayer.frame = [self targetPreviewViewForPosition:self.singleCameraPosition].bounds;
}

#pragma mark - ObjC Bridge Methods

- (void)dc_startSession { [self internalStartSession]; }
- (void)dc_stopSession  { [self internalStopSession]; }
- (void)dc_takePhoto    { [self internalTakePhoto]; }
- (void)dc_startRecording { [self internalStartRecording]; }
- (void)dc_stopRecording  { [self internalStopRecording]; }

#pragma mark - Session Lifecycle

- (void)internalStartSession {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      if (granted) {
        [self startOnSessionQueue];
      } else {
        [self emitSessionError:@"Camera permission was not granted." code:@"camera_permission_denied"];
      }
    }];
  } else if (status == AVAuthorizationStatusAuthorized) {
    [self startOnSessionQueue];
  } else {
    [self emitSessionError:@"Camera permission is denied or restricted." code:@"camera_permission_denied"];
  }
}

- (void)startOnSessionQueue {
  dispatch_async(self.sessionQueue, ^{
    if (self.isConfigured) {
      [self resumeIfNeeded];
      return;
    }

    if ([AVCaptureMultiCamSession isMultiCamSupported]) {
      [self configureAndStartMultiCamSession];
    } else {
      [self configureAndStartSingleCameraFallback];
    }
  });
}

- (void)configureAndStartMultiCamSession {
  AVCaptureDevice *backDevice = [self cameraDeviceForPosition:AVCaptureDevicePositionBack];
  AVCaptureDevice *frontDevice = [self cameraDeviceForPosition:AVCaptureDevicePositionFront];
  if (!backDevice || !frontDevice) {
    [self emitSessionError:@"Could not find both front and back cameras." code:@"camera_not_found"];
    return;
  }

  NSError *error = nil;
  if (![self configureDeviceForMultiCam:backDevice error:&error]) {
    [self emitSessionError:[NSString stringWithFormat:@"Back camera configuration failed: %@", error.localizedDescription] code:@"back_format_failed"];
    return;
  }
  if (![self configureDeviceForMultiCam:frontDevice error:&error]) {
    [self emitSessionError:[NSString stringWithFormat:@"Front camera configuration failed: %@", error.localizedDescription] code:@"front_format_failed"];
    return;
  }

  self.multiCamSession = [[AVCaptureMultiCamSession alloc] init];
  dispatch_sync(dispatch_get_main_queue(), ^{
    [self removePreviewLayers];

    AVCaptureVideoPreviewLayer *bl = [[AVCaptureVideoPreviewLayer alloc] initWithSessionWithNoConnection:self.multiCamSession];
    bl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    bl.frame = self.backPreviewView.bounds;
    [self.backPreviewView.layer addSublayer:bl];
    self.backPreviewLayer = bl;

    AVCaptureVideoPreviewLayer *fl = [[AVCaptureVideoPreviewLayer alloc] initWithSessionWithNoConnection:self.multiCamSession];
    fl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    fl.frame = self.frontPreviewView.bounds;
    [self.frontPreviewView.layer addSublayer:fl];
    self.frontPreviewLayer = fl;

    [self updateLayout];
  });

  AVCaptureDeviceInput *backInput = [AVCaptureDeviceInput deviceInputWithDevice:backDevice error:&error];
  if (!backInput) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:[NSString stringWithFormat:@"Back camera input failed: %@", error.localizedDescription] code:@"back_input_failed"];
    return;
  }

  AVCaptureDeviceInput *frontInput = [AVCaptureDeviceInput deviceInputWithDevice:frontDevice error:&error];
  if (!frontInput) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:[NSString stringWithFormat:@"Front camera input failed: %@", error.localizedDescription] code:@"front_input_failed"];
    return;
  }

  AVCapturePhotoOutput *backPhotoOutput = [[AVCapturePhotoOutput alloc] init];
  AVCapturePhotoOutput *frontPhotoOutput = [[AVCapturePhotoOutput alloc] init];
  AVCaptureMovieFileOutput *backMovieOutput = [[AVCaptureMovieFileOutput alloc] init];

  BOOL ok = YES;
  NSString *failure = nil;
  NSString *failureCode = nil;

  [self.multiCamSession beginConfiguration];

  // Audio input (microphone)
  AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  if (audioDevice) {
    NSError *audioErr = nil;
    self.audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioErr];
    if (self.audioInput && [self.multiCamSession canAddInput:self.audioInput]) {
      [self.multiCamSession addInputWithNoConnections:self.audioInput];
    } else {
      NSLog(@"[DualCamera] Audio input not available: %@", audioErr.localizedDescription);
      self.audioInput = nil;
    }
  }

  if ([self.multiCamSession canAddInput:backInput]) {
    [self.multiCamSession addInputWithNoConnections:backInput];
  } else {
    ok = NO;
    failure = @"Cannot add back camera input to multi-cam session.";
    failureCode = @"back_input_rejected";
  }

  if (ok && [self.multiCamSession canAddInput:frontInput]) {
    [self.multiCamSession addInputWithNoConnections:frontInput];
  } else if (ok) {
    ok = NO;
    failure = @"Cannot add front camera input to multi-cam session.";
    failureCode = @"front_input_rejected";
  }

  AVCaptureInputPort *backVideoPort = ok ? [self videoPortForInput:backInput] : nil;
  AVCaptureInputPort *frontVideoPort = ok ? [self videoPortForInput:frontInput] : nil;
  if (ok && (!backVideoPort || !frontVideoPort)) {
    ok = NO;
    failure = @"Could not find front/back video input ports.";
    failureCode = @"video_port_missing";
  }

  if (ok) {
    ok = [self addPreviewLayer:self.backPreviewLayer
                      forPort:backVideoPort
                    toSession:self.multiCamSession
                  mirrorVideo:NO
                      failure:&failure
                  failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addPreviewLayer:self.frontPreviewLayer
                      forPort:frontVideoPort
                    toSession:self.multiCamSession
                  mirrorVideo:YES
                      failure:&failure
                  failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addOutput:backPhotoOutput
                 forPort:backVideoPort
               toSession:self.multiCamSession
                 failure:&failure
             failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addOutput:frontPhotoOutput
                 forPort:frontVideoPort
               toSession:self.multiCamSession
                 failure:&failure
             failureCode:&failureCode];
  }

  if (ok) {
    NSString *movieFailure = nil;
    NSString *movieFailureCode = nil;
    if (![self addOutput:backMovieOutput
                 forPort:backVideoPort
               toSession:self.multiCamSession
                 failure:&movieFailure
             failureCode:&movieFailureCode]) {
      NSLog(@"[DualCamera] Back movie output disabled: %@ (%@)", movieFailure, movieFailureCode);
      backMovieOutput = nil;
    }
  }

  // Front camera movie output (for front-mode recording in multi-cam session)
  if (ok) {
    AVCaptureMovieFileOutput *frontMovieOut = [[AVCaptureMovieFileOutput alloc] init];
    NSString *frontMovieFailure = nil;
    NSString *frontMovieFailureCode = nil;
    if (![self addOutput:frontMovieOut
                 forPort:frontVideoPort
               toSession:self.multiCamSession
                 failure:&frontMovieFailure
             failureCode:&frontMovieFailureCode]) {
      NSLog(@"[DualCamera] Front movie output disabled: %@ (%@)", frontMovieFailure, frontMovieFailureCode);
      self.frontMovieOutput = nil;
    } else {
      self.frontMovieOutput = frontMovieOut;
    }
  }

  // Audio → movie output connections (must be inside begin/commitConfiguration block)
  if (ok && self.audioInput) {
    [self addAudioConnectionToMovieOutput:self.audioInput output:backMovieOutput session:self.multiCamSession];
    [self addAudioConnectionToMovieOutput:self.audioInput output:self.frontMovieOutput session:self.multiCamSession];
  }

  [self.multiCamSession commitConfiguration];

  if (!ok) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:failure ?: @"Multi-cam session configuration failed." code:failureCode ?: @"multicam_configuration_failed"];
    return;
  }

  if (self.multiCamSession.hardwareCost > 1.0) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:@"This front/back camera configuration exceeds the device hardware budget." code:@"hardware_cost_exceeded"];
    return;
  }

  self.singleSession = nil;
  self.frontDeviceInput = frontInput;
  self.backDeviceInput = backInput;
  self.frontPhotoOutput = frontPhotoOutput;
  self.backPhotoOutput = backPhotoOutput;
  self.backMovieOutput = backMovieOutput;
  self.usingMultiCam = YES;
  self.isConfigured = YES;
  [self registerSessionNotifications:self.multiCamSession];

  [self.multiCamSession startRunning];
  self.isRunning = self.multiCamSession.isRunning;
  if (!self.isRunning) {
    [self emitSessionError:@"Multi-cam session did not start running." code:@"multicam_start_failed"];
  }
}

- (void)configureAndStartSingleCameraFallback {
  if ([self isDualLayout:self.currentLayout]) {
    [self emitSessionError:@"This device does not support simultaneous front and back camera preview." code:@"multicam_unsupported"];
  }
  [self configureSingleSessionForPosition:[self primaryCameraPosition] startRunning:YES];
}

- (void)configureSingleSessionForPosition:(AVCaptureDevicePosition)position startRunning:(BOOL)startRunning {
  [self unregisterSessionNotifications];
  [self.singleSession stopRunning];

  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  session.sessionPreset = AVCaptureSessionPresetHigh;

  AVCaptureDevice *device = [self cameraDeviceForPosition:position];
  if (!device) {
    [self emitSessionError:@"Could not find the requested camera." code:@"camera_not_found"];
    return;
  }

  NSError *error = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (!input) {
    [self emitSessionError:[NSString stringWithFormat:@"Camera input failed: %@", error.localizedDescription] code:@"single_input_failed"];
    return;
  }

  AVCapturePhotoOutput *photoOutput = [[AVCapturePhotoOutput alloc] init];
  AVCaptureMovieFileOutput *movieOutput = [[AVCaptureMovieFileOutput alloc] init];

  [session beginConfiguration];

  // Audio input (microphone)
  AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  if (audioDevice) {
    NSError *audioErr = nil;
    self.audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioErr];
    if (self.audioInput && [session canAddInput:self.audioInput]) {
      [session addInputWithNoConnections:self.audioInput];
    } else {
      NSLog(@"[DualCamera] Audio input not available: %@", audioErr.localizedDescription);
      self.audioInput = nil;
    }
  }

  BOOL addedInput = NO;
  if ([session canAddInput:input]) {
    [session addInput:input];
    addedInput = YES;
  }
  if ([session canAddOutput:photoOutput]) {
    [session addOutput:photoOutput];
  } else {
    photoOutput = nil;
  }
  if ([session canAddOutput:movieOutput]) {
    [session addOutput:movieOutput];
  } else {
    movieOutput = nil;
  }

  // Audio → singleMovieOutput (must be inside begin/commitConfiguration block)
  if (self.audioInput && movieOutput) {
    [self addAudioConnectionToMovieOutput:self.audioInput output:movieOutput session:session];
  }

  [session commitConfiguration];

  if (!addedInput) {
    [self emitSessionError:@"Cannot add camera input to fallback session." code:@"single_input_rejected"];
    return;
  }

  UIView *targetView = [self targetPreviewViewForPosition:position];
  dispatch_sync(dispatch_get_main_queue(), ^{
    [self removePreviewLayers];
    AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.frame = targetView.bounds;
    [targetView.layer addSublayer:layer];
    self.singlePreviewLayer = layer;
    [self updateLayout];
  });

  self.singleSession = session;
  self.multiCamSession = nil;
  self.singleDeviceInput = input;
  self.singlePhotoOutput = photoOutput;
  self.singleMovieOutput = movieOutput;
  self.singleCameraPosition = position;
  self.usingMultiCam = NO;
  self.isConfigured = YES;
  [self registerSessionNotifications:session];

  if (startRunning) {
    [session startRunning];
    self.isRunning = session.isRunning;
    if (!self.isRunning) {
      [self emitSessionError:@"Single camera fallback session did not start running." code:@"single_start_failed"];
    }
  }
}

- (void)reconfigureSingleSessionForCurrentLayout {
  AVCaptureDevicePosition nextPosition = [self primaryCameraPosition];
  if (nextPosition == self.singleCameraPosition && self.singleSession) {
    return;
  }
  BOOL shouldRun = self.isRunning;
  [self configureSingleSessionForPosition:nextPosition startRunning:shouldRun];
}

- (void)resumeIfNeeded {
  if (!self.isConfigured || self.isRunning) return;

  AVCaptureSession *session = self.usingMultiCam ? self.multiCamSession : self.singleSession;
  [session startRunning];
  self.isRunning = session.isRunning;
}

- (void)internalStopSession {
  dispatch_async(self.sessionQueue, ^{
    if (!self.isConfigured || !self.isRunning) return;

    if (self.backMovieOutput.isRecording) {
      [self.backMovieOutput stopRecording];
    }
    if (self.singleMovieOutput.isRecording) {
      [self.singleMovieOutput stopRecording];
    }

    [self.multiCamSession stopRunning];
    [self.singleSession stopRunning];
    self.isRunning = NO;
  });
}

#pragma mark - Session Configuration Helpers

- (AVCaptureDevice *)cameraDeviceForPosition:(AVCaptureDevicePosition)position {
  AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
    discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
    mediaType:AVMediaTypeVideo
    position:position];
  return discovery.devices.firstObject;
}

- (BOOL)configureDeviceForMultiCam:(AVCaptureDevice *)device error:(NSError **)error {
  AVCaptureDeviceFormat *format = [self bestMultiCamFormatForDevice:device];
  if (!format && ![device.activeFormat isMultiCamSupported]) {
    if (error) {
      *error = [NSError errorWithDomain:@"DualCamera"
                                   code:1001
                               userInfo:@{NSLocalizedDescriptionKey: @"No multi-cam supported format is available."}];
    }
    return NO;
  }

  if (![device lockForConfiguration:error]) {
    return NO;
  }

  if (format) {
    device.activeFormat = format;
  }
  device.activeVideoMinFrameDuration = CMTimeMake(1, 30);
  device.activeVideoMaxFrameDuration = CMTimeMake(1, 30);
  device.videoZoomFactor = _backZoomFactor;
  [device unlockForConfiguration];
  return YES;
}

- (void)dc_setFrontZoom:(CGFloat)factor {
  _frontZoomFactor = factor;
  dispatch_async(self.sessionQueue, ^{
    AVCaptureDevice *frontDevice = [self cameraDeviceForPosition:AVCaptureDevicePositionFront];
    if (!frontDevice) return;
    CGFloat f = factor;
    if (f < frontDevice.minAvailableVideoZoomFactor) {
      f = frontDevice.minAvailableVideoZoomFactor;
    } else if (f > frontDevice.maxAvailableVideoZoomFactor) {
      f = frontDevice.maxAvailableVideoZoomFactor;
    }
    NSError *err = nil;
    if ([frontDevice lockForConfiguration:&err]) {
      frontDevice.videoZoomFactor = f;
      [frontDevice unlockForConfiguration];
    }
  });
}

- (void)dc_setBackZoom:(CGFloat)factor {
  _backZoomFactor = factor;
  dispatch_async(self.sessionQueue, ^{
    AVCaptureDevice *backDevice = [self cameraDeviceForPosition:AVCaptureDevicePositionBack];
    if (!backDevice) return;
    CGFloat f = factor;
    if (f < backDevice.minAvailableVideoZoomFactor) {
      f = backDevice.minAvailableVideoZoomFactor;
    } else if (f > backDevice.maxAvailableVideoZoomFactor) {
      f = backDevice.maxAvailableVideoZoomFactor;
    }
    NSError *err = nil;
    if ([backDevice lockForConfiguration:&err]) {
      backDevice.videoZoomFactor = f;
      [backDevice unlockForConfiguration];
    }
  });
}

- (AVCaptureDeviceFormat *)bestMultiCamFormatForDevice:(AVCaptureDevice *)device {
  AVCaptureDeviceFormat *bestFormat = nil;
  int32_t bestArea = 0;

  for (AVCaptureDeviceFormat *format in device.formats) {
    if (![format isMultiCamSupported] || ![self formatSupportsThirtyFps:format]) {
      continue;
    }

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    int32_t area = dimensions.width * dimensions.height;
    BOOL fitsModerateBudget = dimensions.width <= 1920 && dimensions.height <= 1440;
    BOOL currentBestFitsBudget = NO;
    if (bestFormat) {
      CMVideoDimensions bestDimensions = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
      currentBestFitsBudget = bestDimensions.width <= 1920 && bestDimensions.height <= 1440;
    }

    if (!bestFormat ||
        (fitsModerateBudget && !currentBestFitsBudget) ||
        (fitsModerateBudget == currentBestFitsBudget && area > bestArea)) {
      bestFormat = format;
      bestArea = area;
    }
  }

  return bestFormat;
}

- (BOOL)formatSupportsThirtyFps:(AVCaptureDeviceFormat *)format {
  for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
    if (range.minFrameRate <= 30.0 && range.maxFrameRate >= 30.0) {
      return YES;
    }
  }
  return NO;
}

- (AVCaptureInputPort *)videoPortForInput:(AVCaptureDeviceInput *)input {
  for (AVCaptureInputPort *port in input.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeVideo]) {
      return port;
    }
  }
  return nil;
}

- (BOOL)addPreviewLayer:(AVCaptureVideoPreviewLayer *)layer
                forPort:(AVCaptureInputPort *)port
              toSession:(AVCaptureSession *)session
            mirrorVideo:(BOOL)mirrorVideo
                failure:(NSString **)failure
            failureCode:(NSString **)failureCode {
  AVCaptureConnection *connection = [[AVCaptureConnection alloc] initWithInputPort:port videoPreviewLayer:layer];
  if (![session canAddConnection:connection]) {
    if (failure) *failure = @"Cannot connect camera input to preview layer.";
    if (failureCode) *failureCode = @"preview_connection_failed";
    return NO;
  }

  [session addConnection:connection];
  if (connection.isVideoOrientationSupported) {
    connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  }
  if (mirrorVideo && connection.isVideoMirroringSupported) {
    connection.automaticallyAdjustsVideoMirroring = NO;
    connection.videoMirrored = YES;
  }
  return YES;
}

- (BOOL)addOutput:(AVCaptureOutput *)output
          forPort:(AVCaptureInputPort *)port
        toSession:(AVCaptureSession *)session
          failure:(NSString **)failure
      failureCode:(NSString **)failureCode {
  if (![session canAddOutput:output]) {
    if (failure) *failure = @"Cannot add camera output to session.";
    if (failureCode) *failureCode = @"output_rejected";
    return NO;
  }

  [session addOutputWithNoConnections:output];
  AVCaptureConnection *connection = [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:output];
  if (![session canAddConnection:connection]) {
    if (failure) *failure = @"Cannot connect camera input to output.";
    if (failureCode) *failureCode = @"output_connection_failed";
    return NO;
  }

  [session addConnection:connection];
  if (connection.isVideoOrientationSupported) {
    connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  }
  return YES;
}

- (void)addAudioConnectionToMovieOutput:(AVCaptureDeviceInput *)audioInput
                                 output:(AVCaptureMovieFileOutput *)movieOutput
                                session:(AVCaptureSession *)session {
  if (!movieOutput || !audioInput) return;

  for (AVCaptureInputPort *port in audioInput.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeAudio]) {
      AVCaptureConnection *audioConn = [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:movieOutput];
      if ([session canAddConnection:audioConn]) {
        [session addConnection:audioConn];
      }
      break;
    }
  }
}

#pragma mark - Capture Helpers

- (BOOL)isUsingMultiCamDualLayout {
  return self.usingMultiCam && [self isDualLayout:self.currentLayout];
}

- (NSString *)tempPathWithPrefix:(NSString *)prefix {
  return [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"%@%ld.mov", prefix, (long)[[NSDate date] timeIntervalSince1970]]];
}

- (NSString *)saveCIImageAsJPEG:(CIImage *)ciImage {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_composited_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];

  CIContext *ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
  CGImageRef cgImg = [ctx createCGImage:ciImage fromRect:ciImage.extent];
  if (!cgImg) return nil;

  UIImage *uiImage = [UIImage imageWithCGImage:cgImg];
  CGImageRelease(cgImg);

  NSData *jpgData = UIImageJPEGRepresentation(uiImage, 0.9);
  if (!jpgData) return nil;

  [jpgData writeToFile:path atomically:YES];
  return path;
}

- (CIImage *)compositeDualPhotosForCurrentLayout:(CIImage *)front back:(CIImage *)back {
  // Use preview view bounds as canvas reference (what user sees on screen)
  CGFloat canvasW = self.bounds.size.width;
  CGFloat canvasH = self.bounds.size.height;

  if ([self.currentLayout isEqualToString:@"lr"]) {
    // Left-right: back on left, front on right (portrait canvas)
    CGFloat halfW = canvasW;
    CGFloat halfH = canvasH / 2;
    return [self compositeLRForPhotos:front back:back canvasW:canvasW canvasH:canvasH halfW:halfW halfH:halfH];
  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    // Top-bottom: front on top, back on bottom
    CGFloat halfW = canvasW / 2;
    CGFloat halfH = canvasH;
    return [self compositeSXForPhotos:front back:back canvasW:canvasW canvasH:canvasH halfW:halfW halfH:halfH];
  } else if ([self.currentLayout isEqualToString:@"pip_square"]) {
    CGFloat s = canvasW * 0.28;
    return [self compositePIPForPhotos:front back:back canvasW:canvasW canvasH:canvasH
                             pipRect:CGRectMake(canvasW - s - 16, canvasH - s - 160, s, s)];
  } else if ([self.currentLayout isEqualToString:@"pip_circle"]) {
    CGFloat s = canvasW * 0.30;
    return [self compositePIPForPhotos:front back:back canvasW:canvasW canvasH:canvasH
                             pipRect:CGRectMake(canvasW - s - 16, canvasH - s - 160, s, s)];
  }

  return back;
}

- (CIImage *)compositeLRForPhotos:(CIImage *)front back:(CIImage *)back
                         canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                           halfW:(CGFloat)halfW halfH:(CGFloat)halfH {
  // Back camera: fill left half (no mirror)
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = halfH / backOrigH;
  CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
  CGFloat backScaledW = backOrigW * backScale;
  CGFloat backCropX = MAX(0, (backScaledW - halfW) / 2);
  CIImage *backLeft = [backScaled imageByCroppingToRect:CGRectMake(backCropX, 0, halfW, halfH)];

  // Front camera: fill right half, mirror horizontally (matches preview)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = halfH / frontOrigH;
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontScaledW = frontOrigW * frontScale;
  CGFloat frontCropX = MAX(0, (frontScaledW - halfW) / 2);
  CIImage *frontRightRaw = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, 0, halfW, halfH)];
  // Mirror: flip around center vertical axis
  CGFloat cx = halfW;
  CGAffineTransform mirror = CGAffineTransformConcat(
    CGAffineTransformMakeTranslation(cx, 0),
    CGAffineTransformMakeScale(-1, 1));
  CIImage *frontMirrored = [frontRightRaw imageByApplyingTransform:mirror];
  CIImage *frontRight = [frontMirrored imageByApplyingTransform:CGAffineTransformMakeTranslation(halfW, 0)];

  CIImage *composited = [backLeft imageByCompositingOverImage:frontRight];
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

- (CIImage *)compositeSXForPhotos:(CIImage *)front back:(CIImage *)back
                         canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                           halfW:(CGFloat)halfW halfH:(CGFloat)halfH {
  // Front camera: fill top half, mirror horizontally
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = halfW / frontOrigW;
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontScaledH = frontOrigH * frontScale;
  CGFloat frontCropY = MAX(0, (frontScaledH - halfH) / 2);
  CIImage *frontTopRaw = [frontScaled imageByCroppingToRect:CGRectMake(0, frontCropY, halfW, halfH)];
  // Mirror horizontally
  CGFloat cx = halfW;
  CGAffineTransform mirror = CGAffineTransformConcat(
    CGAffineTransformMakeTranslation(cx, 0),
    CGAffineTransformMakeScale(-1, 1));
  CIImage *frontMirrored = [frontTopRaw imageByApplyingTransform:mirror];

  // Back camera: fill bottom half (no mirror)
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = halfW / backOrigW;
  CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
  CGFloat backScaledH = backOrigH * backScale;
  CGFloat backCropY = MAX(0, (backScaledH - halfH) / 2);
  CIImage *backBottom = [backScaled imageByCroppingToRect:CGRectMake(0, backCropY, halfW, halfH)];
  CIImage *backBottomOffset = [backBottom imageByApplyingTransform:CGAffineTransformMakeTranslation(0, halfH)];

  CIImage *composited = [frontMirrored imageByCompositingOverImage:backBottomOffset];
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

- (CIImage *)compositePIPForPhotos:(CIImage *)front back:(CIImage *)back
                          canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                           pipRect:(CGRect)pipRect {
  // Back camera: scale to fill canvas (fill)
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = MAX(canvasW / backOrigW, canvasH / backOrigH);
  CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
  CGFloat backCropX = MAX(0, (backScaled.extent.size.width - canvasW) / 2);
  CGFloat backCropY = MAX(0, (backScaled.extent.size.height - canvasH) / 2);
  CIImage *backFull = [backScaled imageByCroppingToRect:CGRectMake(backCropX, backCropY, canvasW, canvasH)];

  // Front camera: scale to fill pip area (fit), mirror horizontally
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = MAX(pipRect.size.width / frontOrigW, pipRect.size.height / frontOrigH);
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontCropX = MAX(0, (frontScaled.extent.size.width - pipRect.size.width) / 2);
  CGFloat frontCropY = MAX(0, (frontScaled.extent.size.height - pipRect.size.height) / 2);
  CIImage *frontCropped = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, frontCropY, pipRect.size.width, pipRect.size.height)];
  // Mirror horizontally
  CGFloat cx = pipRect.size.width;
  CGAffineTransform mirror = CGAffineTransformConcat(
    CGAffineTransformMakeTranslation(cx, 0),
    CGAffineTransformMakeScale(-1, 1));
  CIImage *frontMirrored = [frontCropped imageByApplyingTransform:mirror];
  CIImage *pipPlaced = [frontMirrored imageByApplyingTransform:CGAffineTransformMakeTranslation(pipRect.origin.x, pipRect.origin.y)];

  return [[pipPlaced imageByCompositingOverImage:backFull]
    imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

- (CIImage *)scaledCIImage:(CIImage *)image toSize:(CGSize)size {
  CGFloat scaleX = size.width / image.extent.size.width;
  CGFloat scaleY = size.height / image.extent.size.height;
  CIFilter *scaleFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
  [scaleFilter setValue:image forKey:kCIInputImageKey];
  [scaleFilter setValue:@(scaleX) forKey:kCIInputScaleKey];
  [scaleFilter setValue:@(1.0) forKey:kCIInputAspectRatioKey];
  return scaleFilter.outputImage ?: image;
}

- (NSString *)documentsPathWithPrefix:(NSString *)prefix {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  return [paths.firstObject stringByAppendingPathComponent:
    [NSString stringWithFormat:@"%@%ld.mp4", prefix, (long)[[NSDate date] timeIntervalSince1970]]];
}

- (AVMutableVideoCompositionLayerInstruction *)layerForTrack:(AVMutableCompositionTrack *)track {
  if (!track) return nil;
  return [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
}

- (NSArray<AVMutableVideoCompositionLayerInstruction *> *)layersWithBack:(AVMutableCompositionTrack *)backTrack front:(AVMutableCompositionTrack *)frontTrack {
  NSMutableArray *layers = [NSMutableArray array];
  AVMutableVideoCompositionLayerInstruction *back = [self layerForTrack:backTrack];
  AVMutableVideoCompositionLayerInstruction *front = [self layerForTrack:frontTrack];
  if (back) [layers addObject:back];
  if (front) [layers addObject:front];
  return layers;
}

- (CGSize)videoSizeForAsset:(AVURLAsset *)asset {
  NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count > 0) {
    return videoTracks.firstObject.naturalSize;
  }
  return CGSizeMake(1080, 1920);
}

- (NSString *)compositeDualVideosForCurrentLayout:(NSString *)frontPath backPath:(NSString *)backPath {
  NSURL *frontURL = [NSURL fileURLWithPath:frontPath];
  NSURL *backURL  = [NSURL fileURLWithPath:backPath];

  if (![[NSFileManager defaultManager] fileExistsAtPath:frontPath] ||
      ![[NSFileManager defaultManager] fileExistsAtPath:backPath]) {
    NSLog(@"[DualCamera] One of the recording files is missing");
    return backPath;
  }

  AVURLAsset *frontAsset = [AVURLAsset assetWithURL:frontURL];
  AVURLAsset *backAsset  = [AVURLAsset assetWithURL:backURL];

  CMTime duration = backAsset.duration;
  // Use canvas size from recording start (portrait=竖屏, landscape=横屏)
  CGFloat canvasW = self.canvasSizeAtRecording.width;
  CGFloat canvasH = self.canvasSizeAtRecording.height;
  if (canvasW == 0 || canvasH == 0) {
    // Fallback to video native size if not captured
    CGSize videoSize = [self videoSizeForAsset:backAsset];
    canvasW = videoSize.width;
    canvasH = videoSize.height;
  }

  AVMutableComposition *composition = [AVMutableComposition composition];

  // Audio track from back video
  NSArray *backAudioTracks = [backAsset tracksWithMediaType:AVMediaTypeAudio];
  if (backAudioTracks.count > 0) {
    AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
    [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                        ofTrack:backAudioTracks.firstObject
                         atTime:kCMTimeZero
                          error:nil];
  }

  // Front video track
  NSArray<AVAssetTrack *> *frontVideoTracks = [frontAsset tracksWithMediaType:AVMediaTypeVideo];
  AVMutableCompositionTrack *frontVideoTrack = nil;
  AVMutableCompositionTrack *backVideoTrack  = nil;

  if (frontVideoTracks.count > 0) {
    frontVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                               preferredTrackID:kCMPersistentTrackID_Invalid];
    [frontVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                             ofTrack:frontVideoTracks.firstObject
                              atTime:kCMTimeZero
                               error:nil];
  }

  NSArray<AVAssetTrack *> *backVideoTracks = [backAsset tracksWithMediaType:AVMediaTypeVideo];
  if (backVideoTracks.count > 0) {
    backVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                              preferredTrackID:kCMPersistentTrackID_Invalid];
    [backVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                            ofTrack:backVideoTracks.firstObject
                             atTime:kCMTimeZero
                              error:nil];
  }

  // Build video composition for layout using canvas dimensions
  AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoComposition];
  videoComp.renderSize = CGSizeMake(canvasW, canvasH);
  videoComp.frameDuration = CMTimeMake(1, 30);

  CMTimeRange timeRange = CMTimeRangeMake(kCMTimeZero, duration);

  // Reference sizes for transform calculation (use back camera as reference)
  CGSize refSize = [self videoSizeForAsset:backAsset];
  CGFloat refW = refSize.width;
  CGFloat refH = refSize.height;
  CGFloat ratio = self.dualLayoutRatio > 0 ? self.dualLayoutRatio : 0.5;

  if ([self.currentLayout isEqualToString:@"lr"]) {
    // LR: portrait canvas (canvasW < canvasH), split left/right vertically
    // back on left, front on right
    CGFloat leftWidth  = canvasW * ratio;   // ratio = back proportion
    CGFloat rightWidth = canvasW * (1 - ratio);

    // Back (left): fill by height, center horizontally
    CGFloat backScale = canvasH / refH;
    CGFloat backFillW = refW * backScale;
    CGFloat backOffsetX = (leftWidth - backFillW) / 2; // center in left half

    // Front (right): fill by height, center in right half, mirror
    CGFloat frontScale = canvasH / refH;
    CGFloat frontFillW = refW * frontScale;
    CGFloat frontOffsetX = leftWidth + (rightWidth - frontFillW) / 2;

    CGAffineTransform backTransform = CGAffineTransformMakeScale(backScale, backScale);
    backTransform = CGAffineTransformTranslate(backTransform, backOffsetX, 0);
    CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
    frontTransform = CGAffineTransformTranslate(frontTransform, frontOffsetX, 0);

    if (backVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *backLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:backVideoTrack];
      [backLayer setTransform:backTransform atTime:kCMTimeZero];
    }
    if (frontVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *frontLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:frontVideoTrack];
      [frontLayer setTransform:frontTransform atTime:kCMTimeZero];
    }

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = [self layersWithBack:backVideoTrack front:frontVideoTrack];
    videoComp.instructions = @[instruction];

  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    // SX: portrait canvas (canvasW < canvasH), split top/bottom horizontally
    // front on top, back on bottom
    CGFloat topHeight    = canvasH * (1 - ratio);  // front proportion
    CGFloat bottomHeight = canvasH * ratio;          // back proportion

    // Front (top): fill by width, center vertically
    CGFloat frontScale = canvasW / refW;
    CGFloat frontFillH = refH * frontScale;
    CGFloat frontOffsetY = (topHeight - frontFillH) / 2;

    // Back (bottom): fill by width, center in bottom half
    CGFloat backScale = canvasW / refW;
    CGFloat backFillH = refH * backScale;
    CGFloat backOffsetY = topHeight + (bottomHeight - backFillH) / 2;

    CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
    frontTransform = CGAffineTransformTranslate(frontTransform, 0, frontOffsetY);
    CGAffineTransform backTransform = CGAffineTransformMakeScale(backScale, backScale);
    backTransform = CGAffineTransformTranslate(backTransform, 0, backOffsetY);

    if (backVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *backLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:backVideoTrack];
      [backLayer setTransform:backTransform atTime:kCMTimeZero];
    }
    if (frontVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *frontLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:frontVideoTrack];
      [frontLayer setTransform:frontTransform atTime:kCMTimeZero];
    }

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = [self layersWithBack:frontVideoTrack front:backVideoTrack];
    videoComp.instructions = @[instruction];

  } else {
    // pip_square / pip_circle: back full screen, front as corner overlay
    CGFloat s = canvasW * self.pipSize;
    CGFloat pipX = canvasW * self.pipPositionX - s / 2;
    CGFloat pipY = canvasH * self.pipPositionY - s / 2;

    // Back: scale to fill canvas (fill)
    CGFloat backScaleX = canvasW / refW;
    CGFloat backScaleY = canvasH / refH;
    CGFloat backScale = MAX(backScaleX, backScaleY);
    CGFloat backFillW = refW * backScale;
    CGFloat backFillH = refH * backScale;
    CGFloat backOffsetX = (canvasW - backFillW) / 2;
    CGFloat backOffsetY = (canvasH - backFillH) / 2;
    CGAffineTransform backTransform = CGAffineTransformMakeScale(backScale, backScale);
    backTransform = CGAffineTransformTranslate(backTransform, backOffsetX, backOffsetY);

    // Front: scale to fit pip area (fit), position in corner
    CGFloat frontScaleX = s / refW;
    CGFloat frontScaleY = s / refH;
    CGFloat frontScale = MIN(frontScaleX, frontScaleY);
    CGFloat frontFillW = refW * frontScale;
    CGFloat frontFillH = refH * frontScale;
    CGFloat frontOffsetX = pipX + (s - frontFillW) / 2;
    CGFloat frontOffsetY = pipY + (s - frontFillH) / 2;
    CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
    frontTransform = CGAffineTransformTranslate(frontTransform, frontOffsetX, frontOffsetY);

    if (backVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *backLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:backVideoTrack];
      [backLayer setTransform:backTransform atTime:kCMTimeZero];
    }
    if (frontVideoTrack) {
      AVMutableVideoCompositionLayerInstruction *frontLayer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:frontVideoTrack];
      [frontLayer setTransform:frontTransform atTime:kCMTimeZero];
    }

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = [self layersWithBack:backVideoTrack front:frontVideoTrack];
    videoComp.instructions = @[instruction];
  }

  NSString *outPath = [self documentsPathWithPrefix:@"dual_composited_"];
  self.videoExportSession =
    [[AVAssetExportSession alloc] initWithAsset:composition
                                presetName:AVAssetExportPresetHighestQuality];
  self.videoExportSession.outputURL = [NSURL fileURLWithPath:outPath];
  self.videoExportSession.outputFileType = AVFileTypeMPEG4;
  self.videoExportSession.videoComposition = videoComp;

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  NSMutableArray *resultArray = [NSMutableArray arrayWithObject:[NSNull null]];

  [self.videoExportSession exportAsynchronouslyWithCompletionHandler:^{
    if (self.videoExportSession.status == AVAssetExportSessionStatusCompleted) {
      resultArray[0] = outPath;
    } else {
      NSLog(@"[DualCamera] Video export failed: %@", self.videoExportSession.error);
      resultArray[0] = backPath;
    }
    self.videoExportSession = nil;
    dispatch_semaphore_signal(sema);
  }];

  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
  return [resultArray[0] isKindOfClass:[NSString class]] ? resultArray[0] : backPath;
}

#pragma mark - Capture

- (void)internalTakePhoto {
  dispatch_async(self.sessionQueue, ^{
    if (!self.isConfigured) return;

    if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
      // Dual-cam: use canvas snapshot for WYSIWYG (what you see = what you get)
      // The preview layers already handle orientation/mirroring/scaling correctly,
      // so rendering the view gives us the exact saved image
      dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *snapshot = [self captureCanvasSnapshot];
        NSString *path = [self saveImageAsJPEG:snapshot];
        if (path) {
          [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
        } else {
          [self emitError:@"Failed to capture canvas snapshot"];
        }
      });
    } else {
      // Single-cam: use photo output for full-resolution
      AVCapturePhotoOutput *output = [self photoOutputForCurrentLayout];
      if (!output) {
        [self emitError:@"Photo output not available"];
        return;
      }
      AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
      settings.flashMode = AVCaptureFlashModeOff;
      [output capturePhotoWithSettings:settings delegate:self];
    }
  });
}

- (UIImage *)captureCanvasSnapshot {
  UIGraphicsBeginImageContextWithOptions(self.bounds.size, YES, [UIScreen mainScreen].scale);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  [self.layer renderInContext:ctx];
  UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return img;
}

- (NSString *)saveImageAsJPEG:(UIImage *)image {
  if (!image) return nil;
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *docs = paths.firstObject;
  NSString *path = [docs stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
  NSData *jpg = UIImageJPEGRepresentation(image, 0.9);
  [jpg writeToFile:path atomically:YES];
  return path;
}

- (void)internalStartRecording {
  dispatch_async(self.sessionQueue, ^{
    if (!self.isConfigured) return;

    if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
      // Canvas size captured from self.bounds (main thread safe since bounds doesn't change during recording)
      self.canvasSizeAtRecording = self.bounds.size;

      // Dual-cam: record both simultaneously
      if (self.isDualRecordingActive) return; // prevent double-start
      self.isDualRecordingActive = YES;
      self.backRecordingFinished = NO;
      self.frontRecordingFinished = NO;

      self.backRecordingPath = [self tempPathWithPrefix:@"dual_back_"];
      self.frontRecordingPath = [self tempPathWithPrefix:@"dual_front_"];

      [self.backMovieOutput startRecordingToOutputFileURL:
        [NSURL fileURLWithPath:self.backRecordingPath] recordingDelegate:self];
      [self.frontMovieOutput startRecordingToOutputFileURL:
        [NSURL fileURLWithPath:self.frontRecordingPath] recordingDelegate:self];
    } else {
      // Single-cam
      self.canvasSizeAtRecording = self.bounds.size;
      AVCaptureMovieFileOutput *output = [self movieOutputForCurrentLayout];
      if (!output) {
        [self emitRecordingError:@"Video recording is currently available only for the active single camera or the back camera stream in dual mode."];
        return;
      }
      if (output.isRecording) return;

      NSString *path = [self tempPathWithPrefix:@"dual_"];
      [output startRecordingToOutputFileURL:[NSURL fileURLWithPath:path] recordingDelegate:self];
    }
  });
}

- (void)internalStopRecording {
  dispatch_async(self.sessionQueue, ^{
    if (!self.isConfigured) return;

    if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
      // Stop both recordings
      if (self.backMovieOutput.isRecording) {
        [self.backMovieOutput stopRecording];
      }
      if (self.frontMovieOutput.isRecording) {
        [self.frontMovieOutput stopRecording];
      }
      // NOTE: isDualRecordingActive cleared when both outputs finish (in delegate)
    } else {
      // Single-cam
      AVCaptureMovieFileOutput *output = [self activeRecordingOutput];
      if (output.isRecording) {
        [output stopRecording];
      }
    }
  });
}

- (AVCapturePhotoOutput *)photoOutputForCurrentLayout {
  if (self.usingMultiCam) {
    return [self primaryCameraPosition] == AVCaptureDevicePositionFront ? self.frontPhotoOutput : self.backPhotoOutput;
  }
  return self.singlePhotoOutput;
}

- (AVCaptureMovieFileOutput *)movieOutputForCurrentLayout {
  if (self.usingMultiCam) {
    if ([self primaryCameraPosition] == AVCaptureDevicePositionBack) {
      return self.backMovieOutput;
    } else {
      return self.frontMovieOutput;
    }
  }
  return self.singleMovieOutput;
}

- (AVCaptureMovieFileOutput *)activeRecordingOutput {
  if (self.backMovieOutput.isRecording) return self.backMovieOutput;
  if (self.frontMovieOutput.isRecording) return self.frontMovieOutput;
  if (self.singleMovieOutput.isRecording) return self.singleMovieOutput;
  return nil;
}

#pragma mark - Layout Helpers

- (BOOL)isDualLayout:(NSString *)layout {
  return ![layout isEqualToString:@"back"] && ![layout isEqualToString:@"front"];
}

- (AVCaptureDevicePosition)primaryCameraPosition {
  return [self.currentLayout isEqualToString:@"front"] ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
}

- (UIView *)targetPreviewViewForPosition:(AVCaptureDevicePosition)position {
  return position == AVCaptureDevicePositionFront ? self.frontPreviewView : self.backPreviewView;
}

- (void)removePreviewLayers {
  [self.frontPreviewLayer removeFromSuperlayer];
  [self.backPreviewLayer removeFromSuperlayer];
  [self.singlePreviewLayer removeFromSuperlayer];
  self.frontPreviewLayer = nil;
  self.backPreviewLayer = nil;
  self.singlePreviewLayer = nil;
}

- (void)clearPreviewLayersOnMainQueue {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self removePreviewLayers];
  });
}

#pragma mark - Notifications

- (void)registerSessionNotifications:(AVCaptureSession *)session {
  [self unregisterSessionNotifications];
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:session];
  [center addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:session];
  [center addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:session];
}

- (void)unregisterSessionNotifications {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionWasInterruptedNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionInterruptionEndedNotification object:nil];
}

- (void)sessionRuntimeError:(NSNotification *)notification {
  NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
  [self emitSessionError:error.localizedDescription ?: @"Camera session runtime error." code:@"session_runtime_error"];
}

- (void)sessionWasInterrupted:(NSNotification *)notification {
  NSNumber *reason = notification.userInfo[AVCaptureSessionInterruptionReasonKey];
  NSString *message = reason ? [NSString stringWithFormat:@"Camera session was interrupted. reason=%@", reason] : @"Camera session was interrupted.";
  [self emitSessionError:message code:@"session_interrupted"];
}

- (void)sessionInterruptionEnded:(NSNotification *)notification {
  [self startOnSessionQueue];
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

- (void)emitSessionError:(NSString *)error code:(NSString *)code {
  [[DualCameraEventEmitter shared] sendSessionError:error code:code];
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

  // Dual-cam photo compositing
  if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
    CIImage *ciImage = [CIImage imageWithData:data];
    if (!ciImage) {
      [self emitError:@"Failed to create CIImage"];
      return;
    }

    NSString *key = (output == self.backPhotoOutput) ? @"back" : @"front";
    self.pendingDualPhotos[key] = ciImage;
    if (output == self.backPhotoOutput) self.pendingDualPhotosBack = YES;
    if (output == self.frontPhotoOutput) self.pendingDualPhotosFront = YES;

    // Both images received
    if (self.pendingDualPhotosBack && self.pendingDualPhotosFront) {
      CIImage *frontImg = self.pendingDualPhotos[@"front"];
      CIImage *backImg  = self.pendingDualPhotos[@"back"];
      [self.pendingDualPhotos removeAllObjects];

      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CIImage *composited = [self compositeDualPhotosForCurrentLayout:frontImg back:backImg];
        NSString *path = [self saveCIImageAsJPEG:composited];
        dispatch_async(dispatch_get_main_queue(), ^{
          if (path) {
            [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
          } else {
            [self emitError:@"Failed to save composited photo"];
          }
        });
      });
    }
    return;
  }

  // Single-cam mode: save directly
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
  [data writeToFile:path atomically:YES];
  [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
}

#pragma mark - AVCaptureFileOutputRecordingDelegate

- (void)captureOutput:(AVCaptureFileOutput *)output
    didFinishRecordingToOutputFileAtURL:(NSURL *)fileURL
                        fromConnections:(NSArray<AVCaptureConnection *> *)connections
                                  error:(NSError *)error {
  if (error) {
    // Error case: stop the other recording and reset
    if (self.isDualRecordingActive) {
      if (output == self.backMovieOutput && self.frontMovieOutput.isRecording) {
        [self.frontMovieOutput stopRecording];
      }
      if (output == self.frontMovieOutput && self.backMovieOutput.isRecording) {
        [self.backMovieOutput stopRecording];
      }
      self.isDualRecordingActive = NO;
      self.backRecordingPath = nil;
      self.frontRecordingPath = nil;
    }
    [self emitRecordingError:error.localizedDescription];
    return;
  }

  if (self.isDualRecordingActive) {
    // Mark which output finished
    if (output == self.backMovieOutput) {
      self.backRecordingFinished = YES;
    } else if (output == self.frontMovieOutput) {
      self.frontRecordingFinished = YES;
    }

    // Both recordings finished: trigger compositing
    if (self.backRecordingFinished && self.frontRecordingFinished) {
      self.backRecordingFinished = NO;
      self.frontRecordingFinished = NO;
      self.isDualRecordingActive = NO;

      NSString *backPath = self.backRecordingPath;
      NSString *frontPath = self.frontRecordingPath;

      dispatch_async(self.compositingQueue, ^{
        NSString *composited = [self compositeDualVideosForCurrentLayout:frontPath backPath:backPath];

        [[NSFileManager defaultManager] removeItemAtPath:frontPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:backPath error:nil];
        self.frontRecordingPath = nil;
        self.backRecordingPath = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
          if (composited) {
            [self emitRecordingFinished:[NSString stringWithFormat:@"file://%@", composited]];
          } else {
            [self emitRecordingError:@"Failed to composite video"];
          }
        });
      });
    }
    return;
  }

  // Single-cam mode: emit directly
  [self emitRecordingFinished:fileURL.absoluteString];
}

- (void)dealloc {
  [self unregisterSessionNotifications];
  // Stop sessions synchronously on current thread to avoid queue deadlock during dealloc
  [_multiCamSession stopRunning];
  [_singleSession stopRunning];
  _isConfigured = NO;
  _videoExportSession = nil;
}

@end
