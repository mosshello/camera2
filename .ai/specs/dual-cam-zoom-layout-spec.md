# 技术契约与架构设计书

**spec_id**: dual-cam-zoom-layout-20260427
**goal**: 修复只保存前置的问题；实现布局比例可调；实现镜头缩放；确保保存文件与预览完全一致
**status**: draft

---

## 一、问题根因分析

### Bug 1：只保存前置画面

`captureOutput: didFinishProcessingPhoto:` 中，双摄模式的分支条件为：

```objc
if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
```

但 `AVCapturePhotoCaptureDelegate` 方法签名只有一个 `output` 参数，无法区分是 `frontPhotoOutput` 还是 `backPhotoOutput`。判断逻辑依赖 `output == self.backPhotoOutput` 是正确的，但 `pendingDualPhotosBack/Front` 标志的设置时机有问题。更关键的是，如果两个 delegate 回调不是同时触发，第二次回调会进入一个不正确的路径。

实际上，根因在于：**AVCapturePhotoCaptureDelegate 只注册了一次**（self），所有 photo output 的回调都进入同一个 delegate 方法。代码逻辑是：
1. 第一次回调：存图到 `pendingDualPhotos[@"front"]` 或 `pendingDualPhotos[@"back"]`，设标志
2. 第二次回调：同样存图，设标志，然后检查是否两个都到了

这个逻辑本身是对的，但问题在于：**前后摄像头生成的图片宽高比不同**。前置的 `front.extent` 是竖屏 `1080×1420`（宽<高），后置的 `back.extent` 是 `1920×1440`（宽>高）。当用 `back.extent` 的宽高作为 canvas 时，前置图明显尺寸不匹配。

### Bug 2：后置白色背景

用户说"后置是白色背景"，这说明后置摄像头拍摄的照片本身可能是**曝光不足或白平衡失调**，但更可能是合成时的 crop 区域问题。如果 `front.extent.size` 和 `back.extent.size` 的宽高比差很大，crop 计算可能取到了纯色区域。

另外，从 EXIF 数据看，照片可能有旋转属性（`kCGImagePropertyOrientation`）。`CIImage.imageWithData:` 不会自动应用旋转，照片可能是侧躺或倒置的，然后 crop 到错误区域导致全白。

### Bug 3：LR/SX 方向错误

当前 `compositeLRForPhotos` 中的 `halfW = canvasW, halfH = canvasH / 2`：
- LR：左=宽，右=宽/2。但预览中左半屏是 canvasH/2 高度、canvasW 宽度的区域，所以应该 halfW = canvasW/2, halfH = canvasH（和 sx 互换）
- SX：上=宽/2，下=宽/2。但预览中上半分屏是 canvasW 宽度、canvasH/2 高度，所以应该 halfW = canvasW, halfH = canvasH/2（和 lr 互换）

**根本原因：LR 和 SX 的 halfW/halfH 写反了。**

### 用户新增需求分析

#### 功能 1：布局比例可调
- LR：左右比例（默认 50:50）
- SX：上下比例（默认 50:50）
- PiP：窗口大小 + 位置（自由拖动）

#### 功能 2：镜头缩放
- 前置：`1x`（广角）、`0.5x`（超广角，需检查是否支持）
- 后置：`0.5x`（超广角）、`1x`（广角）、`2x`/`3x`/`5x`（长焦）

iPhone 上的实现策略：
- 前置：目前只有一颗前置摄像头，用 `device.videoZoomFactor` 实现 0.5x 超广角裁切（需要检查 device 是否支持）
- 后置：需要发现设备上所有可用摄像头（广角、超广角、长焦），通过 `AVCaptureMultiCamSession` 同时配置多个物理摄像头实现真正的光学变焦

实际上，`AVCaptureMultiCamSession` 支持同时运行多个摄像头。如果要实现"1x + 2x"双摄，需要同时打开 `wideAngleCamera` 和 `telephotoCamera`，并分别配置 zoom factor。

