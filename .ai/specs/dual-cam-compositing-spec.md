# 技术契约与架构设计书

**spec_id**: dual-cam-compositing-20260425
**goal**: 在双摄模式下（lr/sx/pip_square/pip_circle），将前置和后置摄像头画面合成为一张照片/一段视频保存
**intent**: 为双摄布局引入 `AVCaptureVideoDataOutput` + `AVAssetWriter` 管线，对照片和视频分别设计最小化合成方案
**status**: implemented

---

## 一、根因分析：为什么当前只保存后置画面

当前捕获架构基于 `AVCapturePhotoOutput` 和 `AVCaptureMovieFileOutput`，这两个输出**每个只能接入一路视频输入**。

```
当前架构：
  backInput  ──→  backPhotoOutput  ──→  照片（后置）
  frontInput ──→  frontPhotoOutput  ──→  (未被使用)
                         ↓
              photoOutputForCurrentLayout
                         ↓
              双摄模式下只选 backPhotoOutput，前置被丢弃
```

`photoOutputForCurrentLayout` 在多摄模式下永远返回 `backPhotoOutput`（第 750-754 行），前置摄像头的 `frontPhotoOutput` 从未被 `capturePhotoWithSettings:delegate:` 调用，所以前置画面永远不会进入最终文件。

视频同理：`movieOutputForCurrentLayout` 只选一路 movie output。

**要同时保存两个摄像头，必须把两个独立的画面合并（compositing）。**

---

## 二、两种方案对比

### 方案 A：先拍后合（同步双拍 → 内存合成）—— 推荐用于照片

```
摄像头A ──→ PhotoOutput ──→ CMSampleBuffer
摄像头B ──→ PhotoOutput ──→ CMSampleBuffer
                                    ↓
                          双图加载到 CIImage
                                    ↓
                          Core Image 合成 + 布局叠加
                                    ↓
                          导出 JPEG → 保存相册
```

**优点**：简单，两个 photo output 各自独立采集，合成在 CPU/GPU 完成
**缺点**：两次拍摄有微小时间差（毫秒级），快速运动场景可能有轻微重影
**适用**：照片模式（静态场景为主）

### 方案 B：`AVCaptureVideoDataOutput` × 2 + `AVAssetWriter`（实时合成）—— 用于视频

```
backInput ──→ VideoDataOutput ──┐
                                 ├─→ AVAssetWriter (合成)
frontInput ──→ VideoDataOutput ──┘
       ↑
   audioInput ──→ AVAssetWriter (音频轨)
```

**优点**：真正的实时合成，音视频同步写入同一文件
**缺点**：
1. `AVCaptureMultiCamSession` 不支持同时添加两个 `AVCaptureVideoDataOutput` 到同一个 session（Apple 文档明确限制每个 session 最多一个 video data output）
2. 绕过方案需要两个独立 `AVCaptureSession`，但无法真正同步前后摄像头帧（时间戳会漂移）

**适用**：视频模式（需权衡实现成本）

### 方案 C：`AVCaptureMultiCamSession` + 帧合并（折中）—— 推荐用于视频

```
backInput ──→ VideoDataOutput (back)
       │
       └──→ backMovieOutput (保留用于预览/兼容)
              ↑                    ↑
              │              AVCaptureVideoDataOutput
              │                   只能有一个!
              │
frontInput ──→ frontMovieOutput
                      ↑
                      └──→ AVCaptureVideoDataOutput ──→ ??? (冲突)
```

经查 Apple 文档：`AVCaptureMultiCamSession` 中每个 session **最多添加一个 `AVCaptureVideoDataOutput`**。因此两个 camera 都无法同时用 video data output。

**最终推荐方案**：

| 媒体类型 | 方案 | 原因 |
|---|---|---|
| **照片** | 方案 A（同步双拍 → CIImage 合成） | `AVCapturePhotoOutput` 支持同时注册两个 delegate，双图合成无技术障碍 |
| **视频** | 方案 B 变体：录两路 → 后处理合并 | 录制时同时录到两个 `.mov` 文件，录制完成后在后台线程用 `AVAssetExportSession` 合并音频 + 画面为一个文件 |

---

## 三、数据模型层（Schema）

### 新增属性

