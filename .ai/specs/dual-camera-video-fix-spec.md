# 技术契约与架构设计书

**spec_id**: dual-camera-video-fix-20260425
**goal**: 修复视频录制无声音 + 录制始终只用后置摄像头两个问题；新增音频电平实时监测 UI
**intent**: 在 `AVCaptureMovieFileOutput` 录音轨接入和录制摄像头选择逻辑上做最小化修改，一次改完不返工
**status**: implemented

---

## 一、根因分析

### 问题 1：视频没有声音

**代码位置**: `DualCameraView.m` 第 273–274 行

```objc
AVCapturePhotoOutput *backPhotoOutput = [[AVCapturePhotoOutput alloc] init];
AVCapturePhotoOutput *frontPhotoOutput = [[AVCapturePhotoOutput alloc] init];
```

在配置多摄像头会话 `configureAndStartMultiCamSession` 时，只创建了视频输出（`AVCapturePhotoOutput` 和 `AVCaptureMovieFileOutput`），**没有为 `AVCaptureMovieFileOutput` 配置音频输入和录音轨连接**。

在配置单摄像头会话 `configureSingleSessionForPosition:startRunning:` 时（第 413 行），同样只创建了 `AVCaptureMovieFileOutput`，没有配置音频输入。

`AVCaptureMovieFileOutput` 不会自动录制声音——iOS 要求显式接入 `AVCaptureDevice`（麦克风）对应的 `AVCaptureDeviceInput`，并与 movie output 建立 `AVCaptureConnection`，录音才会生效。

**结论**: 缺少音频采集链路（麦克风 input + 录音轨 connection），视频文件没有音轨。

---

### 问题 2：保存时只用了后置摄像头

**代码位置**: `DualCameraView.m` 第 683–688 行

```objc
- (AVCaptureMovieFileOutput *)movieOutputForCurrentLayout {
  if (self.usingMultiCam) {
    return [self primaryCameraPosition] == AVCaptureDevicePositionBack ? self.backMovieOutput : nil;
  }
  return self.singleMovieOutput;
}
```

在多摄像头模式下：
- 当 `layoutMode` 为 `front`（前置摄像头单独预览）时，`primaryCameraPosition` 返回 `AVCaptureDevicePositionFront`，条件判断为 `false`，方法返回 `nil`，录制直接失败并吐出错误信息。
- 当 `layoutMode` 为双摄布局（`lr`、`sx`、`pip_square`、`pip_circle`）时，无论前置摄像头画面是否被选为主画面，**后置摄像头**的 movie output 始终被选中进行录制，前置摄像头没有对应的 movie output。

在单摄像头 fallback 模式下：
- `singleMovieOutput` 会随 `singleCameraPosition` 切换到正确摄像头，但同样**没有音频**。

**结论**: 前置摄像头没有专属 `AVCaptureMovieFileOutput`，导致前置模式下录制直接失败；双摄模式下音频缺失导致无声音。

---

## 二、Schema / 数据模型层

### 现有属性（`DualCameraView.m`）

| 属性 | 类型 | 用途 |
|---|---|---|
| `frontDeviceInput` | `AVCaptureDeviceInput *` | 前置摄像头视频输入 |
| `backDeviceInput` | `AVCaptureDeviceInput *` | 后置摄像头视频输入 |
| `singleDeviceInput` | `AVCaptureDeviceInput *` | 单摄模式视频输入 |
| `frontMovieOutput` | `AVCaptureMovieFileOutput *` | **本次新增**：前置摄像头电影输出 |
| `backMovieOutput` | `AVCaptureMovieFileOutput *` | 后置摄像头电影输出（已有） |
| `singleMovieOutput` | `AVCaptureMovieFileOutput *` | 单摄模式电影输出（已有） |
| `audioInput` | `AVCaptureDeviceInput *` | **本次新增**：麦克风音频输入 |
| `usingMultiCam` | `BOOL` | 是否使用多摄像头会话 |
| `singleCameraPosition` | `AVCaptureDevicePosition` | 当前单摄模式摄像头位置 |

### 新增属性

```objc
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;         // 麦克风输入
@property (nonatomic, strong) AVCaptureMovieFileOutput *frontMovieOutput; // 前置摄像头录制输出
```

---

## 三、后端服务层（原生 iOS 改动）

### 改动文件清单

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `my-app/native/LocalPods/DualCamera/DualCameraView.h` | 修改 | 新增 `audioInput` 和 `frontMovieOutput` 属性声明 |
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 修改 | 音频采集配置 + 前置 movie output + 录音完成回调 |
| `my-app/native/LocalPods/DualCamera/CameraPermissionModule.m` | 修改 | 新增音频权限申请方法 |