更实际的方法：
- `0.5x` = `builtInUltraWideCamera`（如果设备有）
- `1x` = `builtInWideAngleCamera`
- `2x/3x/5x` = `builtInTelephotoCamera` 或通过 `builtInWideAngleCamera` 的 `videoZoomFactor`

**核心发现：目前 `cameraDeviceForPosition:` 只发现 `builtInWideAngleCamera`，无法获取超广角和长焦摄像头。**

#### 功能 3：保存与预览完全一致

关键洞察：**直接用 `AVCaptureVideoPreviewLayer` 的渲染结果截图**！

`AVCaptureVideoPreviewLayer` 已经正确处理了：
- 方向旋转（Portrait）
- 镜像（前置）
- 缩放（fill aspect）

所以正确的做法是：
1. 在双摄模式下，给 `AVCaptureVideoPreviewLayer` 添加 `AVCaptureVideoDataOutput`
2. 在 `capturePhotoWithSettings:delegate:` 时，同时保存每个 preview layer 的最新帧
3. 用保存的帧画面（而不是 photo output 的原始图）来合成

但 `AVCaptureMultiCamSession` 最多只能添加一个 `AVCaptureVideoDataOutput`！无法同时获取两个 preview layer 的帧。

**最佳折中方案**：
- 预览时用 `AVCaptureVideoPreviewLayer`（完全正确）
- 拍照/录视频时：直接让 `AVCapturePhotoOutput` 和 `AVCaptureMovieFileOutput` 各自截取画面
- 合成时：按照预览中看到的相对位置，叠加两张原图
- 关键：让每个摄像头按自己的方向输出（不去强制 `AVCaptureVideoOrientationPortrait`），这样前置自拍就不会左右颠倒

实际上，更简单的解决方案是：**在预览 view 上直接截屏**。iOS 上可以用 `layer.render(in:)` 把整个 `DualCameraView` 渲染为一个 `UIImage`。这样保存的文件就和屏幕上看到的完全一样。

这意味着：
- 预览渲染正确 → 直接截图 → 保存文件
- 无需任何旋转、镜像、crop 的额外处理

**最终决定：拍照时直接用 `UIGraphicsBeginImageContextWithOptions` 截图 `DualCameraView`（含所有 preview layers）！**

---

## 二、设计契约

### 数据模型

#### 新增原生属性

```objc
// Layout ratio control (0.0 - 1.0, default 0.5)
@property (nonatomic, assign) CGFloat dualLayoutRatio; // LR: back占的比例; SX: back占的比例

// PiP control
@property (nonatomic, assign) CGFloat pipSize;       // 0.0 - 1.0 (相对于canvasW)
@property (nonatomic, assign) CGPoint pipPosition;   // 0-1 normalized, center of pip

// Zoom
@property (nonatomic, assign) CGFloat frontZoomFactor; // 0.5 or 1.0
@property (nonatomic, assign) CGFloat backZoomFactor;  // 0.5, 1.0, 2.0, 3.0, 5.0

// Canvas snapshot (photo capture)
@property (nonatomic, assign) BOOL useCanvasSnapshot; // default YES, use render snapshot
```

#### JS 侧新增状态

```jsx
const [dualLayoutRatio, setDualLayoutRatio] = useState(0.5); // 0.0 - 1.0
const [pipSize, setPipSize] = useState(0.3); // 0.0 - 1.0
const [pipPosition, setPipPosition] = useState({ x: 0.85, y: 0.75 }); // normalized
const [frontZoom, setFrontZoom] = useState(1.0); // 0.5 or 1.0
const [backZoom, setBackZoom] = useState(1.0);   // 0.5, 1.0, 2.0, 3.0, 5.0
```

#### 新增 RCT_EXPORT_METHOD

