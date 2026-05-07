#import "DualCameraView.h"
#import "DualCameraEventEmitter.h"
#import "DualCameraSessionManager.h"
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface DualCameraView () <AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, UIGestureRecognizerDelegate>

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

// VideoDataOutput for WYSIWYG photo capture
@property (nonatomic, strong) AVCaptureVideoDataOutput *frontVideoDataOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *backVideoDataOutput;
@property (nonatomic, strong) dispatch_queue_t videoDataOutputQueue;
@property (nonatomic, strong) CIImage *latestFrontFrame;
@property (nonatomic, strong) CIImage *latestBackFrame;

// Dual compositing state
@property (nonatomic, strong) NSMutableDictionary *pendingDualPhotos;
@property (nonatomic, assign) BOOL pendingDualPhotosFront;
@property (nonatomic, assign) BOOL pendingDualPhotosBack;
@property (nonatomic, strong) NSString *backRecordingPath;
@property (nonatomic, strong) NSString *frontRecordingPath;
@property (nonatomic, assign) BOOL backRecordingFinished;
@property (nonatomic, assign) BOOL frontRecordingFinished;
@property (nonatomic, assign) BOOL isDualRecordingActive;
@property (nonatomic, strong) AVAssetExportSession *videoExportSession;
@property (nonatomic, strong) dispatch_queue_t compositingQueue;

// canvasSizeAtRecording — only declared here (not in .h), used internally
@property (nonatomic, assign) CGSize canvasSizeAtRecording;

// sxBackOnTop and pipMainIsBack are declared in DualCameraView.h

// PiP gesture recognizers
@property (nonatomic, strong) UIPanGestureRecognizer *pipPanGesture;
@property (nonatomic, strong) UIPinchGestureRecognizer *pipPinchGesture;
@property (nonatomic, assign) CGFloat lastPipSize;

// Forward declaration for compositePIPFront: called before definition
- (CIImage *)compositePIPFront:(CIImage *)front back:(CIImage *)back
                     canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                     pipRect:(CGRect)pipRect
                    isCircle:(BOOL)isCircle;

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
  NSLog(@"[DualCamera] DualCameraView commonInit called");
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
  _videoDataOutputQueue = dispatch_queue_create("com.zhengning.dualcamera.videodata", DISPATCH_QUEUE_SERIAL);
  // Default values for layout/PiP/zoom properties (declared in .h for React Native)
  _dualLayoutRatio = 0.5;
  _pipSize = 0.28;
  _pipPositionX = 0.85;
  _pipPositionY = 0.80;
  _frontZoomFactor = 1.0;
  _backZoomFactor = 1.0;
  _saveAspectRatio = @"9:16";
  _backZoomFactor = 1.0;
  _canvasSizeAtRecording = CGSizeZero;
  _sxBackOnTop = YES;    // SX: default back on top
  _pipMainIsBack = YES;  // PiP: default back is main (full-screen)
  [self createPlaceholderViews];
  [self setupPipGestures];
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

- (void)setPipMainIsBack:(BOOL)pipMainIsBack {
  _pipMainIsBack = pipMainIsBack;
  // Enable/disable PiP gestures based on which view is the small window
  // pipMainIsBack=YES: _frontPreviewView is the small window (enable gestures)
  // pipMainIsBack=NO:  _frontPreviewView is the main view (disable gestures)
  self.pipPanGesture.enabled = pipMainIsBack;
  self.pipPinchGesture.enabled = pipMainIsBack;
}

- (void)setupPipGestures {
  // Guard: if views were recreated after initial setup, re-attach gestures
  if (_pipPanGesture) {
    // Views were recreated (createPlaceholderViews called again)
    // Re-add gesture recognizers to the new _frontPreviewView
    if (_pipPanGesture.view != _frontPreviewView) {
      [_pipPanGesture.view removeGestureRecognizer:_pipPanGesture];
      [_pipPinchGesture.view removeGestureRecognizer:_pipPinchGesture];
      [_frontPreviewView addGestureRecognizer:_pipPanGesture];
      [_frontPreviewView addGestureRecognizer:_pipPinchGesture];
    }
    return;
  }

  // UIPanGestureRecognizer — PiP drag
  _pipPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePipPan:)];
  _pipPanGesture.delegate = self;
  _pipPanGesture.enabled = _pipMainIsBack; // only enabled when _frontPreviewView is the small window
  [_frontPreviewView addGestureRecognizer:_pipPanGesture];
  _frontPreviewView.userInteractionEnabled = YES;

  // UIPinchGestureRecognizer — PiP pinch to resize
  _pipPinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePipPinch:)];
  _pipPinchGesture.delegate = self;
  _pipPinchGesture.enabled = _pipMainIsBack;
  [_frontPreviewView addGestureRecognizer:_pipPinchGesture];
}

- (void)handlePipPan:(UIPanGestureRecognizer *)pan {
  CGPoint translation = [pan translationInView:self];
  CGPoint center = _frontPreviewView.center;
  center.x += translation.x;
  center.y += translation.y;

  // Clamp: small window center cannot exit canvas bounds
  CGFloat halfW = _frontPreviewView.bounds.size.width / 2;
  CGFloat halfH = _frontPreviewView.bounds.size.height / 2;
  center.x = MAX(halfW, MIN(self.bounds.size.width - halfW, center.x));
  center.y = MAX(halfH, MIN(self.bounds.size.height - halfH, center.y));

  _frontPreviewView.center = center;
  [pan setTranslation:CGPointZero inView:self];

  // Update normalized coordinates for save
  _pipPositionX = center.x / self.bounds.size.width;
  _pipPositionY = center.y / self.bounds.size.height;

  if (pan.state == UIGestureRecognizerStateEnded) {
    [[DualCameraEventEmitter shared] sendPipPositionChanged:_pipPositionX y:_pipPositionY];
  }
}

- (void)handlePipPinch:(UIPinchGestureRecognizer *)pinch {
  if (pinch.state == UIGestureRecognizerStateBegan) {
    _lastPipSize = _pipSize;
  }
  CGFloat newSize = _lastPipSize * pinch.scale;
  _pipSize = MAX(0.05, MIN(0.5, newSize));

  // Update view frame
  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });

  if (pinch.state == UIGestureRecognizerStateEnded) {
    [[DualCameraEventEmitter shared] sendPipSizeChanged:_pipSize];
  }
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
  // Allow pan and pinch to work simultaneously
  if ((gestureRecognizer == self.pipPanGesture && otherGestureRecognizer == self.pipPinchGesture) ||
      (gestureRecognizer == self.pipPinchGesture && otherGestureRecognizer == self.pipPanGesture)) {
    return YES;
  }
  return NO;
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

  // Re-setup PiP gestures whenever views are recreated
  [self setupPipGestures];

  dispatch_async(dispatch_get_main_queue(), ^{
    [self updateLayout];
  });
}

#pragma mark - Layout

- (CGRect)canvasBoundsForAspectRatio {
  CGFloat screenW = self.bounds.size.width;
  CGFloat screenH = self.bounds.size.height;
  CGFloat canvasW, canvasH;

  if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
    canvasW = screenW;
    canvasH = canvasW * 16.0 / 9.0;
    if (canvasH > screenH) {
      canvasH = screenH;
      canvasW = canvasH * 9.0 / 16.0;
    }
  } else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
    canvasW = screenW;
    canvasH = canvasW * 4.0 / 3.0;
    if (canvasH > screenH) {
      canvasH = screenH;
      canvasW = canvasH * 3.0 / 4.0;
    }
  } else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
    CGFloat minDim = MIN(screenW, screenH);
    canvasW = canvasH = minDim;
  } else {
    return self.bounds;
  }

  CGFloat ox = (screenW - canvasW) / 2.0;
  CGFloat oy = (screenH - canvasH) / 2.0;
  return CGRectMake(ox, oy, canvasW, canvasH);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self updateLayout];
}