| 属性 | 类型 | 用途 |
|---|---|---|
| `frontVideoDataOutput` | `AVCaptureVideoDataOutput *` | 前置摄像头视频帧输出（用于双摄模式） |
| `backVideoDataOutput` | `AVCaptureVideoDataOutput *` | 后置摄像头视频帧输出 |
| `_pendingDualBuffers` | `NSDictionary *` | 存储双摄像头最新帧（key: `@"front"`, `@"back"`） |
| `_pendingDualPhotos` | `NSDictionary *` | 存储双摄像头待合成照片 |
| `_isCapturingDualPhoto` | `BOOL` | 是否正在拍摄双摄照片（防止重复触发） |
| `_isCompositing` | `BOOL` | 是否正在合成视频（防止重复触发） |

### 照片合成逻辑

```
internalTakePhoto (多摄模式 + 双摄布局):
  1. 标记 _isCapturingDualPhoto = YES
  2. [backPhotoOutput capturePhotoWithSettings:... delegate:self]
  3. [frontPhotoOutput capturePhotoWithSettings:... delegate:self]
  4. 两次 callback 分别收到 backImage / frontImage
  5. 两张图都收到后，执行合成 → 导出 → 保存
```

### 视频合成逻辑

```
internalStartRecording (多摄模式 + 双摄布局):
  1. 创建 AVAssetWriter (主文件，音视频合并)
  2. backMovieOutput.startRecording(...)  ← 录后置（含音频）
  3. frontMovieOutput.startRecording(...) ← 录前置
  4. 各自独立录制

internalStopRecording:
  1. 停止两个 movie output
  2. 等待两个录制文件完成
  3. 启动后台合成线程：AVAssetExportSession 合并
     - 视频轨 A: frontMovieOutput 文件（前置画面）
     - 视频轨 B: backMovieOutput 文件（后置画面 + 音频）
     - 输出: 单一合成视频文件
  4. 合成完成后删除两个原始文件
  5. 将合成文件路径发给 JS
```

---

## 四、后端服务层（原生 iOS 改动）

### 目标文件

- `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.h` — 新增属性声明
- `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.m` — 核心重写
- `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraEventEmitter.h` — 新增事件
- `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraEventEmitter.m` — 新增事件

### 核心改动 1：双摄照片合成

`captureOutput: didFinishProcessingPhoto: error:` 改为按 output 区分处理：

```objc
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

  CIImage *ciImage = [CIImage imageWithData:data];
  if (!ciImage) {
    [self emitError:@"Failed to create image"];
    return;
  }

  NSString *key = (output == self.backPhotoOutput) ? @"back" : @"front";
  self._pendingDualPhotos[key] = ciImage;

  // 两张图都收到后，执行合成
  if (self._pendingDualPhotos[@"back"] && self._pendingDualPhotos[@"front"]) {
    CIImage *backImg = self._pendingDualPhotos[@"back"];
    CIImage *frontImg = self._pendingDualPhotos[@"front"];
    [self._pendingDualPhotos removeAllObjects];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      CIImage *composited = [self compositeDualPhotos:frontImg back:backImg];
      NSString *path = [self saveCIImage:composited];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (path) {
          [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
        } else {
          [self emitError:@"Failed to composite photo"];
        }
        self._isCapturingDualPhoto = NO;
      });
    });
    return;
  }

  // 单摄模式：直接保存（保持原有行为）
  if (!self._isCapturingDualPhoto) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"dual_photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
    [data writeToFile:path atomically:YES];
    [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
  }
}
```

**`compositeDualPhotos:back:` 方法**（核心合成逻辑）：

