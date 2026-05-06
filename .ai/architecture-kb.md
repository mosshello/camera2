# Architecture Knowledge Base
# 架构知识库 — 记录已知缺陷模式和架构陷阱，防止重复踩坑

status: draft
last-verified: 2026-04-30

---

## 已知缺陷模式

### 视频录制无声音 — 缺少音频采集链路
- **首次发现**: 2026-04-25
- **spec_id**: dual-camera-video-fix-20260425
- **文件**: DualCameraView.m
- **根因**: `AVCaptureMovieFileOutput` 不会自动录制声音。必须在会话配置时显式：
  1. 获取 `AVMediaTypeAudio` 设备并创建 `AVCaptureDeviceInput`
  2. 将 audio input 用 `addInputWithNoConnections:` 加入 session
  3. 在 audio input port 与 movie output 之间建立 `AVCaptureConnection`
  多摄模式下只创建了 `backMovieOutput`；单摄模式下只创建了 `singleMovieOutput`，两者都没有 audio input。
- **修复 commit**: <待填写>
- **状态**: [FIXED]

### 前置摄像头录制失败 — 前置摄像头无 movie output
- **首次发现**: 2026-04-25
- **spec_id**: dual-camera-video-fix-20260425
- **文件**: DualCameraView.m
- **根因**: `movieOutputForCurrentLayout` 在多摄模式下，当前置摄像头被选为主画面时返回 `nil`（因为前置摄像头从未被分配 `AVCaptureMovieFileOutput`）。录制直接失败。
- **修复 commit**: <待填写>
- **状态**: [FIXED]

### 双摄拍照全黑 — renderInContext 抓取 Metal layer 黑帧 + 两次 capturePhoto 永不保存
- **首次发现**: 2026-04-27
- **spec_id**: dual-cam-photo-black-20260427
- **文件**: DualCameraView.m
- **根因**: 两条独立 bug 同时存在：
  1. **黑帧**：`internalTakePhoto` 分支 A 调用 `[self.layer renderInContext:]` 做 canvas snapshot，但 `AVCaptureVideoPreviewLayer` 底层是 `CAMetalLayer`，有独立 GPU 渲染管线，不经过 Core Graphics 合成树，renderInContext 只能抓到黑帧。
  2. **永不死锁**：`internalTakePhoto` 分支 B 调用 `capturePhotoWithSettings:delegate:` **两次**（前后各一次）。delegate 收到第一张时，`pendingDualPhotosBack+Front` 初始为 NO，第一张会正确存储，但判断"两张都收到"时，只有第二张也触发才能进入合成保存分支——但第二张触发时 `pendingDualPhotos` 已被第一张填充，判断同样正确，然后等待第二张到达，而第二张就是刚才触发的那一张——逻辑看起来能跑通，实际是代码中 `pendingDualPhotos` 字典从未被清空，导致每次拍照的 flag 状态叠加，最终两张照片永远等不到彼此。
  3. **isDualLayout 属性遮蔽**：delegate 中判断 `if (self.usingMultiCam && [self isDualLayout:self.currentLayout])` 时，方法调用顺序与属性状态不同步，导致分支判断错误。
- **修复 commit**: 2ee9bfc
- **状态**: [FIXED]

---


### PiP 拖动手势缺失 — UIPanGestureRecognizer 未添加（2026-05-01）
|- **首次发现**: 2026-05-01
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
|- **用户需求**: PiP 小窗可被手指拖动到任意位置，拖动时实时预览更新。
|- **根因**: JS 层通过 state 控制 `pipPositionX/Y`，但 Native 层未添加 `UIPanGestureRecognizer`，用户无法直接拖动小窗。
|- **修复**: 在 `commonInit` 中给 `_frontPreviewView` 添加 `UIPanGestureRecognizer` + `UIPinchGestureRecognizer`（见 spec）。
|- **关键技术点**: `_frontPreviewView` 在 PiP 模式下可能是小窗（`pipMainIsBack=YES`）或主画面（`pipMainIsBack=NO`）。拖动手势应**仅在小窗为 `_frontPreviewView`** 时启用。`handlePipPan:` 中 clamp 计算防止拖出画布。拖动结束时通过 `sendPipPositionChanged` 事件通知 JS。
|- **状态**: [TODO]

### PiP 捏合缩放手势缺失 — UIPinchGestureRecognizer 未添加（2026-05-01）
|- **首次发现**: 2026-05-01
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
|- **用户需求**: PiP 小窗可通过两指捏合放大/缩小。
|- **修复**: 在 `commonInit` 中添加 `UIPinchGestureRecognizer`，`handlePipPinch:` 中记录 `lastPipSize`（在 `Began` 状态保存），`Changed` 时应用 `newSize = lastPipSize * pinch.scale`。
|- **状态**: [TODO]

### PiP 模式下 Zoom Bar 控制小窗摄像头 + 跟随小窗位置（2026-05-01）
|- **首次发现**: 2026-05-01
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/App.js`
|- **用户需求**: PiP 模式下，zoom bar 应控制**小窗摄像头**（而非主画面摄像头），且 zoom bar 跟随小窗位置移动。
|- **当前行为**: `effectiveCamera` 在 PiP 模式下为 `isFlipped ? 'front' : 'back'`，控制的是主画面而非小窗。Zoom bar 固定在底部中央。
|- **修复**:
  1. PiP 模式 `effectiveCamera` = **小窗摄像头**：`isFlipped ? 'back' : 'front'`（flip 前小窗=前置，flip 后小窗=后置）。
  2. Zoom bar 改为动态绝对定位：`left/top` 基于 `pipPosition` + `pipSize` 计算，放在小窗外侧（左侧），`transition: left 0.1s ease-out, top 0.1s ease-out` 实现动画。
  3. `onPipPositionChanged` 事件同步 Native 拖动位置到 JS → 更新 `pipPosition` state。
|- **相关陷阱**: 见"PiP zoom bar 跟随小窗 — 相对定位算法"条目。
|- **状态**: [TODO]

### 画幅选择器位置错误 — 应在左上角而非左下角（2026-05-01）
|- **首次发现**: 2026-05-01
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/App.js`
|- **用户需求**: 左上角全局画幅控制（`9:16`/`3:4`/`1:1`），所有模式均显示。
|- **当前实现**: 画幅选择器在左下角（`bottom: 110`），且只在双摄模式显示。
|- **修复**: 移至左上角（`top: 60`），所有模式（单摄+双摄+PiP）均显示。
|- **状态**: [TODO]