- (void)updateLayout {
  CGRect canvas = [self canvasBoundsForAspectRatio];
  CGFloat w = canvas.size.width;
  CGFloat h = canvas.size.height;
  CGFloat ox = canvas.origin.x;
  CGFloat oy = canvas.origin.y;
  CGFloat ratio = self.dualLayoutRatio > 0 ? self.dualLayoutRatio : 0.5;

  _frontPreviewView.layer.masksToBounds = YES;
  _backPreviewView.layer.masksToBounds = YES;

  if ([_currentLayout isEqualToString:@"back"]) {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = canvas;

  } else if ([_currentLayout isEqualToString:@"front"]) {
    _backPreviewView.hidden = YES;
    _frontPreviewView.hidden = NO;
    _frontPreviewView.frame = canvas;

  } else if ([_currentLayout isEqualToString:@"lr"]) {
    // LR: portrait canvas, split left/right vertically
    // back on left (ratio), front on right (1-ratio)
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    CGFloat leftW  = w * ratio;
    CGFloat rightW = w * (1 - ratio);
    _backPreviewView.frame  = CGRectMake(ox, oy, leftW, h);
    _frontPreviewView.frame = CGRectMake(ox + leftW, oy, rightW, h);

  } else if ([_currentLayout isEqualToString:@"sx"]) {
    // SX: portrait canvas, split top/bottom horizontally
    // dualLayoutRatio controls the LARGER region (比例 = 较大区域的高度比例)
    // sxBackOnTop: YES → back gets the larger region, front gets the smaller
    //              NO  → front gets the larger region, back gets the smaller
    _backPreviewView.hidden = NO;
    _frontPreviewView.hidden = NO;
    CGFloat largerH  = h * self.dualLayoutRatio;      // user's slider ratio → larger region
    CGFloat smallerH = h * (1 - self.dualLayoutRatio); // remaining → smaller region
    if (self.sxBackOnTop) {
      // back on top (larger), front on bottom (smaller)
      _backPreviewView.frame  = CGRectMake(ox, oy, w, largerH);
      _frontPreviewView.frame = CGRectMake(ox, oy + largerH, w, smallerH);
    } else {
      // front on top (larger), back on bottom (smaller)
      _frontPreviewView.frame = CGRectMake(ox, oy, w, largerH);
      _backPreviewView.frame  = CGRectMake(ox, oy + largerH, w, smallerH);
    }

  } else if ([_currentLayout isEqualToString:@"pip_square"] || [_currentLayout isEqualToString:@"pip_circle"]) {
    // PiP: pipMainIsBack=YES → back=main(background), front=small-window(PiP)
    //         pipMainIsBack=NO  → front=main(background), back=small-window(PiP)
    CGFloat s = w * self.pipSize;
    CGFloat cx = w * self.pipPositionX;
    CGFloat cy = h * self.pipPositionY;
    // Clamp so pip stays within canvas
    cx = MAX(s / 2, MIN(w - s / 2, cx));
    cy = MAX(s / 2, MIN(h - s / 2, cy));
    CGRect pipRect = CGRectMake(cx - s / 2, cy - s / 2, s, s);

    if (self.pipMainIsBack) {
      // back = main (full canvas)
      _backPreviewView.hidden = NO;
      _backPreviewView.frame = canvas;
      // front = small window (PiP)
      _frontPreviewView.hidden = NO;
      _frontPreviewView.frame = CGRectMake(ox + cx - s / 2, oy + cy - s / 2, s, s);
    } else {
      // front = main (full canvas)
      _frontPreviewView.hidden = NO;
      _frontPreviewView.frame = canvas;
      // back = small window (PiP)
      _backPreviewView.hidden = NO;
      _backPreviewView.frame = CGRectMake(ox + cx - s / 2, oy + cy - s / 2, s, s);
    }

    if ([_currentLayout isEqualToString:@"pip_circle"]) {
      // Only the small window needs corner radius, main screen has sharp corners
      if (self.pipMainIsBack) {
        _frontPreviewView.layer.cornerRadius = s / 2; // front = small window
        _backPreviewView.layer.cornerRadius = 0;
      } else {
        _frontPreviewView.layer.cornerRadius = 0;
        _backPreviewView.layer.cornerRadius = s / 2; // back = small window
      }
    } else {
      _frontPreviewView.layer.cornerRadius = 8;
      _backPreviewView.layer.cornerRadius = 8;
    }

  } else {
    _frontPreviewView.hidden = YES;
    _backPreviewView.hidden = NO;
    _backPreviewView.frame = canvas;
  }

  // Update preview layer frames to match view frames (nil-safe: layers may not exist yet on first layout)
  if (_frontPreviewLayer) _frontPreviewLayer.frame = _frontPreviewView.bounds;
  if (_backPreviewLayer) _backPreviewLayer.frame = _backPreviewView.bounds;
  if (_singlePreviewLayer) _singlePreviewLayer.frame = [self targetPreviewViewForPosition:self.singleCameraPosition].bounds;
}

- (void)setSaveAspectRatio:(NSString *)saveAspectRatio {
  if (![_saveAspectRatio isEqualToString:saveAspectRatio]) {
    _saveAspectRatio = [saveAspectRatio copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateLayout];
    });
  }
}

#pragma mark - ObjC Bridge Methods

- (void)dc_startSession {
  NSLog(@"[DualCamera] dc_startSession called");
  [self internalStartSession];
}
- (void)dc_stopSession  { [self internalStopSession]; }
- (void)dc_takePhoto    { [self internalTakePhoto]; }
- (void)dc_startRecording { [self internalStartRecording]; }
- (void)dc_stopRecording  { [self internalStopRecording]; }

- (void)dc_flipCamera {
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self isDualLayout:self.currentLayout]) {
      if ([self.currentLayout isEqualToString:@"sx"] || [self.currentLayout isEqualToString:@"lr"]) {
        self.sxBackOnTop = !self.sxBackOnTop;
        NSLog(@"[DualCamera] flipCamera: sxBackOnTop=%d", self.sxBackOnTop);
      } else if ([self.currentLayout isEqualToString:@"pip_square"] || [self.currentLayout isEqualToString:@"pip_circle"]) {
        self.pipMainIsBack = !self.pipMainIsBack;
        NSLog(@"[DualCamera] flipCamera: pipMainIsBack=%d", self.pipMainIsBack);
      }
      [self updateLayout];
    } else {
      // Single-cam: switch front/back
      AVCaptureDevicePosition next = (self.singleCameraPosition == AVCaptureDevicePositionBack)
        ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
      dispatch_async(self.sessionQueue, ^{
        [self configureSingleSessionForPosition:next startRunning:YES];
      });
    }
  });
}

#pragma mark - Session Lifecycle