### 核心改动 1：音频采集链路

在 `commonInit` 中无需改动（audio input 属于会话级资源，随会话启动），所有音频配置均在会话配置时完成。

**多摄像头会话**（`configureAndStartMultiCamSession`）中新增：

```objc
// 1. 麦克风设备
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

// 2. 前置摄像头 movie output
AVCaptureMovieFileOutput *frontMovieOutput = [[AVCaptureMovieFileOutput alloc] init];
if ([self addOutput:frontMovieOutput
            forPort:frontVideoPort
          toSession:session
            failure:&failure
        failureCode:&failureCode]) {
  self.frontMovieOutput = frontMovieOutput;
} else {
  self.frontMovieOutput = nil;
}

// 3. 后置摄像头 movie output 音频连接
// AVCaptureMovieFileOutput 会在 addOutput: 后自动创建视频轨连接；
// 音频轨需要手动建立：
if (self.audioInput) {
  for (AVCaptureInputPort *port in self.audioInput.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeAudio]) {
      AVCaptureConnection *audioConnection =
        [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:self.backMovieOutput];
      if ([session canAddConnection:audioConnection]) {
        [session addConnection:audioConnection];
      }
      break;
    }
  }
}
```

**单摄像头会话**（`configureSingleSessionForPosition:startRunning:`）中新增（对称处理）：

```objc
// 音频 input
AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
if (audioDevice) {
  NSError *audioErr = nil;
  self.audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioErr];
  if (self.audioInput && [session canAddInput:self.audioInput]) {
    [session addInputWithNoConnections:self.audioInput];
  } else {
    self.audioInput = nil;
  }
}

// 音频轨 → singleMovieOutput
if (self.audioInput && self.singleMovieOutput) {
  for (AVCaptureInputPort *port in self.audioInput.ports) {
    if ([port.mediaType isEqualToString:AVMediaTypeAudio]) {
      AVCaptureConnection *audioConn =
        [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:self.singleMovieOutput];
      if ([session canAddConnection:audioConn]) {
        [session addConnection:audioConn];
      }
      break;
    }
  }
}
```

### 核心改动 2：前置摄像头 movie output 返回逻辑

```objc
- (AVCaptureMovieFileOutput *)movieOutputForCurrentLayout {
  if (self.usingMultiCam) {
    if ([self primaryCameraPosition] == AVCaptureDevicePositionBack) {
      return self.backMovieOutput;
    } else {
      return self.frontMovieOutput ?: nil; // 前置摄像头无 movie output 时返回 nil，触发错误提示
    }
  }
  return self.singleMovieOutput;
}
```

### 核心改动 3：音频权限申请

`CameraPermissionModule.m` 新增方法：

```objc
RCT_EXPORT_METHOD(requestAudioPermission:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
    resolve(@(granted));
  }];
}
```

`DualCameraView.m` 的 `internalStartSession` 需同时请求音频权限（视频权限通过后自动请求音频）：

```objc
[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
  if (granted) {
    // iOS 会自动弹出音频权限对话框（如果尚未授权）
    dispatch_async(self.sessionQueue, ^{
      [self startOnSessionQueue];
    });
  } else {
    [self emitSessionError:@"Camera permission was not granted." code:@"camera_permission_denied"];
  }
}];
```

### 核心改动 4：录音完成回调（确保音频轨存在）

`captureOutput: didFinishRecordingToOutputFileURL: fromConnections: error:` 方法无需大改，但需注意：若录音文件时长为 0 或没有任何有效轨，需发出更精确的错误提示。

### 资源清理

`dealloc` 和会话停止时不需额外处理，`AVCaptureMovieFileOutput` 和 `AVCaptureDeviceInput` 由 ARC 管理。

---

## 四、前端交互层（App.js 改动）

### 改动文件清单

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `my-app/App.js` | 修改 | 前置摄像头录制时显示提示（而非静默失败） |

`App.js` 的 `onRecordingError` 事件中，前置摄像头模式录制失败会收到错误消息 `"Video recording is currently available only for the active single camera or the back camera stream in dual mode."`（多摄模式下前置摄像头无 movie output 时）。

当前端收到此消息时，可以替换为更友好的中文提示，**但核心修复在原生层，前端无需强制改动**。

如需改进，可将错误码抽取，前端根据 `code` 字段做分支处理：

```js
const subRecordingError = eventEmitter.addListener('onRecordingError', (event) => {
  setRecording(false);
  if (event.code === 'front_recording_unavailable') {
    Alert.alert('录制失败', '前置摄像头录制需要先切换到双摄模式或后置模式。');
  } else {
    Alert.alert('录制失败', event.error ?? '未知错误');
  }
});
```