### 画幅切换不影响预览 viewport — 仅影响保存画布（2026-05-01）
|- **发现日期**: 2026-05-01
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **设计决策**: `saveAspectRatio` 的变更**不重建 AVCaptureSession**，预览 viewport 始终由屏幕实际像素决定（`self.bounds`）。画幅选择仅影响 `internalTakePhoto` 中的 `saveCanvas` 尺寸计算，以及 `compositeDualVideosForCurrentLayout` 中的 `renderSize`。这与 WYSIWYG 原则一致：**预览框就是最终输出框**。无需修改 native layout 代码。
|- **状态**: [BY_DESIGN]

## 架构陷阱与注意事项

### ⚠️ AVCaptureVideoPreviewLayer 不能用 renderInContext 截图
`AVCaptureVideoPreviewLayer` 底层是 `CAMetalLayer`，有独立的 GPU 渲染管线，不经过 Core Graphics 合成树。调用 `[CALayer renderInContext:]` 只能抓到黑帧。
**正确做法**：使用 `AVCapturePhotoOutput` 的 `capturePhotoWithSettings:delegate:` 获取实际图像数据，或使用 `AVCaptureVideoDataOutput` 实时获取 CMSampleBuffer 再转为 UIImage/CIImage。
iOS AVFoundation 中，`AVCaptureMovieFileOutput` 不会自动录制声音。必须在会话配置时同时完成：
- `AVCaptureDeviceInput` (麦克风) → session
- `AVCaptureConnection` (audio input port → movie output)
两者缺一不可。没有 audio input，movie output 的录音轨为空；没有 connection，即使有 input 也不会写入。

### ⚠️ 所有连接必须在 begin/commitConfiguration 块内添加
这是导致音频连接"静默无效"的根本原因。在 `AVCaptureMultiCamSession` 上，`commitConfiguration` 之后添加的 `AVCaptureConnection` 会被忽略（不会报错，只是完全不生效）。
修复方法：将所有音频连接代码（包括音频→各 movie output 的 connection）放在 `[session beginConfiguration]` 之后、`[session commitConfiguration]` 之前。
单摄模式（普通 `AVCaptureSession`）也建议遵循此规则以保持一致性。

### 前置摄像头在多摄模式下默认只有 photo output
多摄模式 (`AVCaptureMultiCamSession`) 配置中，`AVCaptureMovieFileOutput` 需要显式分配并连接到对应的 `AVCaptureInputPort`。
当前置摄像头被选为"主画面"时，如果它没有专属的 movie output，录制会直接失败。
修复方案：多摄模式下同时为前置和后置摄像头各分配一个 `AVCaptureMovieFileOutput`。

### 音频权限跟随相机权限
`[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo]` 完成后，iOS 会自动在需要麦克风时弹出音频权限对话框（若尚未决定）。无需在 JS 层单独申请音频权限，除非需要提前知道授权状态。

### MultiCam hardwareCost 检查
`AVCaptureMultiCamSession` 有硬件预算限制。当 `hardwareCost > 1.0` 时，说明当前配置超出了设备能力，session 无法启动。音频 input 的 hardware cost 极低，不会触发此限制。

### AVCaptureMovieFileOutput 自动创建视频轨连接
`addOutput: forPort: toSession:` 方法中，`[session addOutputWithNoConnections:output]` 后手动创建的 `AVCaptureConnection` 仅包含视频端口。当 audio input 加入后，音频轨连接需要额外手动建立（见上方"陷阱1"）。

### ⚠️ commitConfiguration 之后添加的连接不生效（第二轮发现，2026-04-25）
这是音频录制"静默无效"的根本原因。在 `AVCaptureMultiCamSession` 上，`commitConfiguration` 之后添加的 `AVCaptureConnection` 会被系统静默忽略（不会报错，代码执行了但不生效）。
音频连接必须放在 `[session beginConfiguration]` 之后、`[session commitConfiguration]` 之前。单摄模式（`AVCaptureSession`）也建议遵循此规则。

### 双摄媒体合成方案（2026-04-25，spec: dual-cam-compositing）
`AVCapturePhotoOutput` 可多次调用 `capturePhotoWithSettings:delegate:`，无限制。`AVCaptureMultiCamSession` 最多添加一个 `AVCaptureVideoDataOutput`。因此：
- 照片合成：双 photo output 同时拍摄 → Core Image (CIImage) 内存合成
- 视频合成：双 movie output 同时录两路 `.mov` → 录制完成后用 `AVAssetExportSession` 后处理合并音视频

### 双摄录制状态锁（2026-04-25，spec: dual-cam-compositing）
双摄录制期间必须禁止布局切换，否则 `AVCaptureMultiCamSession` 的 connection 状态会变得不确定，导致录制无法正常停止。
必须使用 `isDualRecordingActive` 标志：`internalStartRecording` 开始时置 YES，`internalStopRecording` 后不立即清除（等待两个 movie output 都完成 delegate 回调才清除）。
若录制出错，也必须立即停止另一个 movie output 并重置状态。

### CIImage 合成顺序：先 crop 再 scale
Core Image 中先 scale 再 crop 的顺序会导致不同分辨率摄像头输出尺寸不匹配（前置 1080×1420 vs 后置 1920×1440）。
正确顺序：`imageByCroppingToRect:` → `scaledCIImage:toSize:`，每半区域独立计算 crop 区域并使用各自原始分辨率。

### 双摄 SX（上下）合成必须边对边对齐（2026-04-27）
SX 布局合成时，如果 front/back 用不同的 scale 基准（前置按宽度缩放，后置按高度缩放），会导致拼接线处出现间隙。
正确做法：front 和 back **必须使用相同的 scale 基准**（如都按 halfH 缩放），crop 时各自从图像边缘（top/bottom）截取相同尺寸，然后直接平移放置（无居中偏移）。

### ⚠️ 视频合成中前置摄像头必须手动添加水平镜像（2026-04-29）
`AVCaptureVideoPreviewLayer` 在配置连接时设置 `connection.videoMirrored = YES`，但 `AVCaptureMovieFileOutput` 录制的 `.mov` 文件**不包含**预览层的镜像变换。前置摄像头的内容在录制文件中是"镜子里"的像（未镜像）。合成时必须在 `frontTransform` 中显式加入水平镜像变换 `CGAffineTransformConcat(translation, scale(-1,1))`，否则保存的视频前置左右颠倒。LR 布局和 PiP 布局均需此修复。SX 布局的前置镜像已在 `captureOutput:didOutputSampleBuffer:` 中对 CIImage 做了，无需重复。