- (void)internalStartSession {
  NSLog(@"[DualCamera] internalStartSession called, layout=%@", self.currentLayout);
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  NSLog(@"[DualCamera] Camera auth status: %ld", (long)status);
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
                  mirrorVideo:NO
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

  // Back camera movie output — assign instance var BEFORE nil-check (prevents nil-assignment bug)
  if (ok) {
    if (![self addOutput:backMovieOutput
                 forPort:backVideoPort
               toSession:self.multiCamSession
                 failure:nil
             failureCode:nil]) {
      NSLog(@"[DualCamera] CRITICAL: Back movie output could not be added — back camera recording disabled");
      self.backMovieOutput = nil;
    } else {
      self.backMovieOutput = backMovieOutput;
    }
  }

  // Front camera movie output — assign instance var BEFORE nil-check
  if (ok) {
    AVCaptureMovieFileOutput *frontMovieOut = [[AVCaptureMovieFileOutput alloc] init];
    NSString *frontMovieFailure = nil;
    NSString *frontMovieFailureCode = nil;
    if (![self addOutput:frontMovieOut
                 forPort:frontVideoPort
               toSession:self.multiCamSession
                 failure:&frontMovieFailure
             failureCode:&frontMovieFailureCode]) {
      NSLog(@"[DualCamera] CRITICAL: Front movie output could not be added — front camera recording disabled: %@ (%@)", frontMovieFailure, frontMovieFailureCode);
      self.frontMovieOutput = nil;
    } else {
      self.frontMovieOutput = frontMovieOut;
    }
  }

  if (!self.backMovieOutput || !self.frontMovieOutput) {
    ok = NO;
    failure = [NSString stringWithFormat:@"Both movie outputs required for dual recording. back=%@ front=%@",
               self.backMovieOutput ? @"OK" : @"NIL",
               self.frontMovieOutput ? @"OK" : @"NIL"];
    failureCode = @"movie_output_init_failed";
  }

  // Audio → movie output connections (must be inside begin/commitConfiguration block)
  if (ok && self.audioInput) {
    [self addAudioConnectionToMovieOutput:self.audioInput output:self.backMovieOutput session:self.multiCamSession];
    [self addAudioConnectionToMovieOutput:self.audioInput output:self.frontMovieOutput session:self.multiCamSession];
  }

  // VideoDataOutput for WYSIWYG photo capture (front camera)
  // Use addOutputWithNoConnections: + manual connection for AVCaptureMultiCamSession
  if (ok) {
    self.frontVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.frontVideoDataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    [self.frontVideoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    if ([self.multiCamSession canAddOutput:self.frontVideoDataOutput]) {
      [self.multiCamSession addOutputWithNoConnections:self.frontVideoDataOutput];
      if (frontVideoPort) {
        AVCaptureConnection *conn = [[AVCaptureConnection alloc] initWithInputPorts:@[frontVideoPort] output:self.frontVideoDataOutput];
        if (conn.isVideoOrientationSupported) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
        if ([self.multiCamSession canAddConnection:conn]) {
          [self.multiCamSession addConnection:conn];
          NSLog(@"[DualCamera] frontVideoDataOutput connected to frontVideoPort (no mirror — WYSIWYG)");
        } else {
          NSLog(@"[DualCamera] frontVideoDataOutput connection failed");
        }
      } else {
        NSLog(@"[DualCamera] frontVideoDataOutput: frontVideoPort is nil");
      }
    } else {
      NSLog(@"[DualCamera] Cannot add frontVideoDataOutput to session");
    }
  }

  // VideoDataOutput for WYSIWYG photo capture (back camera)
  // Use same pattern as frontVideoDataOutput
  if (ok) {
    self.backVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.backVideoDataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    [self.backVideoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    if ([self.multiCamSession canAddOutput:self.backVideoDataOutput]) {
      [self.multiCamSession addOutputWithNoConnections:self.backVideoDataOutput];
      if (backVideoPort) {
        AVCaptureConnection *conn = [[AVCaptureConnection alloc] initWithInputPorts:@[backVideoPort] output:self.backVideoDataOutput];
        if (conn.isVideoOrientationSupported) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
        if ([self.multiCamSession canAddConnection:conn]) {
          [self.multiCamSession addConnection:conn];
          NSLog(@"[DualCamera] backVideoDataOutput connected to backVideoPort");
        } else {
          NSLog(@"[DualCamera] backVideoDataOutput connection failed — port may be in use");
        }
      }
    } else {
      NSLog(@"[DualCamera] Cannot add backVideoDataOutput to session");
    }
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
  NSLog(@"[DualCamera] Session config complete — backMovieOutput=%@ frontMovieOutput=%@",
        self.backMovieOutput ? @"OK" : @"NIL",
        self.frontMovieOutput ? @"OK" : @"NIL");
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

  // Configure device before creating input — apply exposure + zoom
  if ([device lockForConfiguration:&error]) {
    if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
      device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    }
    if (position == AVCaptureDevicePositionBack) {
      device.videoZoomFactor = _backZoomFactor;
    } else {
      device.videoZoomFactor = _frontZoomFactor;
    }
    [device unlockForConfiguration];
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

  // Apply the CORRECT zoom factor for THIS camera (not _backZoomFactor for all)
  CGFloat zoomFactor = (device.position == AVCaptureDevicePositionBack) ? _backZoomFactor : _frontZoomFactor;
  CGFloat clampedZoom = zoomFactor;
  if (clampedZoom < device.minAvailableVideoZoomFactor) {
    clampedZoom = device.minAvailableVideoZoomFactor;
  } else if (clampedZoom > device.maxAvailableVideoZoomFactor) {
    clampedZoom = device.maxAvailableVideoZoomFactor;
  }
  device.videoZoomFactor = clampedZoom;

  // 自动曝光：防止严重过曝/欠曝，保持画面亮度正常
  if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
    device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
  }
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

  // Ensure image is at origin (0,0) before saving to avoid partial crop
  CIImage *toSave = ciImage;
  if (ciImage.extent.origin.x != 0 || ciImage.extent.origin.y != 0) {
    CGFloat ox = -ciImage.extent.origin.x;
    CGFloat oy = -ciImage.extent.origin.y;
    toSave = [ciImage imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }

  CGImageRef cgImg = [ctx createCGImage:toSave fromRect:toSave.extent];
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
  } else if ([self.currentLayout isEqualToString:@"pip_square"] || [_currentLayout isEqualToString:@"pip_circle"]) {
    CGFloat s = canvasW * self.pipSize;
    CGFloat cx = canvasW * self.pipPositionX;
    CGFloat cy = canvasH * self.pipPositionY;
    cx = MAX(s / 2, MIN(canvasW - s / 2, cx));
    cy = MAX(s / 2, MIN(canvasH - s / 2, cy));
    CGRect pipRect = CGRectMake(cx - s / 2, cy - s / 2, s, s);
    BOOL isCircle = [self.currentLayout isEqualToString:@"pip_circle"];
    return [self compositePIPForPhotos:front back:back canvasW:canvasW canvasH:canvasH pipRect:pipRect isCircle:isCircle];
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

  // Front camera: fill right half (no mirror — WYSIWYG)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = halfH / frontOrigH;
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontScaledW = frontOrigW * frontScale;
  CGFloat frontCropX = MAX(0, (frontScaledW - halfW) / 2);
  CIImage *frontRightRaw = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, 0, halfW, halfH)];
  // Translate to right side (x=halfW), no mirror
  CIImage *frontRight = [frontRightRaw imageByApplyingTransform:CGAffineTransformMakeTranslation(halfW, 0)];

  CIImage *composited = [backLeft imageByCompositingOverImage:frontRight];
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

- (CIImage *)compositeSXForPhotos:(CIImage *)front back:(CIImage *)back
                         canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                           halfW:(CGFloat)halfW halfH:(CGFloat)halfH {
  // SX: front on top half, back on bottom half
  // Strategy: each half fills its area edge-to-edge, no gaps
  //
  //   y=0 ┌─────────────────────┐
  //       │  front (top half)   │ topH = halfH
  //       │  scale→crop by W    │
  //   y=halfH └─────────────────────┘ ←拼接线
  //       │  back  (bottom half)│
  //       │  scale→crop by W    │
  //   y=canvasH└─────────────────────┘

  // Front (top): scale by halfH → crop from top → no offset (starts at y=0)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = halfH / frontOrigH;                  // scale by HALF HEIGHT
  CIImage *frontScaled = [self scaledCIImage:front
                                     toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  // frontCropW = halfW; frontCropH = halfH; both cropped from top-left of scaled image
  CIImage *frontTop = [frontScaled imageByCroppingToRect:CGRectMake(0, 0, halfW, halfH)];
  // No mirror — raw front frame (WYSIWYG)

  // Back (bottom): scale by halfH → crop from top → offset by halfH
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = halfH / backOrigH;                     // scale by HALF HEIGHT
  CIImage *backScaled = [self scaledCIImage:back
                                    toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
  // backCropW = halfW; backCropH = halfH; cropped from top-left → translate down by halfH
  CIImage *backBottom = [backScaled imageByCroppingToRect:CGRectMake(0, 0, halfW, halfH)];
  CIImage *backBottomOffset = [backBottom imageByApplyingTransform:CGAffineTransformMakeTranslation(0, halfH)];

  CIImage *composited = [frontTop imageByCompositingOverImage:backBottomOffset];
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

- (CIImage *)compositePIPForPhotos:(CIImage *)front back:(CIImage *)back
                          canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                           pipRect:(CGRect)pipRect
                          isCircle:(BOOL)isCircle {
  // Back camera: scale to fill canvas (fill), use black on nil
  CIImage *backFull;
  if (!back) {
    backFull = [self blackCanvasSize:CGSizeMake(canvasW, canvasH)];
  } else {
    CGFloat backOrigW = back.extent.size.width;
    CGFloat backOrigH = back.extent.size.height;
    CGFloat backScale = MAX(canvasW / backOrigW, canvasH / backOrigH);
    CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
    CGFloat backCropX = MAX(0, (backScaled.extent.size.width - canvasW) / 2);
    CGFloat backCropY = MAX(0, (backScaled.extent.size.height - canvasH) / 2);
    backFull = [backScaled imageByCroppingToRect:CGRectMake(backCropX, backCropY, canvasW, canvasH)];
  }

  // Front camera: scale to fit pip area (use MIN to fit, not MAX/cover), position at pipRect
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = MIN(pipRect.size.width / frontOrigW, pipRect.size.height / frontOrigH);
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontCropX = MAX(0, (frontScaled.extent.size.width - pipRect.size.width) / 2);
  CGFloat frontCropY = MAX(0, (frontScaled.extent.size.height - pipRect.size.height) / 2);
  CIImage *frontCropped = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, frontCropY, pipRect.size.width, pipRect.size.height)];
  // Translate frontCropped to pipRect.origin (no mirror — WYSIWYG)
  CIImage *frontPlaced = [frontCropped imageByApplyingTransform:CGAffineTransformMakeTranslation(pipRect.origin.x, pipRect.origin.y)];

  // Apply circular mask for pip_circle only
  CIImage *frontFinal = frontPlaced;
  if (isCircle) {
    @autoreleasepool {
      @try {
        CGFloat s = pipRect.size.width;
        CGFloat centerX = pipRect.origin.x + s / 2.0;
        CGFloat centerY = pipRect.origin.y + s / 2.0;
        CIImage *circleMask = [self circleMaskAtCenter:CGPointMake(centerX, centerY)
                                              radius:s / 2.0
                                          extentSize:CGSizeMake(canvasW, canvasH)];
        CIImage *whiteCanvas = [self whiteCanvasSize:CGSizeMake(canvasW, canvasH)];
        CIImage *blended = [frontPlaced imageByApplyingFilter:@"CIBlendWithMask"
                                     withInputParameters:@{
                                       kCIInputBackgroundImageKey: whiteCanvas,
                                       kCIInputMaskImageKey: circleMask
                                     }];
        if (blended && blended.extent.size.width > 0 && blended.extent.size.height > 0) {
          frontFinal = blended;
        } else {
          NSLog(@"[DualCamera] compositePIPForPhotos: CIBlendWithMask invalid, using square");
        }
      } @catch (NSException *exception) {
        NSLog(@"[DualCamera] compositePIPForPhotos: circle mask exception=%@, falling back to square", exception);
        frontFinal = frontPlaced;
      }
    }
  }

  // Shift composited extent to origin (0,0) before returning
  CIImage *composited = [frontFinal imageByCompositingOverImage:backFull];
  CGFloat ox = -composited.extent.origin.x;
  CGFloat oy = -composited.extent.origin.y;
  if (ox != 0 || oy != 0) {
    composited = [composited imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
}

// Helper: circular white mask (alpha=1 inside circle, alpha=0 outside)
- (CIImage *)circleMaskAtCenter:(CGPoint)center radius:(CGFloat)radius extentSize:(CGSize)extentSize {
  CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
  [radialGradient setValue:@{
    kCIInputCenterKey: [CIVector vectorWithX:center.x Y:center.y],
    kCIInputRadius0Key: @(radius * 0.98),
    kCIInputRadius1Key: @(radius),
    @"inputColor0": [CIColor colorWithRed:1 green:1 blue:1 alpha:1],
    @"inputColor1": [CIColor colorWithRed:1 green:1 blue:1 alpha:0]
  } forKey:kCIInputImageKey];
  CIImage *mask = radialGradient.outputImage;
  CGFloat ox = -mask.extent.origin.x;
  CGFloat oy = -mask.extent.origin.y;
  if (ox != 0 || oy != 0) {
    mask = [mask imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }
  return mask;
}

- (CIImage *)whiteCanvasSize:(CGSize)size {
  CIFilter *colorGen = [CIFilter filterWithName:@"CIConstantColorGenerator"];
  [colorGen setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:1] forKey:kCIInputColorKey];
  CIImage *canvas = [colorGen.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
  CGFloat ox = -canvas.extent.origin.x;
  CGFloat oy = -canvas.extent.origin.y;
  if (ox != 0 || oy != 0) {
    canvas = [canvas imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }
  return canvas;
}

- (CIImage *)blackCanvasSize:(CGSize)size {
  CIFilter *colorGen = [CIFilter filterWithName:@"CIConstantColorGenerator"];
  [colorGen setValue:[CIColor colorWithRed:0 green:0 blue:0 alpha:1] forKey:kCIInputColorKey];
  CIImage *canvas = [colorGen.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
  CGFloat ox = -canvas.extent.origin.x;
  CGFloat oy = -canvas.extent.origin.y;
  if (ox != 0 || oy != 0) {
    canvas = [canvas imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }
  return canvas;
}

- (CIImage *)scaledCIImage:(CIImage *)image toSize:(CGSize)size {
  CGFloat scaleX = size.width / image.extent.size.width;
  CGFloat scaleY = size.height / image.extent.size.height;
  // Use CIAffineTransform to preserve correct aspect ratio
  CIFilter *transformFilter = [CIFilter filterWithName:@"CIAffineTransform"];
  [transformFilter setValue:image forKey:kCIInputImageKey];
  [transformFilter setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformMakeScale(scaleX, scaleY)] forKey:kCIInputTransformKey];
  CIImage *result = transformFilter.outputImage;
  if (!result) return image;
  // CIAffineTransform moves the extent origin; translate back to (0,0)
  CGFloat offsetX = -result.extent.origin.x;
  CGFloat offsetY = -result.extent.origin.y;
  if (offsetX != 0 || offsetY != 0) {
    result = [result imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];
  }
  return result;
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

- (CGAffineTransform)makeLayerTransformWithTargetRect:(CGRect)targetRect
                                         sourceSize:(CGSize)srcSize
                                 sourcePreferredTransform:(CGAffineTransform)srcTransform
                                              mirrored:(BOOL)mirrored {
  // Decompose the preferredTransform to find the rotation angle
  CGFloat angle = atan2(srcTransform.b, srcTransform.a); // rotation in radians
  CGFloat deg = angle * 180.0 / M_PI;
  BOOL isRotated90 = (fabs(fabs(deg) - 90.0) < 1.0);

  // Effective source frame size AFTER applying the preferredTransform
  CGFloat effW = srcSize.width;
  CGFloat effH = srcSize.height;
  if (isRotated90) {
    CGFloat tmp = effW; effW = effH; effH = tmp;
  }

  // Scale to fit the target rect (uniform fill)
  CGFloat scaleX = targetRect.size.width  / effW;
  CGFloat scaleY = targetRect.size.height / effH;
  CGFloat scale  = MAX(scaleX, scaleY);

  // Scaled dimensions
  CGFloat scaledW = effW * scale;
  CGFloat scaledH = effH * scale;

  // Center within target rect
  CGFloat tx = targetRect.origin.x + (targetRect.size.width  - scaledW) / 2.0;
  CGFloat ty = targetRect.origin.y + (targetRect.size.height - scaledH) / 2.0;

  // Build transform:
  // 1. Translate source center to origin
  // 2. Apply rotation (fixes portrait orientation)
  // 3. Apply horizontal mirror (flipX) if mirrored — flips left/right
  // 4. Scale to fit target
  // 5. Translate to target position
  CGAffineTransform t = CGAffineTransformMakeTranslation(srcSize.width / 2.0, srcSize.height / 2.0);
  t = CGAffineTransformRotate(t, angle);
  if (mirrored) {
    // flipX: mirror around the Y-axis (horizontal flip)
    t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(-1, 1));
  }
  t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(scale, scale));
  t = CGAffineTransformTranslate(t, tx - srcSize.width / 2.0, ty - srcSize.height / 2.0);
  return t;
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
    CGSize naturalSize = videoTracks.firstObject.naturalSize;
    CGAffineTransform t = videoTracks.firstObject.preferredTransform;
    CGFloat w = fabs(naturalSize.width * t.a + naturalSize.height * t.c);
    CGFloat h = fabs(naturalSize.width * t.b + naturalSize.height * t.d);
    if (w > 0 && h > 0) {
      return CGSizeMake(w, h);
    }
    if (naturalSize.width > 0 && naturalSize.height > 0) {
      return naturalSize;
    }
  }
  return CGSizeMake(1080, 1920);
}

- (NSString *)compositeDualVideosForCurrentLayout:(NSString *)frontPath backPath:(NSString *)backPath {
  NSURL *frontURL = [NSURL fileURLWithPath:frontPath];
  NSURL *backURL  = [NSURL fileURLWithPath:backPath];

  if (![[NSFileManager defaultManager] fileExistsAtPath:frontPath] ||
      ![[NSFileManager defaultManager] fileExistsAtPath:backPath]) {
    NSLog(@"[DualCamera] One of the recording files is missing — front=%@ back=%@",
          [[NSFileManager defaultManager] fileExistsAtPath:frontPath] ? @"EXISTS" : @"MISSING",
          [[NSFileManager defaultManager] fileExistsAtPath:backPath] ? @"EXISTS" : @"MISSING");
    return backPath;
  }

  AVURLAsset *frontAsset = [AVURLAsset assetWithURL:frontURL];
  AVURLAsset *backAsset  = [AVURLAsset assetWithURL:backURL];

  NSDictionary *frontAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:frontPath error:nil];
  NSDictionary *backAttrs  = [[NSFileManager defaultManager] attributesOfItemAtPath:backPath error:nil];
  NSLog(@"[DualCamera] Compositing — frontSize=%@KB backSize=%@KB frontNaturalSize=%@ backNaturalSize=%@",
        @([frontAttrs[NSFileSize] unsignedLongLongValue] / 1024),
        @([backAttrs[NSFileSize] unsignedLongLongValue] / 1024),
        NSStringFromCGSize([self videoSizeForAsset:frontAsset]),
        NSStringFromCGSize([self videoSizeForAsset:backAsset]));

  CMTime frontDuration = frontAsset.duration;
  CMTime backDuration  = backAsset.duration;
  CMTime duration = CMTimeMinimum(frontDuration, backDuration);

  // Canvas dimensions based on saveAspectRatio (9:16, 3:4, 1:1)
  // Always portrait: height >= width
  CGFloat canvasW, canvasH;
  if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
    canvasW = 1080; canvasH = 1920;
  } else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
    canvasW = 1440; canvasH = 1920;
  } else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
    canvasW = 1920; canvasH = 1920;
  } else {
    CGSize vs = [self videoSizeForAsset:frontAsset];
    canvasW = (vs.width >= vs.height) ? vs.height : vs.width;
    canvasH = (vs.width >= vs.height) ? vs.width  : vs.height;
  }

  // Get video tracks for preferredTransform info (before composition track creation)
  NSArray<AVAssetTrack *> *frontVideoTracks = [frontAsset tracksWithMediaType:AVMediaTypeVideo];
  NSArray<AVAssetTrack *> *backVideoTracks  = [backAsset tracksWithMediaType:AVMediaTypeVideo];

  // Log raw preferredTransform for debugging
  CGAffineTransform frontPT = frontVideoTracks.count > 0 ? frontVideoTracks.firstObject.preferredTransform : CGAffineTransformIdentity;
  CGAffineTransform backPT  = backVideoTracks.count  > 0 ? backVideoTracks.firstObject.preferredTransform  : CGAffineTransformIdentity;
  NSLog(@"[DualCamera] VideoCompositing — layout=%@ saveAspectRatio=%@ canvas=%.0fx%.0f sxBackOnTop=%d frontPT=[%.1f,%.1f,%.1f,%.1f,%.0f,%.0f] backPT=[%.1f,%.1f,%.1f,%.1f,%.0f,%.0f]",
        self.currentLayout, self.saveAspectRatio, canvasW, canvasH, self.sxBackOnTop,
        frontPT.a, frontPT.b, frontPT.c, frontPT.d, frontPT.tx, frontPT.ty,
        backPT.a,  backPT.b,  backPT.c,  backPT.d,  backPT.tx,  backPT.ty);

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

  AVMutableCompositionTrack *frontVideoTrack = nil;
  AVMutableCompositionTrack *backVideoTrack  = nil;
  CGAffineTransform frontSrcTransform = CGAffineTransformIdentity;
  CGAffineTransform backSrcTransform  = CGAffineTransformIdentity;

  if (frontVideoTracks.count > 0) {
    frontVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                              preferredTrackID:kCMPersistentTrackID_Invalid];
    [frontVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                           ofTrack:frontVideoTracks.firstObject
                            atTime:kCMTimeZero
                             error:nil];
    frontSrcTransform = frontVideoTracks.firstObject.preferredTransform;
    frontVideoTrack.preferredTransform = frontSrcTransform;
  }

  if (backVideoTracks.count > 0) {
    backVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                              preferredTrackID:kCMPersistentTrackID_Invalid];
    [backVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration)
                           ofTrack:backVideoTracks.firstObject
                            atTime:kCMTimeZero
                             error:nil];
    backSrcTransform = backVideoTracks.firstObject.preferredTransform;
    backVideoTrack.preferredTransform = backSrcTransform;
  }

  // Build video composition
  AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoComposition];
  videoComp.renderSize = CGSizeMake(canvasW, canvasH);
  videoComp.frameDuration = CMTimeMake(1, 30);

  CMTimeRange timeRange = CMTimeRangeMake(kCMTimeZero, duration);

  // Source natural sizes from asset tracks
  CGSize backRawSize   = backVideoTracks.count  > 0 ? backVideoTracks.firstObject.naturalSize  : CGSizeMake(1440, 1920);
  CGSize frontRawSize  = frontVideoTracks.count > 0 ? frontVideoTracks.firstObject.naturalSize : CGSizeMake(1920, 1440);

  // Transform parameters: T(tx,ty) × S(sx,sy) maps raw → canvas
  // Back PT=[0,1,-1,0,1440,0], Front PT=[0,1,1,0,0,1920], Canvas=1080×1920
  // LR: back fills LEFT, front fills RIGHT
  // SX: back/top or front/top, split by sxBackOnTop

  CGFloat leftW  = canvasW * self.dualLayoutRatio;
  CGFloat rightW = canvasW * (1 - self.dualLayoutRatio);
  CGFloat largeH = canvasH * self.dualLayoutRatio;

  CGFloat lrBackSx  = leftW  / backRawSize.height;    // 0.375
  CGFloat lrBackSy  = canvasH / backRawSize.height;   // 1.333
  CGFloat lrBackTx  = 0.0;
  CGFloat lrBackTy  = 0.0;

  CGFloat lrFrontSx = rightW / frontRawSize.height;    // 0.375
  CGFloat lrFrontSy = canvasH / frontRawSize.height;   // 1.333
  CGFloat lrFrontTx = rightW / 2.0;                  // 540
  CGFloat lrFrontTy = 0.0;

  CGFloat sxBackSx  = canvasW / backRawSize.height;
  CGFloat sxBackSy  = canvasH / backRawSize.height;
  CGFloat sxBackTx  = 0.0;
  CGFloat sxBackTy  = self.sxBackOnTop ? 0.0 : largeH;

  CGFloat sxFrontSx = canvasW / frontRawSize.height;
  CGFloat sxFrontSy = canvasH / frontRawSize.height;
  CGFloat sxFrontTx = 0.0;
  CGFloat sxFrontTy = self.sxBackOnTop ? largeH : 0.0;

  NSLog(@"[DualCamera] Transform — LR: backS=(%.4f,%.4f) backT=(%.1f,%.1f) frontS=(%.4f,%.4f) frontT=(%.1f,%.1f)",
        lrBackSx, lrBackSy, lrBackTx, lrBackTy, lrFrontSx, lrFrontSy, lrFrontTx, lrFrontTy);
  NSLog(@"[DualCamera] Transform — SX: backS=(%.4f,%.4f) backT=(%.1f,%.1f) frontS=(%.4f,%.4f) frontT=(%.1f,%.1f) sxBackOnTop=%d",
        sxBackSx, sxBackSy, sxBackTx, sxBackTy, sxFrontSx, sxFrontSy, sxFrontTx, sxFrontTy, self.sxBackOnTop);

  if ([self.currentLayout isEqualToString:@"lr"]) {
    CGAffineTransform backTransform = CGAffineTransformMakeTranslation(lrBackTx, lrBackTy);
    backTransform = CGAffineTransformConcat(backTransform, CGAffineTransformMakeScale(lrBackSx, lrBackSy));

    CGAffineTransform frontTransform = CGAffineTransformMakeTranslation(lrFrontTx, lrFrontTy);
    frontTransform = CGAffineTransformConcat(frontTransform, CGAffineTransformMakeScale(lrFrontSx, lrFrontSy));

    AVMutableVideoCompositionLayerInstruction *frontLayer = [self layerForTrack:frontVideoTrack];
    AVMutableVideoCompositionLayerInstruction *backLayer  = [self layerForTrack:backVideoTrack];
    if (backLayer)  [backLayer  setTransform:backTransform  atTime:kCMTimeZero];
    if (frontLayer) [frontLayer setTransform:frontTransform atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = @[
      (id)(backLayer  ?: (id)[NSNull null]),
      (id)(frontLayer ?: (id)[NSNull null])
    ];
    videoComp.instructions = @[instruction];

  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    CGAffineTransform backTransform = CGAffineTransformMakeTranslation(sxBackTx, sxBackTy);
    backTransform = CGAffineTransformConcat(backTransform, CGAffineTransformMakeScale(sxBackSx, sxBackSy));

    CGAffineTransform frontTransform = CGAffineTransformMakeTranslation(sxFrontTx, sxFrontTy);
    frontTransform = CGAffineTransformConcat(frontTransform, CGAffineTransformMakeScale(sxFrontSx, sxFrontSy));

    AVMutableVideoCompositionLayerInstruction *topLayer, *bottomLayer;
    CGAffineTransform topTransform, bottomTransform;
    if (self.sxBackOnTop) {
      bottomLayer = frontVideoTrack ? [self layerForTrack:frontVideoTrack] : nil;
      bottomTransform = frontTransform;
      topLayer = backVideoTrack ? [self layerForTrack:backVideoTrack] : nil;
      topTransform = backTransform;
    } else {
      bottomLayer = backVideoTrack ? [self layerForTrack:backVideoTrack] : nil;
      bottomTransform = backTransform;
      topLayer = frontVideoTrack ? [self layerForTrack:frontVideoTrack] : nil;
      topTransform = frontTransform;
    }

    if (bottomLayer) [bottomLayer setTransform:bottomTransform atTime:kCMTimeZero];
    if (topLayer)    [topLayer    setTransform:topTransform    atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = @[
      (id)(bottomLayer ?: (id)[NSNull null]),
      (id)(topLayer    ?: (id)[NSNull null])
    ];
    videoComp.instructions = @[instruction];

  } else {
    // pip_square / pip_circle: back full screen, front as corner overlay
    CGFloat s = canvasW * self.pipSize;
    CGFloat pipX = canvasW * self.pipPositionX - s / 2;
    CGFloat pipY = canvasH * self.pipPositionY - s / 2;

    // Back: fills entire canvas (same as SX back)
    CGAffineTransform backTransform = CGAffineTransformMakeTranslation(0, 0);
    backTransform = CGAffineTransformConcat(backTransform, CGAffineTransformMakeScale(sxBackSx, sxBackSy));

    // Front: pip window
    CGFloat pipFrontSx = s / (frontRawSize.height);
    CGFloat pipFrontSy = s / (frontRawSize.height);
    CGAffineTransform frontTransform = CGAffineTransformMakeTranslation(pipX, pipY);
    frontTransform = CGAffineTransformConcat(frontTransform, CGAffineTransformMakeScale(pipFrontSx, pipFrontSy));

    AVMutableVideoCompositionLayerInstruction *backLayer  = [self layerForTrack:backVideoTrack];
    AVMutableVideoCompositionLayerInstruction *frontLayer = [self layerForTrack:frontVideoTrack];
    if (backLayer)  [backLayer  setTransform:backTransform  atTime:kCMTimeZero];
    if (frontLayer) [frontLayer setTransform:frontTransform atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = @[
      (id)(backLayer  ?: (id)[NSNull null]),
      (id)(frontLayer ?: (id)[NSNull null])
    ];
    videoComp.instructions = @[instruction];
  }

  CGFloat fDeg = atan2(frontSrcTransform.b, frontSrcTransform.a) * 180.0 / M_PI;
  CGFloat bDeg = atan2(backSrcTransform.b,  backSrcTransform.a)  * 180.0 / M_PI;
  NSLog(@"[DualCamera] Compositing — layout=%@ canvas=%.0fx%.0f frontRaw=%.0fx%.0f backRaw=%.0fx%.0f frontRot=%.0fdeg backRot=%.0fdeg frontDur=%.2fs backDur=%.2fs",
        self.currentLayout, canvasW, canvasH,
        frontRawSize.width, frontRawSize.height,
        backRawSize.width, backRawSize.height,
        fDeg, bDeg,
        CMTimeGetSeconds(frontDuration), CMTimeGetSeconds(backDuration));

  NSString *outPath = [self documentsPathWithPrefix:@"dual_composited_"];
  self.videoExportSession =
    [[AVAssetExportSession alloc] initWithAsset:composition
                                presetName:AVAssetExportPresetHighestQuality];
  self.videoExportSession.outputURL = [NSURL fileURLWithPath:outPath];
  self.videoExportSession.outputFileType = AVFileTypeMPEG4;
  self.videoExportSession.videoComposition = videoComp;

  NSLog(@"[DualCamera] Exporting to %@ (renderSize=%.0fx%.0f, layers=%lu)",
        outPath, canvasW, canvasH,
        (unsigned long)videoComp.instructions.firstObject ? 0UL : 0UL);

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
  // Capture screen size on main thread BEFORE dispatching to background
  __block CGSize canvasSizeForPhoto;
  dispatch_sync(dispatch_get_main_queue(), ^{
    canvasSizeForPhoto = self.bounds.size;
  });

  dispatch_async(self.sessionQueue, ^{
    @autoreleasepool {
      if (!self.isConfigured) return;

      if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
        // WYSIWYG: grab latest frames from VideoDataOutput and composite
        CIImage *frontFrame;
        CIImage *backFrame;
        @synchronized(self) {
          frontFrame = self.latestFrontFrame;
          backFrame = self.latestBackFrame;
        }

        NSLog(@"[DualCamera] internalTakePhoto WYSIWYG — frontFrame=%@ backFrame=%@ layout=%@",
              frontFrame ? @"OK" : @"NIL",
              backFrame ? @"OK" : @"NIL",
              self.currentLayout);

        if (!frontFrame || !backFrame) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self emitError:@"Camera not ready, please try again"];
          });
          return;
        }

        // Calculate save canvas: use screen width × 3 for high resolution
        // This matches device camera native resolution (e.g. 1440px on iPhone)
        CGFloat refW = canvasSizeForPhoto.width * 3.0;
        CGSize saveCanvas;
        if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
          saveCanvas = CGSizeMake(refW, round(refW * 16.0 / 9.0));
        } else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
          saveCanvas = CGSizeMake(refW, round(refW * 4.0 / 3.0));
        } else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
          saveCanvas = CGSizeMake(refW, refW);
        } else {
          saveCanvas = CGSizeMake(refW, round(refW * 16.0 / 9.0));
        }

        NSLog(@"[DualCamera] internalTakePhoto — front size=%@ back size=%@ canvasSizeForPhoto=%@ saveCanvas=%@",
              NSStringFromCGSize(frontFrame.extent.size),
              NSStringFromCGSize(backFrame.extent.size),
              NSStringFromCGSize(canvasSizeForPhoto),
              NSStringFromCGSize(saveCanvas));

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          @autoreleasepool {
            // Use canvasSizeForPhoto to determine split ratio (matches preview layout)
            CGFloat saveRatio = self.dualLayoutRatio > 0 ? self.dualLayoutRatio : 0.5;
            CIImage *composited = [self compositeFront:frontFrame back:backFrame
                                              toCanvas:saveCanvas
                                         canvasForRatio:canvasSizeForPhoto
                                            splitRatio:saveRatio];
            NSLog(@"[DualCamera] internalTakePhoto — composited extent=%@ (expect W=%.0f H=%.0f)",
                  NSStringFromCGRect(composited.extent), saveCanvas.width, saveCanvas.height);
            NSString *path = [self saveCIImageAsJPEG:composited];
            NSLog(@"[DualCamera] internalTakePhoto — saved path=%@", path);
            dispatch_async(dispatch_get_main_queue(), ^{
              if (path) {
                [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
              } else {
                [self emitError:@"Failed to save photo"];
              }
            });
          }
        });
      } else {
        // Single-cam: use photo output for full-resolution
        AVCapturePhotoOutput *output = [self photoOutputForCurrentLayout];
        if (!output) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self emitError:@"Photo output not available"];
          });
          return;
        }
        @try {
          AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
          settings.flashMode = AVCaptureFlashModeOff;
          [output capturePhotoWithSettings:settings delegate:self];
        } @catch (NSException *exception) {
          NSLog(@"[DualCamera] internalTakePhoto exception: %@", exception);
          dispatch_async(dispatch_get_main_queue(), ^{
            [self emitError:[NSString stringWithFormat:@"Photo capture failed: %@", exception.reason ?: @"Unknown error"]];
          });
        }
      }
    }
  });
}