```objc
// Layout control
RCT_EXPORT_METHOD(setDualLayoutRatio:(double)ratio) {
  // 0.0-1.0, 0.5 = 50:50 split
}

// PiP control
RCT_EXPORT_METHOD(setPipSize:(double)size) {
  // 0.0-1.0, 0.3 = 30% of screen width
}
RCT_EXPORT_METHOD(setPipPosition:(double)x y:(double)y) {
  // normalized 0-1 position
}

// Zoom
RCT_EXPORT_METHOD(setFrontZoom:(double)factor) {
  // 0.5 or 1.0
}
RCT_EXPORT_METHOD(setBackZoom:(double)factor) {
  // 0.5, 1.0, 2.0, 3.0, 5.0
}
```

---

## 三、拍照管线重构（核心）

### 新拍照方案：Canvas 直接截图

```objc
- (void)internalTakePhoto {
  dispatch_async(self.sessionQueue, ^{
    // Always use canvas snapshot for dual-cam mode
    if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
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
      // Single-cam mode: use existing photo output
      AVCapturePhotoOutput *output = [self photoOutputForCurrentLayout];
      if (!output) {
        [self emitError:@"Photo output not available"];
        return;
      }
      AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
      [output capturePhotoWithSettings:settings delegate:self];
    }
  });
}

- (UIImage *)captureCanvasSnapshot {
  dispatch_sync(dispatch_get_main_queue(), ^{
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, YES, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [self.layer renderInContext:ctx];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img; // captured on main thread
  });
}

- (NSString *)saveImageAsJPEG:(UIImage *)image {
  NSString *path = [[self documentsPath] stringByAppendingPathComponent:
    [NSString stringWithFormat:@"dual_photo_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]]];
  NSData *jpg = UIImageJPEGRepresentation(image, 0.9);
  [jpg writeToFile:path atomically:YES];
  return path;
}
```

**优点**：
1. 预览正确 = 保存正确（所见即所得）
2. 不需要处理方向、镜像、旋转
3. LR/SX/PiP 的比例和位置完全由 UI 布局决定，截图自动包含
4. 简单可靠，没有 crop/scale 错误

**代价**：
- 照片分辨率 = 屏幕分辨率（通常 1080×1920 @3x = 3240×5760），质量足够日常使用
- 需要在主线程截图（但用户按下快门本身可以有短暂等待）

### 视频录制管线重构

视频同理：不能用 canvas 截图，需要录制 `AVCaptureMovieFileOutput` 的画面。

视频方案：合成时用和拍照相同的布局参数，但这次是从录制的视频文件中读取帧来合成。

但实际上，最佳方案是：**双摄视频直接使用 `AVAssetWriter` 从 `AVCaptureVideoDataOutput` 写入**。但 `AVCaptureMultiCamSession` 只支持一个 `AVCaptureVideoDataOutput`。

**折中方案**：录两路视频 → 后处理合成（和之前一样），但这次使用预览中看到的正确布局参数。

---

## 四、缩放实现

### 摄像头发现增强

```objc
- (NSArray<AVCaptureDevice *> *)allVideoDevices {
  AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
    discoverySessionWithDeviceTypes:@[
      AVCaptureDeviceTypeBuiltInUltraWideCamera,
      AVCaptureDeviceTypeBuiltInWideAngleCamera,
      AVCaptureDeviceTypeBuiltInTelephotoCamera,
      AVCaptureDeviceTypeBuiltInDualCamera,
      AVCaptureDeviceTypeBuiltInDualWideCamera,
      AVCaptureDeviceTypeBuiltInTripleCamera,
    ]
    mediaType:AVMediaTypeVideo
    position:AVCaptureDevicePositionUnspecified];
  return discovery.devices;
}
```

### 缩放方案

对于 iPhone：
- 前置：只有一颗 `builtInWideAngleCamera`，`videoZoomFactor` 范围通常是 1.0-5.0，可以在 1.0 时达到正常视角。要实现 0.5x，需要检查是否有 `builtInUltraWideCamera`（某些型号的前置有超广角）
- 后置：
  - 基础：`builtInWideAngleCamera`（1x）
  - 超广角：`builtInUltraWideCamera`（0.5x）— 需要单独配置一个 device input
  - 长焦：`builtInTelephotoCamera`（2x/3x/5x）— 需要单独配置一个 device input