### ⚠️ AVCaptureVideoDataOutput 必须显式设置 videoOrientation（2026-04-28）
`AVCaptureVideoDataOutput` 的连接不自动继承 `AVCaptureVideoOrientationPortrait`，如果不设置，buffer 的坐标系方向取决于设备当前朝向，可能导致 buffer 宽高颠倒（portrait device 输出 landscape 帧）。
修复：在 `[session addOutput:]` 后立即获取连接并设置 `connection.videoOrientation = AVCaptureVideoOrientationPortrait`。
同时 `AVCaptureConnection.videoMirrored` 的 `automaticallyAdjustsVideoMirroring` 默认开启，必须设为 `NO` 后再设置 `videoMirrored = YES`。

### 保存 canvas 基准宽度必须固定（2026-04-28）
`self.bounds.size.width` 在屏幕旋转时可能变化（portrait/landscape），导致保存比例不一致。
修复：用固定值 `refW = 390.0` 作为参考宽度，保证无论设备朝向如何，输出尺寸恒定。

### 视频合成变换：禁止硬编码 scale factor
`CGAffineTransformMakeScale(2.0, 1.0)` 是错误的占位代码。必须从 `AVAssetTrack.naturalSize` 动态计算 scale factor：
- LR/SX 布局：`scale = targetDimension / videoTrack.naturalSize.{width|height}`
- PiP 布局：`scale = targetPixelSize / videoTrack.naturalSize.{width|height}`
- `videoSize` 应取后置摄像头录制的 `naturalSize`（作为 renderSize 基准）

### fmt v11 + Xcode 26.4 编译失败 — C++20 consteval 兼容性问题
- **首次发现**: 2026-04-29
- **spec_id**: fmt-xcode26-compile-fix-20260429
- **根因**: Xcode 26.4 的 Clang 对 C++20 `consteval` 函数有 bug，`fmt::basic_format_string` 的构造函数无法通过 constexpr 求值检查
- **修复方案**:
  1. 设置 `CLANG_CXX_LANGUAGE_STANDARD = c++17` (避免 consteval 问题)
  2. 设置 `GCC_TREAT_WARNINGS_AS_ERRORS = NO`
  3. **Podfile post_install 补丁**: 将 `FMT_STRING(s)` 替换为 `runtime_format_string(s)` 运行时版本
  4. 添加 `runtime_format_string` 辅助类避免 consteval 检查
- **注意**: fmt v11 不支持 `FMT_HEADER_ONLY` 预处理器宏
- **状态**: [FIXED]

### Xcode 可运行性回归 — 全局 C++17 与 RN 0.81 C++20 特性冲突
- **首次发现**: 2026-04-29
- **spec_id**: xcode-runnability-audit-20260429
- **文件**: `/Users/zhengxi/vibecoding/camera2/my-app/ios/Podfile`
- **根因**: `post_install` 将所有 Pod target 统一设置为 `CLANG_CXX_LANGUAGE_STANDARD = c++17`。React Native 0.81 的 `ReactCommon/react/performance/timeline/PerformanceObserver.cpp` 使用了 `std::unordered_set::contains`（C++20），导致 `xcodebuild` 报错并失败。
- **复现命令**: `xcodebuild -workspace myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
- **修复方案**: `Podfile post_install` 按 target 分级设置 C++ 标准（默认 `c++20`，`fmt` / `RCT-Folly` 使用 `c++17`）。
- **验证命令**: `pod install && xcodebuild -workspace /Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
- **状态**: [FIXED]

### 真机启动红屏 No script URL provided — Debug 包无内嵌 JS 且 Metro 不可达
- **首次发现**: 2026-04-29
- **spec_id**: ios-no-script-url-20260429
- **文件**: `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/AppDelegate.swift`, `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcodeproj/project.pbxproj`
- **根因**:
  1. `AppDelegate.swift` Debug 分支依赖 `RCTBundleURLProvider` 提供远程 JS URL，返回 `nil` 时 Bridge 无法启动；
  2. `project.pbxproj` 中 Debug 构建脚本固定 `SKIP_BUNDLING=1`，不会产出内嵌 `main.jsbundle`；
  3. 用户从手机桌面离线直开 Debug 包或 Metro 不同网段时，出现 `unsanitizedScriptURLString = (null)`。
- **修复建议**: 二选一
  1. 流程约束：仅通过 dev-client + Metro 启动；
  2. 工程兜底：Debug 支持按开关内嵌 bundle，并在 AppDelegate 增加 fallback 到 `main.jsbundle`。
- **修复方案**:
  1. `AppDelegate.swift` Debug 先尝试 Metro URL，失败 fallback 到 `main.jsbundle`；
  2. 新增 `.xcode.env.updates`，在 `DEBUG_EMBED_BUNDLE=1` 时 `unset SKIP_BUNDLING` 且 `FORCE_BUNDLING=1`；
  3. `.xcode.env` 新增 `DEBUG_EMBED_BUNDLE` 默认值（可被外部环境覆盖）。
- **验证命令**:
  - `xcodebuild -workspace /Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
  - `DEBUG_EMBED_BUNDLE=1 xcodebuild -workspace /Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`
- **状态**: [FIXED]

### 方案 B（实施级）— Debug 通过 `.xcode.env.updates` 解除 SKIP_BUNDLING
- **日期**: 2026-04-29
- **spec_id**: ios-no-script-url-planb-implementation-20260429
- **关键要点**:
  1. `Bundle React Native code and images` 已支持 source `.xcode.env.updates`，可用作开关注入点；
  2. 推荐引入 `DEBUG_EMBED_BUNDLE=1`：仅在开关打开时 `unset SKIP_BUNDLING`；
  3. `AppDelegate.swift` Debug 必须加 `main.jsbundle` fallback，避免 `unsanitizedScriptURLString = (null)`。
- **状态**: [FIXED]

### 方案 B（一次性修复包）— One-Shot 交付标准
- **日期**: 2026-04-29
- **spec_id**: ios-no-script-url-planb-one-shot-fix-20260429
- **关键要点**:
  1. 一次提交同时覆盖：开关注入、脚本覆盖、AppDelegate fallback、README 使用说明；
  2. Debug 默认行为不变，仅在 `DEBUG_EMBED_BUNDLE=1` 时开启内嵌 bundle；
  3. 验收必须包含“Metro 开/关 + 开关开/关”四象限验证。
- **状态**: [FIXED]

### iOS 本地网络被拒绝 — Metro `/status` 返回 -1009 (Denied over Wi-Fi)
- **首次发现**: 2026-04-29
- **spec_id**: ios-local-network-denied-metro-status-20260429
- **文件**: `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/Info.plist`
- **根因**:
  1. 调试态会访问 `http://<LAN_IP>:8081/status`；
  2. iOS 返回 `Denied over Wi-Fi interface`，说明本地网络路径被系统策略拒绝；
  3. 现有工程缺少 `NSLocalNetworkUsageDescription`，且设备设置可能关闭了 Local Network 权限。
