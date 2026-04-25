#import "DualCameraView.h"
#import "DualCameraEventEmitter.h"
#import "DualCameraSessionManager.h"

@interface DualCameraView () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate>

@property (nonatomic, strong) AVCaptureMultiCamSession *multiCamSession;
@property (nonatomic, strong) AVCaptureSession *singleSession;
@property (nonatomic, strong) AVCaptureDeviceInput *frontDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *backDeviceInput;
@property (nonatomic, strong) AVCaptureDeviceInput *singleDeviceInput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *frontPreviewLayer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *backPreviewLayer;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *singlePreviewLayer;
@property (nonatomic, strong) AVCapturePhotoOutput *frontPhotoOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *backPhotoOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *singlePhotoOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *backMovieOutput;
@property (nonatomic, strong) AVCaptureMovieFileOutput *singleMovieOutput;
@property (nonatomic, strong) UIView *frontPreviewView;
@property (nonatomic, strong) UIView *backPreviewView;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, assign) AVCaptureDevicePosition singleCameraPosition;
@property (nonatomic, assign) BOOL usingMultiCam;
@property (nonatomic, assign) BOOL isConfigured;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, copy) NSString *currentLayout;

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

  _frontPreviewView.layer.cornerRadius = 0;
  _frontPreviewView.layer.masksToBounds = YES;
  _backPreviewView.layer.cornerRadius = 0;
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

  } else if ([_currentLayout isEqualToString:@"pip_circle"]) {
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
    CGFloat s = 110;
    _frontPreviewView.frame = CGRectMake(w - s - 16, h - s - 160, s, s);
    _frontPreviewView.layer.cornerRadius = s / 2;

  } else {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = self.bounds;
  }

  _frontPreviewLayer.frame = _frontPreviewView.bounds;
  _backPreviewLayer.frame = _backPreviewView.bounds;
  _singlePreviewLayer.frame = [self targetPreviewViewForPosition:self.singleCameraPosition].bounds;
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

  AVCaptureMultiCamSession *session = [[AVCaptureMultiCamSession alloc] init];
  __block AVCaptureVideoPreviewLayer *backLayer = nil;
  __block AVCaptureVideoPreviewLayer *frontLayer = nil;
  dispatch_sync(dispatch_get_main_queue(), ^{
    [self removePreviewLayers];

    backLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSessionWithNoConnection:session];
    backLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    backLayer.frame = self.backPreviewView.bounds;
    [self.backPreviewView.layer addSublayer:backLayer];

    frontLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSessionWithNoConnection:session];
    frontLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    frontLayer.frame = self.frontPreviewView.bounds;
    [self.frontPreviewView.layer addSublayer:frontLayer];

    self.backPreviewLayer = backLayer;
    self.frontPreviewLayer = frontLayer;
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

  [session beginConfiguration];

  if ([session canAddInput:backInput]) {
    [session addInputWithNoConnections:backInput];
  } else {
    ok = NO;
    failure = @"Cannot add back camera input to multi-cam session.";
    failureCode = @"back_input_rejected";
  }

  if (ok && [session canAddInput:frontInput]) {
    [session addInputWithNoConnections:frontInput];
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
    ok = [self addPreviewLayer:backLayer
                      forPort:backVideoPort
                    toSession:session
                  mirrorVideo:NO
                      failure:&failure
                  failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addPreviewLayer:frontLayer
                      forPort:frontVideoPort
                    toSession:session
                  mirrorVideo:YES
                      failure:&failure
                  failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addOutput:backPhotoOutput
                 forPort:backVideoPort
               toSession:session
                 failure:&failure
             failureCode:&failureCode];
  }

  if (ok) {
    ok = [self addOutput:frontPhotoOutput
                 forPort:frontVideoPort
               toSession:session
                 failure:&failure
             failureCode:&failureCode];
  }

  if (ok) {
    NSString *movieFailure = nil;
    NSString *movieFailureCode = nil;
    if (![self addOutput:backMovieOutput
                 forPort:backVideoPort
               toSession:session
                 failure:&movieFailure
             failureCode:&movieFailureCode]) {
      NSLog(@"[DualCamera] Back movie output disabled: %@ (%@)", movieFailure, movieFailureCode);
      backMovieOutput = nil;
    }
  }

  [session commitConfiguration];

  if (!ok) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:failure ?: @"Multi-cam session configuration failed." code:failureCode ?: @"multicam_configuration_failed"];
    return;
  }

  if (session.hardwareCost > 1.0) {
    [self clearPreviewLayersOnMainQueue];
    [self emitSessionError:@"This front/back camera configuration exceeds the device hardware budget." code:@"hardware_cost_exceeded"];
    return;
  }

  self.multiCamSession = session;
  self.singleSession = nil;
  self.frontDeviceInput = frontInput;
  self.backDeviceInput = backInput;
  self.frontPhotoOutput = frontPhotoOutput;
  self.backPhotoOutput = backPhotoOutput;
  self.backMovieOutput = backMovieOutput;
  self.usingMultiCam = YES;
  self.isConfigured = YES;
  [self registerSessionNotifications:session];

  [session startRunning];
  self.isRunning = session.isRunning;
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
  [device unlockForConfiguration];
  return YES;
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

#pragma mark - Capture

- (void)internalTakePhoto {
  dispatch_async(self.sessionQueue, ^{
    AVCapturePhotoOutput *output = [self photoOutputForCurrentLayout];
    if (!output) {
      [self emitError:@"Photo output not available"];
      return;
    }

    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    settings.flashMode = AVCaptureFlashModeOff;
    [output capturePhotoWithSettings:settings delegate:self];
  });
}

- (void)internalStartRecording {
  dispatch_async(self.sessionQueue, ^{
    AVCaptureMovieFileOutput *output = [self movieOutputForCurrentLayout];
    if (!output) {
      [self emitRecordingError:@"Video recording is currently available only for the active single camera or the back camera stream in dual mode."];
      return;
    }

    if (output.isRecording) {
      return;
    }

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"dual_%ld.mov", (long)[[NSDate date] timeIntervalSince1970]]];
    [output startRecordingToOutputFileURL:[NSURL fileURLWithPath:path] recordingDelegate:self];
  });
}

- (void)internalStopRecording {
  dispatch_async(self.sessionQueue, ^{
    AVCaptureMovieFileOutput *output = [self activeRecordingOutput];
    if (output.isRecording) {
      [output stopRecording];
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
    return [self primaryCameraPosition] == AVCaptureDevicePositionBack ? self.backMovieOutput : nil;
  }
  return self.singleMovieOutput;
}

- (AVCaptureMovieFileOutput *)activeRecordingOutput {
  if (self.backMovieOutput.isRecording) return self.backMovieOutput;
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
  [self unregisterSessionNotifications];
  [_multiCamSession stopRunning];
  [_singleSession stopRunning];
}

@end