```objc
- (CIImage *)compositeDualPhotos:(CIImage *)front back:(CIImage *)front {
  CGFloat w = front.extent.size.width;  // 屏幕宽
  CGFloat h = front.extent.size.height; // 屏幕高

  CIImage *result;

  if ([self.currentLayout isEqualToString:@"lr"]) {
    // 左右分屏：前置占右半，后置占左半
    result = [self compositeLR:front back:back w:w h:h];

  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    // 上下分屏：前置占上，后置占下
    result = [self compositeSX:front back:back w:w h:h];

  } else if ([self.currentLayout isEqualToString:@"pip_square"] ||
             [self.currentLayout isEqualToString:@"pip_circle"]) {
    // PiP：后置全屏，前置小窗
    CGFloat s = MIN(w, h) * 0.28;
    CGFloat pipX = w - s - 16;
    CGFloat pipY = h - s - 160;
    result = [self compositePIP:front back:back
                        pipRect:CGRectMake(pipX, pipY, s, s)
                        w:w h:h];

  } else {
    // 非双摄布局：只返回主画面
    result = back;
  }

  return result;
}

- (CIImage *)compositeLR:(CIImage *)front back:(CIImage *)back w:(CGFloat)w h:(CGFloat)h {
  CIImage *frontScaled = [front imageByScalingToSize:CGSizeMake(w / 2, h)];
  CIImage *backScaled  = [back  imageByScalingToSize:CGSizeMake(w / 2, h)];

  frontScaled = [frontScaled imageByApplyingOrientation:6]; // 前置镜像修正
  frontScaled = [frontScaled imageByCroppingToRect:CGRectMake(0, 0, w / 2, h)];
  backScaled  = [backScaled imageByCroppingToRect:CGRectMake(0, 0, w / 2, h)];

  CIImage *rightHalf = [frontScaled imageByTransform:
    CGAffineTransformMakeTranslation(w / 2, 0)];
  return [[backScaled imageByCompositingOverImage:rightHalf]
    imageByCroppingToRect:CGRectMake(0, 0, w, h)];
}

- (CIImage *)compositeSX:(CIImage *)front back:(CIImage *)back w:(CGFloat)w h:(CGFloat)h {
  CIImage *frontScaled = [front imageByScalingToSize:CGSizeMake(w, h / 2)];
  frontScaled = [frontScaled imageByApplyingOrientation:6]; // 前置镜像修正
  frontScaled = [frontScaled imageByCroppingToRect:CGRectMake(0, 0, w, h / 2)];

  CIImage *backScaled = [back imageByScalingToSize:CGSizeMake(w, h / 2)];
  backScaled = [backScaled imageByCroppingToRect:CGRectMake(0, 0, w, h / 2)];
  backScaled = [backScaled imageByTransform:
    CGAffineTransformMakeTranslation(0, h / 2)];

  return [[frontScaled imageByCompositingOverImage:backScaled]
    imageByCroppingToRect:CGRectMake(0, 0, w, h)];
}

- (CIImage *)compositePIP:(CIImage *)front back:(CIImage *)back
                  pipRect:(CGRect)pip w:(CGFloat)w h:(CGFloat)h {
  CIImage *backFull = [back imageByScalingToSize:CGSizeMake(w, h)];

  CIImage *pipScaled = [front imageByScalingToSize:CGSizeMake(pip.size.width, pip.size.height)];
  pipScaled = [pipScaled imageByApplyingOrientation:6]; // 前置镜像修正
  pipScaled = [pipScaled imageByCroppingToRect:
    CGRectMake(0, 0, pip.size.width, pip.size.height)];

  CGFloat scaleX = pip.origin.x / (w - pip.size.width);
  CGFloat scaleY = pip.origin.y / (h - pip.size.height);

  return [[pipScaled imageByCompositingOverImage:backFull]
    imageByCroppingToRect:CGRectMake(0, 0, w, h)];
}
```

### 核心改动 2：双摄视频后处理合成

录制时同时触发两个 movie output，停止后触发后台合并：

```objc
- (void)internalStartRecording {
  dispatch_async(self.sessionQueue, ^{
    if (!self.isUsingMultiCamDualLayout) {
      // 单摄或非双摄布局：使用原有单路录制逻辑
      [self startSingleRecording];
      return;
    }

    // 双摄布局：同时录制两路
    self._backRecordingPath = [self tempPathWithPrefix:@"dual_back_"];
    self._frontRecordingPath = [self tempPathWithPrefix:@"dual_front_"];

    [self.backMovieOutput startRecordingToOutputFileURL:
      [NSURL fileURLWithPath:self._backRecordingPath] recordingDelegate:self];
    [self.frontMovieOutput startRecordingToOutputFileURL:
      [NSURL fileURLWithPath:self._frontRecordingPath] recordingDelegate:self];
  });
}

- (void)internalStopRecording {
  dispatch_async(self.sessionQueue, ^{
    if (!self._backRecordingPath || !self._frontRecordingPath) {
      // 单路录制
      AVCaptureMovieFileOutput *output = [self activeRecordingOutput];
      if (output.isRecording) [output stopRecording];
      return;
    }

    // 停止双路录制
    [self.backMovieOutput stopRecording];
    [self.frontMovieOutput stopRecording];
  });
}

- (void)captureOutput:(AVCaptureFileOutput *)output
    didFinishRecordingToOutputFileAtURL:(NSURL *)fileURL
                        fromConnections:(NSArray *)connections
                                  error:(NSError *)error {
  if (error) {
    [self emitRecordingError:error.localizedDescription];
    return;
  }

  // 记录哪个 output 完成
  if (output == self.backMovieOutput) {
    self._backRecordingFinished = YES;
  } else if (output == self.frontMovieOutput) {
    self._frontRecordingFinished = YES;
  }

  // 两路都完成后，触发合成
  if (self._backRecordingFinished && self._frontRecordingFinished) {
    self._backRecordingFinished = NO;
    self._frontRecordingFinished = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
      NSString *composited = [self compositeDualVideos:self._frontRecordingPath
                                                 backPath:self._backRecordingPath];
      // 删除原始文件
      [[NSFileManager defaultManager] removeItemAtPath:self._frontRecordingPath error:nil];
      [[NSFileManager defaultManager] removeItemAtPath:self._backRecordingPath error:nil];
      self._frontRecordingPath = nil;
      self._backRecordingPath = nil;

      dispatch_async(dispatch_get_main_queue(), ^{
        if (composited) {
          [self emitRecordingFinished:[NSString stringWithFormat:@"file://%@", composited]];
        } else {
          [self emitRecordingError:@"Failed to composite video"];
        }
        self._isCompositing = NO;
      });
    });
  }
}
```

