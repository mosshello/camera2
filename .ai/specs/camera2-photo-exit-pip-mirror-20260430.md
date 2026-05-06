# 技术契约与架构设计书
# 修复：后置摄像头严重曝光 + 拍照直接退出 App + PiP 位置错误 + 无镜像
# spec_id: camera2-photo-exit-pip-mirror-20260430
# 日期: 2026-04-30

---

## 一、问题诊断

### 问题 1：后置摄像头严重曝光（过曝/白蒙蒙）
- **用户描述**: "后置摄像头拍出来的画面严重曝光"
- **根因分析**: `configureDeviceForMultiCam:` 配置了设备格式、帧率、缩放因子，但**从未设置曝光模式**。`AVCaptureDevice` 默认曝光策略取决于系统当前状态，在某些设备/光照组合下可能产生严重过曝。
- **受波及文件**: `DualCameraView.m`

### 问题 2：点击拍摄直接退出 App
- **用户描述**: "点击拍摄直接退出 app"
- **根因分析**: 4 条独立 bug 叠加：
  1. `takePhoto()` 调用后若出错/异常，`saving` 标志无法重置（JS 层的 `onPhotoError` 和 `onSessionError` 监听器都没有将 `saving` 重置为 `false`），导致 UI 卡死。
  2. `internalTakePhoto` 在 `sessionQueue` 中访问 `canvasSizeForPhoto`（__block 变量），但如果 view 在 dispatch 期间被 dealloc，可能触发 EXC_BAD_ACCESS。
  3. `compositingQueue` 上的 `dispatch_async` 没有 `@autoreleasepool`，大量 CIImage 操作可能使 autorelease pool 耗尽导致异常。
  4. `internalTakePhoto` 的单摄分支（`else` 分支）在 delegate 回调外触发了 `capturePhotoWithSettings:delegate:` 但没有任何日志或状态保护，异常无法向上传播。
- **受波及文件**: `DualCameraView.m`（原生层）、`App.js`（JS 层）

### 问题 3：PiP 位置从右下跑到左上
- **用户描述**: "方向的从右下跑到了左上角落"
- **根因分析**: `DualCameraViewManager.m` 只声明了 `layoutMode` 和 `saveAspectRatio` 为 `RCT_CUSTOM_VIEW_PROPERTY`。`pipSize`、`pipPositionX`、`pipPositionY` 是非自定义属性，React Native 的属性传递机制对其处理不正确——**JS 层传入的值从未真正设置到 native view 上**，导致 native view 一直使用 `commonInit` 中的默认值（`pipPositionX=0.85`，`pipPositionY=0.80`）——等等，这应该是右下角？实际上问题更深：默认 `pipPositionX=0.85` 理论上应该是右下，但 `compositePIPFront` 和 `compositePIPForPhotos` 中的 PiP 计算与预览层 `updateLayout` 的坐标系统不一致（镜像变换导致坐标反转）。
- **受波及文件**: `DualCameraView.m`（composite 镜像逻辑）、`DualCameraViewManager.m`（缺少属性声明）

### 问题 4：所有拍摄不需要镜像处理
- **用户描述**: "所有拍摄不需要做镜像处理，镜头里呈现出来什么样子保存为什么样子"
- **根因分析**: 当前代码在多处对前置摄像头做了镜像：
  1. 预览层：`connection.videoMirrored = YES`（第 414 行）
  2. 照片合成（LR/SX/PiP 各有两套方法）：所有 `composite*` 方法都显式加入了水平镜像变换
- **修复方向**: 移除所有镜像。预览层改为 `videoMirrored = NO`；所有合成方法移除镜像变换。PiP 的位置计算保持不变（前置预览已在右上角/左上角，不需要靠镜像变换来对齐）。

---

## 二、技术契约

### 2.1 数据模型层（无变更）

`DualCameraView` 属性不变，不新增 Schema。

### 2.2 API 交互层（Native → JS）

事件类型不变：`onPhotoSaved`、`onPhotoError`、`onRecordingFinished`、`onRecordingError`、`onSessionError`。

变更点：
- `onPhotoError` 触发时必须通知 JS 层清除 `saving` 标志（JS 层已在 `onPhotoError` 监听器中处理）

### 2.3 前端交互层