#pragma mark - WYSIWYG Capture Helpers

- (CGSize)canvasSizeForSaveAspectRatio:(NSString *)aspectRatio {
  // Use a fixed reference width to ensure consistent output regardless of device orientation.
  // The canvas height is derived from the selected aspect ratio.
  CGFloat refW = 390.0;  // fixed reference width (portrait iPhone width in points)
  if ([aspectRatio isEqualToString:@"9:16"]) {
    return CGSizeMake(refW, round(refW * 16.0 / 9.0));
  } else if ([aspectRatio isEqualToString:@"3:4"]) {
    return CGSizeMake(refW, round(refW * 4.0 / 3.0));
  } else if ([aspectRatio isEqualToString:@"1:1"]) {
    return CGSizeMake(refW, refW);
  }
  return CGSizeMake(refW, round(refW * 16.0 / 9.0));
}

- (CIImage *)compositeFront:(CIImage *)front back:(CIImage *)back
                  toCanvas:(CGSize)canvasSize
             canvasForRatio:(CGSize)previewCanvas
                 splitRatio:(CGFloat)ratio {
  CGFloat canvasW = canvasSize.width;
  CGFloat canvasH = canvasSize.height;
  CGFloat effectiveRatio = ratio > 0 ? ratio : 0.5;

  if ([self.currentLayout isEqualToString:@"lr"]) {
    // LR: sxBackOnTop=YES → back on left, front on right
    //     sxBackOnTop=NO  → front on left, back on right
    CGFloat leftW  = canvasW * effectiveRatio;
    CGFloat rightW = canvasW * (1 - effectiveRatio);
    if (self.sxBackOnTop) {
      return [self compositeLRFront:front back:back canvasW:canvasW canvasH:canvasH leftW:leftW rightW:rightW];
    } else {
      return [self compositeLRFront:front back:back canvasW:canvasW canvasH:canvasH leftW:rightW rightW:leftW];
    }
  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    // SX: sxBackOnTop=YES → back on top (primary), front on bottom
    //     sxBackOnTop=NO  → front on top (primary), back on bottom
    CGFloat primaryH   = canvasH * effectiveRatio;
    CGFloat secondaryH = canvasH * (1 - effectiveRatio);
    if (self.sxBackOnTop) {
      // back on top, front on bottom
      // compositeSXFront: first param = "front" slot (top), second = "back" slot (bottom)
      return [self compositeSXFront:back back:front canvasW:canvasW canvasH:canvasH topH:primaryH bottomH:secondaryH];
    } else {
      // front on top, back on bottom
      return [self compositeSXFront:front back:back canvasW:canvasW canvasH:canvasH topH:primaryH bottomH:secondaryH];
    }
  } else if ([self.currentLayout isEqualToString:@"pip_square"] || [self.currentLayout isEqualToString:@"pip_circle"]) {
    // PiP: pipMainIsBack=YES → back=main(background), front=small-window
    //       pipMainIsBack=NO  → front=main(background), back=small-window
    CGFloat s = canvasW * self.pipSize;
    CGFloat cx = canvasW * self.pipPositionX;
    CGFloat cy = canvasH * self.pipPositionY;
    cx = MAX(s / 2, MIN(canvasW - s / 2, cx));
    cy = MAX(s / 2, MIN(canvasH - s / 2, cy));
    CGRect pipRect = CGRectMake(cx - s / 2, cy - s / 2, s, s);
    NSLog(@"[DualCamera] compositeFront PiP — pipMainIsBack=%d canvasW=%.0f canvasH=%.0f pipRect=%@",
          self.pipMainIsBack, canvasW, canvasH, NSStringFromCGRect(pipRect));
    BOOL isCircle = [self.currentLayout isEqualToString:@"pip_circle"];
    if (self.pipMainIsBack) {
      // back=main, front=small-window
      return [self compositePIPFront:front back:back canvasW:canvasW canvasH:canvasH pipRect:pipRect isCircle:isCircle];
    } else {
      // front=main, back=small-window — swap front/back arguments
      return [self compositePIPFront:front back:back canvasW:canvasW canvasH:canvasH pipRect:pipRect isCircle:isCircle];
    }
  }

  // Default: return back camera
  return [self scaledCIImage:back toSize:canvasSize];
}