### 双摄缩放架构

要实现"前置 1x/0.5x + 后置 1x/2x"同时工作，需要：

```
Session: AVCaptureMultiCamSession
  - backUltraWide → backPhotoOutput / backMovieOutput (0.5x)
  - backWide → (no output, for preview reference)
  - backTelephoto → (no output, for preview reference)
  - frontWide → frontPhotoOutput / frontMovieOutput (1x)
```

但 `AVCaptureMultiCamSession` 的硬件成本是有限制的。当前的 `hardwareCost > 1.0` 检查限制了同时使用的摄像头数量。

**最小可行方案**：对于双摄模式（同时使用前后摄像头），使用 `builtInWideAngleCamera` 作为唯一的后置摄像头，通过 `videoZoomFactor` 实现数字变焦（1x/2x/3x）。超广角和长焦摄像头的切换通过更换 `AVCaptureDevice` 实现（这会中断预览）。

**实际可行方案**（分阶段）：
- 阶段 1：使用 `videoZoomFactor` 实现数字缩放（1x/2x/3x），前置用 1x
- 阶段 2：如果设备支持 `builtInUltraWideCamera`，在切换到 0.5x 时替换后置摄像头

---

## 五、JS 前端 UI 设计

### 滑块 UI

在相机模式下，底部显示一个可展开的"布局调整"面板：

```
┌────────────────────────────────────────┐
│ [布局调整]                               │
│                                        │
│ LR/SX 比例: ◄────●─────────────► 50%   │
│ PiP 大小: ◄──●───────────────────► 30%  │
│ PiP 位置: ↗                           │
│                                        │
│ 前置缩放: [1x] [0.5x]                  │
│ 后置缩放: [1x] [2x] [3x]               │
└────────────────────────────────────────┘
```

### 滑块传递到原生

```jsx
<DualCameraView
  style={styles.camera}
  layoutMode={cameraMode}
  // 新增：
  dualLayoutRatio={dualLayoutRatio}
  pipSize={pipSize}
  pipPositionX={pipPosition.x}
  pipPositionY={pipPosition.y}
  frontZoomFactor={frontZoom}
  backZoomFactor={backZoom}
/>
```

---

## 六、文件清单

### 修改文件

1. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.h` — 新增属性声明
2. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraView.m` — 核心重写
3. `E:\MyCameraApp\my-app\native\LocalPods\DualCamera\DualCameraModule.m` — 新增 RCT 方法
4. `E:\MyCameraApp\my-app\App.js` — 新增 UI 滑块

### 无需新建文件

---

## 七、验证计划

| 布局 | 拍照 | 视频 | 缩放 |
|---|---|---|---|
| `lr` 50:50 | 所见即所得 | 正确合成 | 支持 |
| `lr` 70:30 | 所见即所得 | 正确合成 | 支持 |
| `sx` 50:50 | 所见即所得 | 正确合成 | 支持 |
| `pip` 移动 | 所见即所得 | 正确合成 | 支持 |
| `back` | 单摄正常 | 单摄正常 | 支持 |
| `front` | 单摄正常 | 单摄正常 | 支持 |

---

## 八、知识回写

```
### 所见即所得拍照：Canvas 截图（2026-04-27，spec: dual-cam-zoom-layout）
双摄模式下，不要用 AVCapturePhotoOutput 的原始图来做合成。
直接用 UIGraphicsBeginImageContextWithOptions 截图整个 DualCameraView（含所有 AVCaptureVideoPreviewLayer）。
这样预览正确 = 保存正确，无需处理方向/镜像/旋转。
注意：此方法会截取整个 view，包括所有 UI 覆盖层（如按钮），需要在截图中过滤掉按钮层。

### AVCaptureMultiCamSession 摄像头发现（2026-04-27，spec: dual-cam-zoom-layout）
cameraDeviceForPosition: 只返回 builtInWideAngleCamera。
要发现超广角和长焦，必须用 allVideoDevices + AVCaptureDeviceTypeBuiltIn* 系列类型。
```