`App.js` 变更：
- `onPhotoError` 监听器中 `setSaving(false)`（已存在，但 `onSessionError` 中也需要）
- 无需变更 Props 传递（因为变更在 native 侧）

---

## 三、全栈影响面分析

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 核心修改 | 曝光 + 镜像 + 防崩溃 |
| `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m` | 新增声明 | PiP 属性声明 |
| `my-app/App.js` | 最小修改 | 添加 `setSaving(false)` 到 `onSessionError` |

---

## 四、详细修改清单

### 4.1 `DualCameraView.m`

#### Bug 1 Fix: 自动曝光（新增）
在 `configureDeviceForMultiCam:` 中，`device.videoZoomFactor = _backZoomFactor` 之后添加：
```objc
// 自动曝光：防止严重过曝/欠曝
if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
  [device lockForConfiguration:nil];
  device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
  [device unlockForConfiguration];
}
```

#### Bug 1 Fix: 单摄模式也加曝光
在 `configureSingleSessionForPosition:startRunning:` 中，设备锁定块结束后添加相同曝光代码。

#### Bug 2 Fix Part A: @autoreleasepool + 防御性 nil 检查
在 `internalTakePhoto` 的 `dispatch_async(self.sessionQueue, ...)` 块中，用 `@autoreleasepool {}` 包裹全部操作，并添加 `if (!self.isConfigured) return;` 保护。

#### Bug 2 Fix Part B: 单摄分支防崩溃
`internalTakePhoto` 的单摄分支在 `capturePhotoWithSettings:delegate:` 前后添加 `@try/@catch(NSException *exception)` 包装。

#### Bug 2 Fix Part C: `captureOutput:didFinishProcessingPhoto:error:` 异常保护
在 delegate 回调中用 `@try/@catch` 包裹全部保存逻辑。

#### Bug 3 Fix: 移除镜像（预览层 + 全部合成方法）
- `configureAndStartMultiCamSession` 第 414 行：`mirrorVideo:YES` → `mirrorVideo:NO`
- `compositeLRFront`: 移除 `frontRightOffset` 的镜像变换（前摄以原始方向合成）
- `compositeSXFront`: 移除前摄镜像变换
- `compositePIPFront`: 移除 `t` 中的镜像变换，前摄以原始方向放置到 PiP 区域
- `compositeLRForPhotos`: 移除镜像
- `compositeSXForPhotos`: 移除镜像
- `compositePIPForPhotos`: 移除镜像

**关键说明**：移除镜像后，前摄画面以前镜头看到的原始方向保存，与预览层去掉 `videoMirrored` 后的画面完全一致——所见即所存。

### 4.2 `DualCameraViewManager.m`

新增 `RCT_CUSTOM_VIEW_PROPERTY` 声明：
- `dualLayoutRatio` (CGFloat)
- `pipSize` (CGFloat)
- `pipPositionX` (CGFloat)
- `pipPositionY` (CGFloat)

### 4.3 `App.js`

在 `onSessionError` 监听器中添加 `setSaving(false); setRecording(false);`（`setSaving` 已存在，`setRecording` 也已存在，确认代码正确）。

---

## 五、风险评估

| 风险 | 级别 | 缓解 |
|---|---|---|
| 移除镜像后前摄自拍方向反转（用户习惯自拍镜像） | 中 | 用户明确要求无镜像，与预期行为一致 |
| @autoreleasepool 改变内存释放时机 | 低 | 仅影响 compositing 队列内部的 autorelease 对象生命周期 |
| PiP 位置在移除镜像后视觉偏移 | 低 | PiP 位置由 `pipPositionX/Y` 控制，与镜像无关；坐标计算本身不需要镜像 |
| `configureDeviceForMultiCam` 修改后某些设备格式不支持自动曝光 | 低 | 使用 `isExposureModeSupported:` 检查，不支持的设备跳过 |

---

## 六、验收标准

1. ✅ 后置摄像头（back 模式）拍照/预览：画面亮度正常，不过曝
2. ✅ 点击圆形拍照按钮：App 不退出，saving 状态正确归零
3. ✅ PiP 布局：预览中 PiP 在右下角 → 保存照片中 PiP 也在右下角
4. ✅ 前置摄像头：预览无镜像（头偏向哪边，哪边就在那边）→ 保存照片与预览一致（无镜像）
5. ✅ 双摄 LR/SX/PiP 布局：前后摄像头画面方向正确，无异常镜像