- **修复建议**:
  1. `Info.plist` 增加 `NSLocalNetworkUsageDescription`；
  2. 在 README 增加“同网段 + Local Network 权限”排障步骤；
  3. 保留离线 fallback（`DEBUG_EMBED_BUNDLE=1`）作为兜底。
- **状态**: [FIXED]

### ⚠️ 前置摄像头镜像策略（2026-04-30）
- 预览层：`connection.videoMirrored = YES` 自动完成，无需额外代码。
- 拍照保存：存储 `captureOutput:didOutputSampleBuffer:` 中的**原始帧**，不在 CIImage 层做镜像。
- 视频合成：在 `AVMutableVideoCompositionLayerInstruction` 的 `frontTransform` 中显式加入镜像（`CGAffineTransformConcat(translation, scale(-1,1))`），因为录制的 .mov 不包含预览层镜像。
- **禁止**：在 `captureOutput` 中对 CIImage 做镜像，会导致双重镜像。

### ⚠️ CILanczosScaleTransform 的 aspectRatio 参数会破坏图像宽高比（2026-04-30）
- `CILanczosScaleTransform` 的 `kCIInputAspectRatioKey` 默认为 `1.0`，强制输出 1:1 正方形。
- 正确做法：使用 `CIAffineTransform` 滤镜配合 `CGAffineTransformMakeScale(scaleX, scaleY)`。
- 注意：`CIAffineTransform` 会改变 CIImage 的 extent origin，需要平移校正。

### ⚠️ dispatch_sync 在 sessionQueue 中访问 UIView bounds（2026-04-30）
- `sessionQueue` 是串行队列，其线程不是主线程。`dispatch_sync(dispatch_get_main_queue(), ...)` 在 `sessionQueue` 上执行不会死锁，但**禁止**在主线程本身调用。
- 正确模式：`__block` 变量 + `dispatch_sync(dispatch_get_main_queue(), ...)` 在 `sessionQueue` dispatch 之前执行。

### ⚠️ UIView.bounds 禁止从后台线程访问（2026-04-28）
- `UIView.bounds` 必须在主线程访问。在后台队列（如 `sessionQueue`）中需要使用 `dispatch_sync(dispatch_get_main_queue(), ...)` 预先捕获尺寸。

### ⚠️ AVCaptureVideoDataOutput 必须显式设置 videoOrientation（2026-04-28）
- 同 KB 原有条目，保持不变。

### ⚠️ 视频合成中前置摄像头必须手动添加水平镜像（2026-04-29）
- 同 KB 原有条目，保持不变。
### 双摄录制只保存前置 + 画面与预览不一致 — 4 条独立 bug（一次性修复）
|- **首次发现**: 2026-04-29
|- **spec_id**: dual-cam-video-compositing-complete-fix-20260429
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
|- **根因**: 4 条独立 bug：
  1. **SX layerInstructions 参数颠倒**（第 1200 行）：`layersWithBack:frontVideoTrack front:backVideoTrack` 传参反了。方法签名是 `layersWithBack:backTrack front:frontTrack`，实际传入 front→backTrack、back→frontTrack，导致 layers[0]=前置、layers[1]=后置。AVMVideComposition z-order：index=0 底部（最先合成），index=1 顶部（遮盖下方）。颠倒后后置在顶部遮盖前置。**配合后置录制失败（backMovieOutput nil）→ 前置透过显示。**
  2. **SX backOffsetY 多加 topHeight**（第 1179 行）：`backOffsetY = topHeight + (bottomHeight - backFillH) / 2` 中 topHeight 不应出现。正确：`backOffsetY = (bottomHeight - backFillH) / 2`。
  3. **LR + PiP 前置摄像头无水平镜像**：预览层配置了 `videoMirrored=YES`，但 `AVCaptureMovieFileOutput` 录制的 .mov 不包含镜像。合成时 frontTransform 缺少镜像，保存的视频前置左右颠倒。修复：在 frontTransform 中加入 `CGAffineTransformConcat(translation, scale(-1,1))`。
  4. **PiP 前置 scale 使用后置 naturalSize**：第 1221 行 `s / refW` 用后置的 refW/refH 计算前置比例，导致 PiP 小窗画面严重失真。修复：从 `frontAsset` 获取前置自身的 `naturalSize`。
|- **修复**:
  1. 第 1200 行：`layersWithBack:backVideoTrack front:frontVideoTrack`
  2. 第 1179 行：`backOffsetY = (bottomHeight - backFillH) / 2`
  3. LR 第 1146-1148 行：`frontTransform = CGAffineTransformConcat(translation(leftWidth+frontOffsetX,0), scale(-1,1))`；PiP 第 1235-1237 行：`frontTransform = CGAffineTransformConcat(translation(frontOffsetX+s, frontOffsetY), scale(-1, frontScale))`
  4. PiP 第 1225-1230 行：从 `frontAsset` 获取 `frontNaturalSize` 计算 scale
|- **状态**: [FIXED]

---

### DualCamera 两份源码陷阱
- **首次发现**: 2026-04-29
- **文件**: `native/LocalPods/DualCamera/` vs `ios/LocalPods/DualCamera/`
- **问题**: `withDualCamera` 插件使用 `copyRecursiveSync` 将 `native/LocalPods/` 复制到 `ios/LocalPods/`，每次 `pod install` 都会覆盖。Xcode 编译的是 `ios/LocalPods/` 的内容，而开发者通常编辑 `native/LocalPods/`。
- **修复**: 插件改用 `symlinkSync` 替代 `copyRecursiveSync`，保持单一真相源。
- **状态**: [FIXED]

---

## 历史 Spec 索引