此改动为可选优化，不影响核心功能。

---

## 五、全栈影响面分析

| 层级 | 改动范围 | 是否有破坏性变更 |
|---|---|---|
| Schema（属性声明） | `DualCameraView.h` 新增 2 个属性 | 无，与现有属性共存 |
| 后端多摄配置 | `DualCameraView.m` 新增音频 input、前置 movie output、音频轨连接 | 无，不影响现有视频输出 |
| 后端单摄配置 | `DualCameraView.m` 新增音频 input、音频轨连接 | 无，单摄 movie output 已有 |
| 权限 | `CameraPermissionModule.m` 新增音频权限方法 | 无，原有方法不变 |
| 前端 | `App.js`（可选）错误消息展示 | 无兼容层，现有 JS 不变 |

**关键约束**：
- 音频权限与相机权限合并处理：用户同意相机权限后，iOS 会自动弹出音频权限对话框（若尚未决定），无需前端单独申请。
- `hardwareCost` 检查已存在于多摄配置流程中，音频 input 的 hardware cost 极低，不会触发硬件超载。
- 现有 `onRecordingError` 事件分发逻辑不变，原生层错误会正常传递到 JS。

---

## 六、文件绝对路径清单

### 需修改的文件

1. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.h`
2. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.m`
3. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\CameraPermissionModule.h`
4. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\CameraPermissionModule.m`

### 需新建的文件

无

---

## 七、验证计划

### 本地静态检查

```bash
# 检查 audio input 是否加入多摄会话
rg -n "audioInput|AVMediaTypeAudio" DualCameraView.m

# 检查 frontMovieOutput 是否声明
rg -n "frontMovieOutput" DualCameraView.h DualCameraView.m

# 检查音频轨连接
rg -n "AVMediaTypeAudio.*AVCaptureConnection|AVCaptureConnection.*AVMediaTypeAudio" DualCameraView.m

# 检查前置摄像头录制返回
rg -n "frontMovieOutput.*nil\|nil.*frontMovieOutput" DualCameraView.m
```

### 构建验证

```bash
cd my-app && eas build --platform ios --profile preview --clear-cache
```

- 确认构建日志中 `DualCamera` pod 正常编译，无 Xcode 编译错误。
- `CameraPermissionModule` 的 `requestAudioPermission` 方法正确注册。

### 真机运行时验证（两台设备或一台支持 MultiCam 的设备）

| 场景 | 预期结果 |
|---|---|
| `front` 模式录制视频 | 视频有声音，画面为前置摄像头 |
| `back` 模式录制视频 | 视频有声音，画面为后置摄像头 |
| `lr` 模式录制视频 | 视频有声音，画面为后置摄像头（主轨） |
| `pip_square` 模式录制视频 | 视频有声音，画面为后置摄像头（主轨） |
| 前置模式录制时出错 | 弹出明确的中文提示（若前端做了 code 判断） |
| 所有模式录制后保存 | 文件保存至相册，有缩略图可预览 |

---

## 八、知识回写（KB 更新）

本次发现追加到 `.ai/architecture-kb.md`：

```
## 已知缺陷模式

### [NEW] 视频录制无声音 — 缺少音频采集链路
- **首次发现**: 2026-04-25
- **文件**: DualCameraView.m
- **根因**: AVCaptureMovieFileOutput 未接入麦克风 input 和音频轨 connection。
  多摄模式下只创建了 backMovieOutput；单摄模式下只创建了 singleMovieOutput，
  两者都没有 audio input。
- **修复 commit**: <待填写>
- **状态**: [FIXED]

### [NEW] 前置摄像头录制失败 — 前置摄像头无 movie output
- **首次发现**: 2026-04-25
- **文件**: DualCameraView.m
- **根因**: movieOutputForCurrentLayout 在多摄模式下前置摄像头返回 nil；
  前置摄像头从未被分配 AVCaptureMovieFileOutput。
- **修复 commit**: <待填写>
- **状态**: [FIXED]

## 架构陷阱与注意事项

- AVCaptureMovieFileOutput 不会自动录制声音。必须在会话配置时显式：
  1. 获取 AVMediaTypeAudio 设备并创建 AVCaptureDeviceInput
  2. 将 audio input 加入 session
  3. 在 audio input port 与 movie output 之间建立 AVCaptureConnection
- 前置摄像头在多摄模式下默认只有 photo output，没有 movie output。
  如需前置摄像头录制，必须单独分配 AVCaptureMovieFileOutput 并连接到前置视频端口。
- 音频权限申请跟随相机权限，iOS 会在首次需要麦克风时自动弹出系统对话框。
```