**`compositeDualVideos:backPath:` 方法**：

```objc
- (NSString *)compositeDualVideos:(NSString *)frontPath backPath:(NSString *)backPath {
  NSURL *frontURL = [NSURL fileURLWithPath:frontPath];
  NSURL *backURL  = [NSURL fileURLWithPath:backPath];

  AVURLAsset *frontAsset = [AVURLAsset assetWithURL:frontURL];
  AVURLAsset *backAsset  = [AVURLAsset assetWithURL:backURL];

  AVMutableComposition *composition = [AVMutableComposition composition];

  // 音频轨：使用后置视频的音频（backMovieOutput 含音频）
  if (backAsset.hasAudioTrack) {
    AVAudioTrack *audioTrack = [backAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                              preferredTrackID:kCMPersistentTrackID_Invalid];
    // ... 音轨处理
  }

  // 前置画面轨（缩放 + 镜像 + 定位）
  AVMutableVideoCompositionLayerInstruction *frontLayerInstr =
    [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:frontTrack];

  // 后置画面轨（缩放 + 定位）
  AVMutableVideoCompositionLayerInstruction *backLayerInstr =
    [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:backTrack];

  // 根据布局设置变换（CGAffineTransform）
  // lr: 前置右半，后置左半
  // sx: 前置上，前置下半
  // pip: 前置小窗，后置全屏

  AVMutableVideoCompositionInstruction *instruction =
    [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, backAsset.duration);
  instruction.layerInstructions = @[backLayerInstr, frontLayerInstr];

  AVMutableVideoComposition *videoComp = [AVMutableVideoComposition videoComposition];
  videoComp.renderSize = CGSizeMake(screenW, screenH);
  videoComp.instructions = @[instruction];

  NSString *outPath = [self tempPathWithPrefix:@"dual_composited_"];
  AVAssetExportSession *exportSession =
    [[AVAssetExportSession alloc] initWithAsset:composition
                                  presetName:AVAssetExportPresetHighestQuality];
  exportSession.outputURL = [NSURL fileURLWithPath:outPath];
  exportSession.outputFileType = AVFileTypeMPEG4;
  exportSession.videoComposition = videoComp;

  [exportSession exportAsynchronouslyWithCompletionHandler:^{
    // 导出完成，outPath 即为最终文件
  }];

  return outPath;
}
```

### 核心改动 3：内部状态判断方法

```objc
- (BOOL)isUsingMultiCamDualLayout {
  return self.usingMultiCam && [self isDualLayout:self.currentLayout];
}
```

---

## 五、事件层（DualCameraEventEmitter）

### 新增事件

| 事件名 | 内容 | 用途 |
|---|---|---|
| `onDualCaptureStarted` | `{}` | 双摄媒体开始捕获，JS 可显示"正在合成..." |
| `onDualCaptureProgress` | `{progress: 0-1}` | 合成进度（可选） |
| `onDualCaptureCompleted` | `{uri: string}` | 合成完成，JS 保存到相册 |

### 修改事件

| 事件名 | 修改内容 |
|---|---|
| `onPhotoSaved` | 双摄照片合成完成后发出，包含完整 URI |
| `onRecordingFinished` | 双摄视频合成完成后发出，包含完整 URI |

---

## 六、前端交互层（App.js）

### 改动文件

- `E:\MyCameraApp\my-app\App.js`

### 改动内容

在 `subRecordingFinished` / `subPhotoSaved` 的回调中，由于原生现在返回的是合成后的单文件路径，**JS 端无需任何改动**——原有保存逻辑完全兼容。

可选增强：在合成期间前端显示一个进度遮罩（类似 `savingOverlay`）：