| spec_id | 日期 | 目标 |
|---|---|---|
| ios-native-camera-module-load-20260425 | 2026-04-25 | 诊断原生模块未加载问题 |
| wysiwyg-dual-cam-photo-20260427 | 2026-04-27 | WYSIWYG 双摄拍照（VideoDataOutput 实时帧，3种保存比例） |
| dual-cam-photo-black-20260427 | 2026-04-27 | 双摄拍照全黑（renderInContext 黑帧 + capturePhoto 逻辑 bug） |
| dual-cam-sx-composite-fix-20260427 | 2026-04-27 | SX 上下双摄合成间隙修复 |
| ios-multicam-session-redesign-20260425 | 2026-04-25 | 双摄预览同时显示（MultiCam 重构） |
| dual-camera-video-fix-20260425 | 2026-04-25 | 视频无声音 + 前置摄像头录制失败 |
| dual-cam-compositing-20260425 | 2026-04-25 | 双摄画面合成保存（照片+视频） |
| xcode-runnability-audit-20260429 | 2026-04-29 | Xcode 可运行性审计（C++17 与 RN 0.81 冲突） |
| ios-no-script-url-20260429 | 2026-04-29 | 真机启动红屏（No script URL provided） |
| ios-no-script-url-planb-implementation-20260429 | 2026-04-29 | 方案B实施：Debug 离线启动兜底 |
| ios-no-script-url-planb-one-shot-fix-20260429 | 2026-04-29 | 方案B一次性修复包（One-Shot） |
| ios-local-network-denied-metro-status-20260429 | 2026-04-29 | iOS 本地网络拒绝（Metro /status -1009） |
| dual-cam-video-compositing-complete-fix-20260429 | 2026-04-29 | 双摄录制4条bug一次性修复（SX参数颠倒+backOffsetY+LR镜像+PiP scale） |
| dual-cam-pod-not-installed-20260429 | 2026-04-29 | DualCamera Pod未安装导致bug持续复现 |
| dual-cam-js-native-not-connected-20260429 | 2026-04-29 | 原生模块已编译链接但JS层未触发录制逻辑（无日志，待诊断） |
| dual-cam-one-shot-fix-20260429 | 2026-04-29 | 一次性修复：JS Bundle + AppDelegate + 插件 + native文件同步 |
|| dual-cam-photo-fix-20260430 | 2026-04-30 | 拍照逻辑一次性修复（单摄保存+B后置VideoDataOutput） |
|| dual-cam-wysiwyg-fix-20260430 | 2026-04-30 | 双摄WYSIWYG只保存后置（统一VideoDataOutput连接方式） |
| camera2-photo-exit-pip-mirror-20260430 | 2026-04-30 | 后置曝光+拍照退出+PiP位置+无镜像一次性修复 |

---

## 已知缺陷模式

### 单摄拍照无保存逻辑 — didFinishProcessingPhoto 回调被清空
- **首次发现**: 2026-04-30
- **spec_id**: dual-cam-photo-fix-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `AVCapturePhotoCaptureDelegate` 的 `didFinishProcessingPhoto:error:` 回调中，保存逻辑被注释/删除，只剩错误处理。
- **修复**: 补全保存逻辑，将 photo data 写入 Documents 目录并触发 `onPhotoSaved` 事件。
- **状态**: [FIXED]

### 双摄只保存前置 — 后置摄像头 VideoDataOutput 未添加到 session
- **首次发现**: 2026-04-30
- **spec_id**: dual-cam-photo-fix-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: 多摄模式下，前置摄像头有 `frontVideoDataOutput` 并添加到 session，但后置摄像头的 `backVideoDataOutput` 只创建了变量，**没有添加到 session**。导致 `latestBackFrame` 永远是 nil，双摄合成时 `!frontFrame || !backFrame` 条件成立，提前返回错误。
- **修复**: 将 `backVideoDataOutput` 用 `addOutputWithNoConnections:` 添加到 session，并创建连接到 `backVideoPort` 的 `AVCaptureConnection`。
- **状态**: [FIXED]

### 双摄 WYSIWYG 只保存后置 — VideoDataOutput 连接方式不一致
- **首次发现**: 2026-04-30
- **spec_id**: dual-cam-wysiwyg-fix-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `AVCaptureMultiCamSession` 要求使用统一的连接方式。前置使用 `addOutput:` + `connectionWithMediaType:`（可能在 MultiCam 上失败），后置使用 `addOutputWithNoConnections:` + 手动创建 connection。两者不一致导致 `canAddConnection:` 返回 NO。
- **修复**: 统一使用 `addOutputWithNoConnections:` + 手动创建 `AVCaptureConnection` 的模式，前置和后置都使用 `frontVideoPort`/`backVideoPort` 进行连接。
- **状态**: [FIXED]


### 双摄 WYSIWYG 拍照完整修复（2026-04-30）— 4 项独立 bug 一次性解决
- **首次发现**: 2026-04-30
- **spec_id**: dual-cam-wysiwyg-fix-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`, `my-app/ios/LocalPods/DualCamera/DualCameraView.m`
- **Bug 1 — 保存像素模糊**:
  - 根因：`canvasSizeForSaveAspectRatio` 使用固定 `refW = 390.0`（iPhone 点数），经 CIContext 渲染后约 390×693px，远低于摄像头原生分辨率（1440×1920px）。
  - 修复：`internalTakePhoto` 在主线程预先捕获 `self.bounds.size`，以 `screenWidth * 3.0` 作为基准（390pt → 1170px），保存质量提升 3 倍。
- **Bug 2 — 前置摄像头镜像错误**:
  - 根因：`captureOutput:didOutputSampleBuffer:` 中对前置 CIImage 施加水平镜像，但预览层已通过 `connection.videoMirrored = YES` 做了镜像，保存时再次镜像导致镜子里的像。
  - 修复：移除 `captureOutput` 中的前端镜像处理，直接存储原始帧。镜像完全由预览层 connection 处理。
- **Bug 3 — 预览与保存画面比例不一致**:
  - 根因：`compositeFront:back:toCanvas:` 用保存画布尺寸计算 split ratio，导致保存画面与预览不一致。
  - 修复：`compositeFront:...`，增加 `canvasForRatio` 参数，使用预览 canvas 尺寸计算 split ratio。
- **Bug 4 — 画中画位置错误**:
  - 根因：`compositeDualPhotosForCurrentLayout` 的 PiP 分支用硬编码像素值 `CGRectMake(canvasW - s - 16, canvasH - s - 160, s, s)`，而预览层 `updateLayout` 用归一化坐标公式 `cx = canvasW * pipPositionX`。两者不一致，导致预览右下角、保存右上角。
  - 修复：统一使用 `pipPositionX/Y` 归一化计算 PiP rect（`cx = canvasW * pipPositionX; cy = canvasH * pipPositionY; pipRect = CGRectMake(cx - s/2, cy - s/2, s, s)`）。
- **状态**: [FIXED]

### ⚠️ 前置摄像头镜像策略（2026-04-30）
- 预览层：`connection.videoMirrored = YES` 自动完成，无需额外代码。
- 拍照保存：存储 `captureOutput:didOutputSampleBuffer:` 中的**原始帧**，不在 CIImage 层做镜像。
- 视频合成：在 `AVMutableVideoCompositionLayerInstruction` 的 `frontTransform` 中显式加入镜像（`CGAffineTransformConcat(translation, scale(-1,1))`），因为录制的 .mov 不包含预览层镜像。
- **禁止**：在 `captureOutput` 中对 CIImage 做镜像，会导致双重镜像。

### ⚠️ CILanczosScaleTransform 的 aspectRatio 参数会破坏图像宽高比（2026-04-30）
- `CILanczosScaleTransform` 的 `kCIInputAspectRatioKey` 默认为 `1.0`，强制输出 1:1 正方形。
- 正确做法：使用 `CIAffineTransform` 滤镜配合 `CGAffineTransformMakeScale(scaleX, scaleY)`。
- 注意：`CIAffineTransform` 会改变 CIImage 的 extent origin，需要平移校正。

### ⚠️ dispatch_sync 在 sessionQueue 中访问 UIView bounds（2026-04-30）
- `sessionQueue` 是串行队列，其线程不是主线程。`dispatch_sync(dispatch_get_main_queue(), ...)` 在 `sessionQueue` 上执行不会死锁，但**禁止**在主线程本身调用。
- 正确模式：`__block` 变量 + `dispatch_sync(dispatch_get_main_queue(), ...)` 在 `sessionQueue` dispatch 之前执行。

### ⚠️ UIView.bounds 禁止从后台线程访问（2026-04-28）
- `UIView.bounds` 必须在主线程访问。在后台队列（如 `sessionQueue`）中需要使用 `dispatch_sync(dispatch_get_main_queue(), ...)` 预先捕获尺寸。

### ⚠️ AVCaptureVideoDataOutput 必须显式设置 videoOrientation（2026-04-28）
- 同 KB 原有条目，保持不变。

### ⚠️ 视频合成中前置摄像头必须手动添加水平镜像（2026-04-29）
- 同 KB 原有条目，保持不变。

### PiP 合成：必须使用归一化坐标，禁止硬编码像素偏移
|- **spec_id**: dual-cam-wysiwyg-fix-20260430
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`, `my-app/ios/LocalPods/DualCamera/DualCameraView.m`
|- **根因**: `compositeDualPhotosForCurrentLayout` 的 PiP 分支用硬编码像素值，与预览层 `updateLayout` 归一化公式不一致，导致保存位置与预览位置不符。
|- **修复**: `cx = canvasW * pipPositionX; cy = canvasH * pipPositionY; clamp 后 `CGRectMake(cx - s/2, cy - s/2, s, s)``。
|- **状态**: [FIXED]