- (CIImage *)compositeLRFront:(CIImage *)front back:(CIImage *)back
                      canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                        leftW:(CGFloat)leftW rightW:(CGFloat)rightW {
  NSLog(@"[DualCamera] compositeLRFront — front orig=%@ back orig=%@ canvasW=%.0f canvasH=%.0f leftW=%.0f rightW=%.0f",
        NSStringFromCGSize(front.extent.size), NSStringFromCGSize(back.extent.size),
        canvasW, canvasH, leftW, rightW);

  // Back (left): fill by height, crop from left edge so origin is (0,0)
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = canvasH / backOrigH;
  CGSize backTargetSize = CGSizeMake(backOrigW * backScale, backOrigH * backScale);
  CIImage *backScaled = [self scaledCIImage:back toSize:backTargetSize];
  NSLog(@"[DualCamera] compositeLRFront — backScaled extent=%@ (expect W=%.0f H=%.0f)",
        NSStringFromCGRect(backScaled.extent), backTargetSize.width, backTargetSize.height);
  // Crop from origin (0,0) to avoid coordinate offset issues
  CIImage *backLeft = [backScaled imageByCroppingToRect:CGRectMake(0, 0, leftW, canvasH)];
  NSLog(@"[DualCamera] compositeLRFront — backLeft extent=%@", NSStringFromCGRect(backLeft.extent));

  // Front (right): fill by height, crop, translate to right side (x=leftW)
  // No mirror — raw front camera frame matches preview (videoMirrored=NO)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = canvasH / frontOrigH;
  CGSize frontTargetSize = CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale);
  CIImage *frontScaled = [self scaledCIImage:front toSize:frontTargetSize];
  NSLog(@"[DualCamera] compositeLRFront — frontScaled extent=%@ (expect W=%.0f H=%.0f)",
        NSStringFromCGRect(frontScaled.extent), frontTargetSize.width, frontTargetSize.height);
  // Crop front portion (centered) from scaled image
  CGFloat frontScaledW = frontOrigW * frontScale;
  CGFloat frontCropX = MAX(0, (frontScaledW - rightW) / 2);
  CIImage *frontRight = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, 0, rightW, canvasH)];
  NSLog(@"[DualCamera] compositeLRFront — frontRight extent=%@ cropX=%.0f", NSStringFromCGRect(frontRight.extent), frontCropX);
  // Translate front: first to origin (0,0), then to right side (x=leftW)
  CIImage *frontRightOffset = [frontRight imageByApplyingTransform:CGAffineTransformMakeTranslation(-frontCropX, 0)];
  frontRightOffset = [frontRightOffset imageByApplyingTransform:CGAffineTransformMakeTranslation(leftW, 0)];
  NSLog(@"[DualCamera] compositeLRFront — frontRightOffset extent=%@", NSStringFromCGRect(frontRightOffset.extent));

  // Composite: back on left (0..leftW), front on right (leftW..canvasW)
  CIImage *result = [frontRightOffset imageByCompositingOverImage:backLeft];
  NSLog(@"[DualCamera] compositeLRFront — result extent=%@ (expect W=%.0f H=%.0f)",
        NSStringFromCGRect(result.extent), canvasW, canvasH);
  return result;
}