```jsx
const [compositing, setCompositing] = useState(false);

const subRecordingFinished = eventEmitter.addListener('onRecordingFinished', async (event) => {
  setCompositing(false);
  // ... 原有保存逻辑
});
```

---

## 七、全栈影响面分析

| 层级 | 改动范围 | 破坏性变更 |
|---|---|---|
| Schema（属性） | `DualCameraView.h/.m` 新增 6 个属性、4 个路径变量 | 无，与现有属性共存 |
| 后端拍照 | `captureOutput: didFinishProcessingPhoto:` 大改，按 output 区分 | **有**：原有单摄照片路径生成逻辑需保留 |
| 后端录制 | `internalStartRecording/stopRecording` 大改 | **有**：双摄录制使用不同路径，单摄路径走原有分支 |
| 后端合成 | 新增 `compositeDualPhotos:back:`、`compositeDualVideos:backPath:` 等方法 | 无新破坏 |
| 事件 | `DualCameraEventEmitter` 新增 3 个事件 | 无，原有事件分发不变 |
| 前端 | App.js 基本无需改动 | **无** |

### 关键约束

1. **双摄拍照合成在主线程之外执行**，避免阻塞 UI
2. **双摄视频合成在后台线程执行**（`QOS_CLASS_BACKGROUND`），完成后回到主线程通知 JS
3. **内存管理**：双摄照片合成完成后立即释放 `_pendingDualPhotos`
4. **错误恢复**：合成失败时至少保留后置摄像头文件，通过 `onRecordingError` 告知 JS
5. **`AVAssetExportSession` 是异步的**，需要等待导出完成后才能删除原始文件
6. **`AVCaptureMultiCamSession` 最多一个 `VideoDataOutput`**：因此视频合成采用后处理方案而非实时合成

---

## 八、文件绝对路径清单

### 需修改的文件

1. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.h` — 新增属性声明
2. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.m` — 核心重写
3. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraEventEmitter.h` — 新增事件声明
4. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraEventEmitter.m` — 新增事件实现

### 需新建的文件

无

---

## 九、验证计划

### 本地静态检查

```bash
rg -n "isUsingMultiCamDualLayout|compositeDualPhotos|compositeDualVideos|AVAssetExportSession" DualCameraView.m
rg -n "AVCaptureVideoDataOutput" DualCameraView.m  # 确认此方法不再使用
```

### 构建验证

```bash
cd my-app && eas build --platform ios --profile preview --clear-cache
```

### 真机验证矩阵

| 布局 | 拍照 | 视频 |
|---|---|---|
| `lr` | 左右各半，无镜像，画面比例正确 | 左右合成，音频正常 |
| `sx` | 上下各半，无镜像 | 上下合成，音频正常 |
| `pip_square` | 后置全屏，前置右下小窗，有圆角 | 同照片布局 |
| `pip_circle` | 后置全屏，前置右下圆形小窗 | 同照片布局 |
| `back` | 单摄（原有行为） | 单摄（原有行为） |
| `front` | 单摄（原有行为） | 单摄（原有行为） |

---

## 十、知识回写（KB）

追加到 `.ai/architecture-kb.md`：

```
### 双摄媒体合成 — AVCaptureMovieFileOutput 单路限制
- **首次发现**: 2026-04-25
- **spec**: dual-cam-compositing-20260425
- `AVCapturePhotoOutput` 可以多次调用 `capturePhotoWithSettings:delegate:` 捕获多路画面，无限制。
- `AVCaptureMovieFileOutput` 同一 session 只能有一个录制进行中。
- `AVCaptureMultiCamSession` 最多添加一个 `AVCaptureVideoDataOutput`。
- 因此双摄视频合成方案：同时录两路 `.mov`，录制完成后用 `AVAssetExportSession` 后处理合并。
- 双摄照片合成方案：用 Core Image (CIImage) 在内存中合成，绕过 `capturePhoto` delegate 合并问题。
```

---

## 十一、Scope 边界

### 明确在范围内
- 双摄布局（lr/sx/pip_square/pip_circle）下照片合成
- 双摄布局下视频合成（后处理方式）
- 单摄模式（back/front）保持原有行为不变

### 明确在范围外
- **实时视频合成**（`AVAssetWriter` 实时推流）：`AVCaptureMultiCamSession` 限制使此方案不可行
- **双摄同步帧**：无硬件同步保证，后处理合并视频可能有毫秒级时间差
- **音频轨合成**：使用后置摄像头的音频（更清晰），前置音频丢弃
- **视频合成进度条**：可选优化，不影响核心功能