### ⚠️ CIImage 镜像变换顺序错误导致 PiP 位置偏移（2026-04-30）
|- **spec_id**: dual-cam-wysiwyg-fix-20260430
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`, `my-app/ios/LocalPods/DualCamera/DualCameraView.m`
|- **根因**: `compositePIPFront` / `compositePIPForPhotos` 的镜像变换顺序为 `T(cx,cy) * S(-1,1) * T(cx,0)`（先放再镜像），导致镜像后图像原点偏移，合成结果 extent origin 非零（如 x=215），在 `createCGImage:fromRect:` 中被截断。`saveCIImageAsJPEG` 的平移只是治标，根因在变换顺序。
|- **修复**: 镜像顺序改为 `T(origin.x+s, origin.y) * S(-1,1) * T(-s,0)`（先镜像再平移），使图像原点自然回到 `(origin.x, origin.y)`，合成后 extent origin 为 `(0,0)`。同时在方法末尾加安全网平移。
|- **状态**: [FIXED]

### ⚠️ PiP 圆形布局未应用圆形 mask（2026-04-30）
|- **spec_id**: dual-cam-wysiwyg-fix-20260430
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`, `my-app/ios/LocalPods/DualCamera/DualCameraView.m`
|- **根因**: `compositePIPFront` / `compositePIPForPhotos` 未对 `pip_circle` 布局应用圆形裁剪，导致圆形预览但保存为方形。
|- **修复**: 在 `compositePIPFront` / `compositePIPForPhotos` 中判断 `isCircle` 参数，使用 `CIRadialGradient`（alpha 渐变 1→0）生成圆形 mask，通过 `CIBlendWithMask` + 白色画布将前置画面裁剪为圆形。helper 方法 `circleMaskAtCenter:radius:extentSize:` 和 `whiteCanvasSize:`。
|- **状态**: [FIXED]

### ⚠️ CIContext 合成结果 extent origin 可能非零点（2026-04-30）
|- **spec_id**: dual-cam-wysiwyg-fix-20260430
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`, `my-app/ios/LocalPods/DualCamera/DualCameraView.m`
|- **根因**: `scaledCIImage` 虽然在函数内部做了 extent origin 平移，但镜像变换顺序错误导致合成后 CIImage extent origin 再次偏移（非零）。`createCGImage:ciImage fromRect:ciImage.extent` 从该 origin 开始截取，导致画布整体偏移（如 x=215）。日志证据：`composited extent={{215, 0}, {1290, 2293}}`。
|- **修复**: 修正镜像变换顺序使 composited extent origin 自然为 (0,0)；`saveCIImageAsJPEG` 中保留平移安全网兜底。
|- **状态**: [FIXED]

### 后置摄像头严重曝光 — 缺少自动曝光配置（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-photo-exit-pip-mirror-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `configureDeviceForMultiCam:` 和 `configureSingleSessionForPosition:` 配置了设备格式、帧率、缩放因子，但**从未设置曝光模式**。`AVCaptureDevice` 默认曝光策略在某些设备/光照组合下可能产生严重过曝（白蒙蒙）。
- **修复**: 在两个方法中添加 `AVCaptureExposureModeContinuousAutoExposure` 配置。
- **状态**: [FIXED]

### 拍照点击直接退出 App — 多处缺少 autoreleasepool + 异常保护（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-photo-exit-pip-mirror-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: 4 条独立问题：
  1. `internalTakePhoto` 在 `sessionQueue` 的 `dispatch_async` 中大量 CIImage 操作，无 `@autoreleasepool`
  2. `capturePhotoWithSettings:delegate:` 无 `@try/@catch`
  3. `captureOutput:didFinishProcessingPhoto:error:` delegate 方法无 `@try/@catch`
  4. 合成子队列也无 `@autoreleasepool`
- **修复**: 全部 4 处添加 `@autoreleasepool {}` 和 `@try/@catch` 保护。
- **状态**: [FIXED]

### 前置摄像头镜像策略变更 — 彻底移除镜像（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-photo-exit-pip-mirror-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **用户需求**: 所有拍摄不做镜像处理，镜头里呈现什么样子保存为什么样子。
- **修复**: 移除预览层 `videoMirrored`、所有 `composite*` 方法中的镜像变换、视频合成的 `frontTransform` 镜像。
- **状态**: [FIXED]

### PiP 位置异常 — RCT_CUSTOM_VIEW_PROPERTY 缺失（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-photo-exit-pip-mirror-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m`
- **根因**: `pipSize`、`pipPositionX`、`pipPositionY`、`dualLayoutRatio` 未声明为 `RCT_CUSTOM_VIEW_PROPERTY`，React Native 无法将 JS 值同步到 native view。
- **修复**: 添加 4 个 `RCT_CUSTOM_VIEW_PROPERTY` 声明。
- **状态**: [FIXED]