- (CIImage *)compositeSXFront:(CIImage *)front back:(CIImage *)back
                      canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                        topH:(CGFloat)topH bottomH:(CGFloat)bottomH {
  // Front (top): fill by width, crop from top, no mirror (raw frame)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = canvasW / frontOrigW;
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(canvasW, frontOrigH * frontScale)];
  CIImage *frontTop = [frontScaled imageByCroppingToRect:CGRectMake(0, 0, canvasW, topH)];

  // Back (bottom): fill by width, crop from top, translate down by topH
  CGFloat backOrigW = back.extent.size.width;
  CGFloat backOrigH = back.extent.size.height;
  CGFloat backScale = canvasW / backOrigW;
  CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(canvasW, backOrigH * backScale)];
  CIImage *backBottomRaw = [backScaled imageByCroppingToRect:CGRectMake(0, 0, canvasW, bottomH)];
  CIImage *backBottom = [backBottomRaw imageByApplyingTransform:CGAffineTransformMakeTranslation(0, topH)];

  return [frontTop imageByCompositingOverImage:backBottom];
}

- (CIImage *)compositePIPFront:(CIImage *)front back:(CIImage *)back
                       canvasW:(CGFloat)canvasW canvasH:(CGFloat)canvasH
                       pipRect:(CGRect)pipRect
                      isCircle:(BOOL)isCircle {
  // Back: fill canvas (scale to cover, crop excess)
  // If back is nil (VideoDataOutput not delivering frames), use black background
  CIImage *backFull;
  if (!back) {
    backFull = [self blackCanvasSize:CGSizeMake(canvasW, canvasH)];
  } else {
    CGFloat backOrigW = back.extent.size.width;
    CGFloat backOrigH = back.extent.size.height;
    CGFloat backScale = MAX(canvasW / backOrigW, canvasH / backOrigH);
    CIImage *backScaled = [self scaledCIImage:back toSize:CGSizeMake(backOrigW * backScale, backOrigH * backScale)];
    CGFloat backCropX = MAX(0, (backScaled.extent.size.width - canvasW) / 2);
    CGFloat backCropY = MAX(0, (backScaled.extent.size.height - canvasH) / 2);
    backFull = [backScaled imageByCroppingToRect:CGRectMake(backCropX, backCropY, canvasW, canvasH)];
  }

  // Front: fit into pip rect, position at pipRect (no mirror — raw frame matches preview)
  CGFloat frontOrigW = front.extent.size.width;
  CGFloat frontOrigH = front.extent.size.height;
  CGFloat frontScale = MIN(pipRect.size.width / frontOrigW, pipRect.size.height / frontOrigH);
  CIImage *frontScaled = [self scaledCIImage:front toSize:CGSizeMake(frontOrigW * frontScale, frontOrigH * frontScale)];
  CGFloat frontCropX = MAX(0, (frontScaled.extent.size.width - pipRect.size.width) / 2);
  CGFloat frontCropY = MAX(0, (frontScaled.extent.size.height - pipRect.size.height) / 2);
  CIImage *frontCropped = [frontScaled imageByCroppingToRect:CGRectMake(frontCropX, frontCropY, pipRect.size.width, pipRect.size.height)];
  // Translate frontCropped to pipRect.origin (no mirror — WYSIWYG)
  CIImage *frontPlaced = [frontCropped imageByApplyingTransform:CGAffineTransformMakeTranslation(pipRect.origin.x, pipRect.origin.y)];

  // Apply circular mask for pip_circle only
  // Wrap in @try/@catch + @autoreleasepool to prevent EXC_BAD_ACCESS crashes
  CIImage *frontFinal = frontPlaced;
  if (isCircle) {
    @autoreleasepool {
      @try {
        CGFloat s = pipRect.size.width;
        CGFloat centerX = pipRect.origin.x + s / 2.0;
        CGFloat centerY = pipRect.origin.y + s / 2.0;
        CIImage *circleMask = [self circleMaskAtCenter:CGPointMake(centerX, centerY)
                                              radius:s / 2.0
                                          extentSize:CGSizeMake(canvasW, canvasH)];
        CIImage *whiteCanvas = [self whiteCanvasSize:CGSizeMake(canvasW, canvasH)];
        CIImage *blended = [frontPlaced imageByApplyingFilter:@"CIBlendWithMask"
                                      withInputParameters:@{
                                        kCIInputBackgroundImageKey: whiteCanvas,
                                        kCIInputMaskImageKey: circleMask
                                      }];
        if (blended && blended.extent.size.width > 0 && blended.extent.size.height > 0) {
          frontFinal = blended;
        } else {
          NSLog(@"[DualCamera] compositePIPFront: CIBlendWithMask returned invalid image, using fallback");
        }
      } @catch (NSException *exception) {
        NSLog(@"[DualCamera] compositePIPFront: circle mask exception=%@, falling back to square", exception);
        // Fallback: no circular mask, use square pip
        frontFinal = frontPlaced;
      }
    }
  }

  // Shift composited extent to origin (0,0) before returning
  CIImage *composited = [frontFinal imageByCompositingOverImage:backFull];
  CGFloat ox = -composited.extent.origin.x;
  CGFloat oy = -composited.extent.origin.y;
  if (ox != 0 || oy != 0) {
    composited = [composited imageByApplyingTransform:CGAffineTransformMakeTranslation(ox, oy)];
  }
  return [composited imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
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
  // Capture bounds on main thread BEFORE dispatching to background queue
  // (UIView.bounds must not be accessed from background threads)
  __block CGSize canvasSizeForRecording;
  dispatch_sync(dispatch_get_main_queue(), ^{
    canvasSizeForRecording = self.bounds.size;
  });

  dispatch_async(self.sessionQueue, ^{
    if (!self.isConfigured) return;

    if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
      // Canvas size captured from main thread
      self.canvasSizeAtRecording = canvasSizeForRecording;

      // Dual-cam: record both simultaneously
      if (self.isDualRecordingActive) return; // prevent double-start
      self.isDualRecordingActive = YES;
      self.backRecordingFinished = NO;
      self.frontRecordingFinished = NO;

      self.backRecordingPath = [self tempPathWithPrefix:@"dual_back_"];
      self.frontRecordingPath = [self tempPathWithPrefix:@"dual_front_"];

      NSLog(@"[DualCamera] startRecording — backMovieOutput=%@ frontMovieOutput=%@",
            self.backMovieOutput ? @"OK" : @"NIL",
            self.frontMovieOutput ? @"OK" : @"NIL");

      if (!self.backMovieOutput || !self.frontMovieOutput) {
        self.isDualRecordingActive = NO;
        [self emitRecordingError:@"Dual recording unavailable — one or both camera outputs not configured."];
        return;
      }

      [self.backMovieOutput startRecordingToOutputFileURL:
        [NSURL fileURLWithPath:self.backRecordingPath] recordingDelegate:self];
      [self.frontMovieOutput startRecordingToOutputFileURL:
        [NSURL fileURLWithPath:self.frontRecordingPath] recordingDelegate:self];
    } else {
      // Single-cam
      self.canvasSizeAtRecording = canvasSizeForRecording;
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
  @try {
    if (error) {
      [self emitError:error.localizedDescription];
      return;
    }

    NSData *data = [photo fileDataRepresentation];
    if (!data) {
      [self emitError:@"Failed to get photo data"];
      return;
    }

    // Single-cam: save directly from photo data
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        @try {
          NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
          NSString *filename = [NSString stringWithFormat:@"photo_%@.jpg", @((NSInteger)[[NSDate date] timeIntervalSince1970])];
          NSString *path = [documentsPath stringByAppendingPathComponent:filename];
          NSError *writeError = nil;
          [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
          dispatch_async(dispatch_get_main_queue(), ^{
            if (writeError) {
              [self emitError:writeError.localizedDescription];
            } else {
              [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
            }
          });
        } @catch (NSException *exception) {
          NSLog(@"[DualCamera] captureOutput photo inner exception: %@", exception);
          dispatch_async(dispatch_get_main_queue(), ^{
            [self emitError:[NSString stringWithFormat:@"Photo save failed: %@", exception.reason ?: @"Unknown error"]];
          });
        }
      }
    });
  } @catch (NSException *exception) {
    NSLog(@"[DualCamera] captureOutput delegate outer exception: %@", exception);
    [self emitError:[NSString stringWithFormat:@"Photo capture delegate failed: %@", exception.reason ?: @"Unknown error"]];
  }
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
        @autoreleasepool {
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
        }
      });
    }
    return;
  }

  // Single-cam mode: emit directly
  [self emitRecordingFinished:fileURL.absoluteString];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pixelBuffer) return;

  CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
  if (!ciImage) return;

  // Debug: log which output received the frame
  BOOL isFrontOutput = (output == self.frontVideoDataOutput);
  BOOL isBackOutput = (output == self.backVideoDataOutput);
  NSLog(@"[DualCamera] captureOutput: output=%p isFront=%d isBack=%d frontVDO=%p backVDO=%p frameSize=%@",
        (__bridge void *)output, isFrontOutput, isBackOutput,
        (__bridge void *)self.frontVideoDataOutput, (__bridge void *)self.backVideoDataOutput,
        NSStringFromCGSize(ciImage.extent.size));

  // Store raw frames (no mirror applied — WYSIWYG: save what preview shows)
  if (output == self.frontVideoDataOutput) {
    @synchronized(self) {
      self.latestFrontFrame = ciImage;
    }
  } else {
    @synchronized(self) {
      self.latestBackFrame = ciImage;
    }
  }
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