### SX 保存位置与预览不一致 — sxBackOnTop flip 机制缺失（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-flip-zoom-drag-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **用户需求**: SX 模式下，默认后置摄像头在顶部；点击 flip 后前后互换位置；保存的图片必须与预览一致。
- **根因**: 原代码中 `updateLayout` 的 SX 分支固定分配 `_frontPreviewView` 到顶部、`_backPreviewView` 到底部，无法动态交换。保存时 `compositeFront:back:` 同样固定分配，无法响应 flip 状态。
- **修复**: 引入 `sxBackOnTop` 布尔属性（DualCameraView）、`updateLayout` 根据该属性动态分配 front/back 的垂直位置、`compositeFront:back:` 的 SX 分支根据该属性决定传入 `compositeSXFront:` 的参数顺序。JS 层通过 `sxBackOnTop={!isFlipped}` prop 传递 flip 状态。
- **关键洞察**: Preview 和 Save 必须使用完全一致的摄像头分配逻辑。Preview 通过 view frame 决定视觉位置；Save 通过 `compositeFront:` 的参数顺序决定合成时谁在顶部/左/主画面。
- **状态**: [FIXED]

### 圆形 PiP 拍照直接退出 App — CIBlendWithMask EXC_BAD_ACCESS（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-flip-zoom-drag-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **用户需求**: 圆形 PiP 拍照不崩溃。
- **根因**: `@try/@catch` 只能捕获 Objective-C exception（`NSException`），无法捕获 EXC_BAD_ACCESS（内存访问错误）。`CIBlendWithMask` 在某些边界情况下（nil 输入、extent origin 不为0）会触发 GPU 内存访问错误，导致进程被 SIGABRT 杀死。
- **修复**: 在 `compositePIPFront` 和 `compositePIPForPhotos` 的 `isCircle` 分支中，将 `CIBlendWithMask` 调用包裹在 `@autoreleasepool { @try { ... } @catch }` 中。如果滤镜返回 nil 或 extent 无效，fallback 到不做圆形裁剪（保留方形 PiP）。
- **状态**: [FIXED]

### 方形 PiP 后置摄像头变白背景 — latestBackFrame nil + blackCanvasSize（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-flip-zoom-drag-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **用户需求**: 方形 PiP 中后置摄像头正常显示，不变白。
- **根因**: `backVideoDataOutput` 在某些 `AVCaptureMultiCamSession` 配置路径下可能因 `canAddConnection:NO` 而未成功连接到 `backVideoPort`，导致 `latestBackFrame` 为 nil。后续合成时，`backFull` CIImage 为 nil，`imageByCompositingOverImage` 使用 nil → 结果为黑色或白色背景色（取决于 CIImage nil 的处理）。
- **修复**: 在 `compositePIPFront` 和 `compositePIPForPhotos` 的 back 合成分支中，检查 `back` 是否为 nil，若为 nil 则使用 `blackCanvasSize:` 创建黑色背景替代白色画布。添加 `blackCanvasSize:` helper 方法（与 `whiteCanvasSize:` 对应，生成黑色 RGBA CIImage）。
- **状态**: [FIXED]

### 视频合成内存泄漏 — compositingQueue 缺少 @autoreleasepool（2026-04-30）
- **首次发现**: 2026-04-30
- **spec_id**: camera2-flip-zoom-drag-20260430
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `compositeDualVideosForCurrentLayout` 中的 `dispatch_async(self.compositingQueue, ^{ ... })` 块处理大量 AVAsset、CIImage 对象，但 `dispatch_async` 队列不会自动创建 autoreleasepool，导致中间创建的 autorelease 对象无法及时释放，在视频合成完成后才释放，可能导致内存压力。
- **修复**: 在 `captureOutput:didFinishRecordingToOutputFileAtURL:` 的 `compositingQueue` dispatch block 周围添加 `@autoreleasepool {}` 包裹。
- **状态**: [FIXED]

## 架构陷阱与注意事项

### Preview 和 Save 的摄像头分配必须严格对称
在 dual-cam 模式下，Preview（通过 `updateLayout` 的 frame + hidden 状态）和 Save（通过 `compositeFront:back:` 的参数顺序）必须使用完全一致的决定逻辑。任何 flip 机制必须在两端同时生效，否则保存的图片与预览不一致。

### PiP 翻转不需要重建 Session
PiP flip 时，只需要在 native 层切换 `_backPreviewView` 和 `_frontPreviewView` 的 frame（主画面 vs 小窗口），无需重建 AVCaptureMultiCamSession，也无需重新配置 VideoDataOutput 连接。这比重建 session 更快、更稳定。

### CIBlendWithMask 必须配合 nil 检查 + @try/@catch
任何使用 `CIBlendWithMask` 的代码都应该：
1. 检查所有输入 CIImage 是否为 nil
2. 用 `@autoreleasepool { @try { ... } @catch }` 包裹
3. 检查输出是否为 nil 或 extent 无效，fallback 到不执行滤镜

### RCT_CUSTOM_VIEW_PROPERTY 是 JS→Native 通信的唯一可靠途径
对于任何需要在 JS 层控制 native view 行为的属性（如 `dualLayoutRatio`、`pipSize`、`sxBackOnTop`、`pipMainIsBack`），必须通过 `RCT_CUSTOM_VIEW_PROPERTY` 声明，否则 JS 传递的值无法到达 native view。

### LR/SX 独立双 zoom — 单 bar + 摄像头切换按钮（2026-05-01）
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/App.js`
|- **问题**: LR/SX 两个摄像头各自独立 zoom，UI 如何展示两套档位栏？
|- **方案否决**: 每区域各自显示一套 zoom bar（竖屏空间太窄，遮挡画面，UX 割裂）。
|- **最终方案**: 单 zoom bar + 摄像头切换按钮（`[后置▼]` / `[前置▼]`）。`activeZoomTarget` state 控制当前 bar 对应的摄像头（`'primary'` 主区域 / `'secondary'` 次区域）。点击切换按钮 → `effectiveCamera` 变化 → bar 显示正确档位。
|- **layout 切换时**: `handleModeSwitch` 中 `setActiveZoomTarget('primary')` 重置。
|- **状态**: [TODO]

### PiP zoom bar 跟随小窗 — 相对定位算法（2026-05-01 终版确认）
||- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
||- **文件**: `my-app/App.js`, `my-app/native/LocalPods/DualCamera/DualCameraEventEmitter.m`
||- **问题**: 用户将 PiP 小窗拖到任意位置，zoom bar 如何跟随又不被遮挡？
||- **终版方案**: bar 放在小窗左侧，竖向排列（`flexDirection: 'column'`，每行一个档位）。`barLeft = 小窗中心X - 小窗宽度/2 - bar宽度 - 8`。`barTop = 小窗中心Y - bar高度/2`。`clamp` 防止 bar 超出屏幕边界。`transition: left 0.1s ease-out, top 0.1s ease-out` 实现动画。
||- **竖向排列优势**: 竖排宽度仅 44px，适合放在小窗左侧窄空间；横排约 170px 空间不足。
||- **Native 同步**: `UIGestureRecognizerStateEnded` 时 `sendPipPositionChanged:y:` 事件通知 JS，JS 更新 `pipPosition` state。
||- **状态**: [TODO]


### PiP 拖动时手势识别器的启用/禁用逻辑（2026-05-01）
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
|- **问题**: `_frontPreviewView` 在 `pipMainIsBack=YES` 时是小窗，`pipMainIsBack=NO` 时是主画面。拖动手势应何时启用？
|- **方案**: 在 `setPipMainIsBack:` setter 中动态添加/移除手势。当 `_frontPreviewView` 是小窗时（`pipMainIsBack=YES`），`_frontPreviewView` = 小窗 → 启用拖动。当 `_frontPreviewView` 是主画面时（`pipMainIsBack=NO`），`_frontPreviewView` = 主画面 → 禁用拖动。
|- **实现**: 给每个 gesture recognizer 设置 `enabled = self.pipMainIsBack`。
|- **状态**: [TODO]

### PiP 布局切换时位置/大小重置（2026-05-01）
|- **spec_id**: camera2-aspect-ratio-pip-drag-zoom-20260501
|- **文件**: `my-app/App.js`
|- **用户决策**: 切换布局模式后，PiP 位置/大小重置为默认值。
|- **实现**: `handleModeSwitch` 中同时设置 `setPipSize(0.28)` + `setPipPosition({ x: 0.85, y: 0.80 })`。
|- **关键**: `_pipPositionX/Y` 通过 JS→Native prop 同步，Native 侧无需额外逻辑。
|- **状态**: [TODO]


### AVCaptureMovieFileOutput nil 陷阱 — 实例变量赋值顺序导致静默失败
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `configureAndStartMultiCamSession` 中，`AVCaptureMovieFileOutput *backMovieOutput` 是**局部变量**。如果 `addOutput:...` 失败，局部变量被设为 `nil`，但 `ok` 仍为 `YES`，最终 `self.backMovieOutput = backMovieOutput` 将 `nil` 写入实例变量。后置摄像头录制静默失败。
- **修复**: 在 if/else 块内**立即赋值** `self.backMovieOutput`（成功时）或 `nil`（失败时），并添加 guard：`if (!self.backMovieOutput || !self.frontMovieOutput) { ok = NO; }`
- **状态**: [FIXED]

### 音频录制后置策略 — 只录后置摄像头麦克风
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **设计决策**: 双摄视频只保留后置摄像头的音频轨。符合用户选择（A: 只保留后置音频).
- **状态**: [BY_DESIGN]

### 视频输出分辨率自适应
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **设计决策**: 分辨率由 `canvasSizeAtRecording` 决定（`self.bounds.size`），不强制固定 1080p。符合用户选择（B: 保持自适应）。
- **状态**: [BY_DESIGN]

### 视频合成 30fps — preferredTransform 显式设置
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **修复**: `AVMutableCompositionTrack` 插入轨道后显式设置 `track.preferredTransform = sourceTrack.preferredTransform`，确保输出帧率与录制帧率一致（30fps）。
- **状态**: [FIXED]

### 前置摄像头不保存 — configureDeviceForMultiCam 对前后置错误应用 _backZoomFactor
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `configureDeviceForMultiCam:error:` 被调用两次（前置+后置），但内部第 901 行固定使用 `device.videoZoomFactor = _backZoomFactor`，无论哪个设备传入。前置摄像头收到的是 `_backZoomFactor`（可能是 1.0~5.0），超出前置支持范围（通常 1.0~3.0）导致 zoom 静默失败。
- **修复**: 在方法内判断 `device.position == AVCaptureDevicePositionBack` 来应用 `_backZoomFactor` 或 `_frontZoomFactor`，并 clamp 到 `[minAvailableVideoZoomFactor, maxAvailableVideoZoomFactor]`。
- **状态**: [FIXED]

### 后置摄像头 zoom 与预览不同步 — VideoDataOutput 连接未考虑 zoom 变化
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: `dc_setBackZoom` 正确更新了 `device.videoZoomFactor`，但 `AVCaptureVideoDataOutput` 在 session 初始化时已建立连接，zoom 变化后连接状态可能不同步。
- **修复**: 在 `configureDeviceForMultiCam` 中正确设置 zoom 后，确保 session 启动时两个摄像头都在正确的初始 zoom 状态。
- **状态**: [FIXED]

### LR/SX 布局前置 scale 用后置 naturalSize — 画面严重失真
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: LR/SX 布局中前置摄像头 scale 计算错误使用 `canvasH / refH`（`refH` 是后置 naturalSize），前置 1420×1920 vs 后置 1920×1440，导致前置画面极度拉伸或压缩。
- **修复**: 前置统一使用前置自身的 naturalSize（已在 PiP 中正确实现，LR/SX 补齐）。
- **状态**: [FIXED]

### videoSizeForAsset 不考虑 preferredTransform 旋转
- **首次发现**: 2026-05-01
- **spec_id**: dual-cam-video-recording-fix-20260501
- **文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- **根因**: 前置摄像头录制文件 naturalSize 可能是横向（1080×1920 rotated），直接使用会得到错误的宽高比。
- **修复**: `videoSizeForAsset` 方法加入 `preferredTransform` 旋转校正：`w = |a*c + c*w|`，`h = |b*w + d*h|`。
- **状态**: [FIXED]
