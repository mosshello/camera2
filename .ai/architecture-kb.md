# Architecture Knowledge Base
# 架构知识库 — 记录已知缺陷模式和架构陷阱，防止重复踩坑

status: draft
last-verified: 2026-04-25

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

---

## 架构陷阱与注意事项

### AVCaptureMovieFileOutput 必须显式接入音频
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

### 视频合成变换：禁止硬编码 scale factor
`CGAffineTransformMakeScale(2.0, 1.0)` 是错误的占位代码。必须从 `AVAssetTrack.naturalSize` 动态计算 scale factor：
- LR/SX 布局：`scale = targetDimension / videoTrack.naturalSize.{width|height}`
- PiP 布局：`scale = targetPixelSize / videoTrack.naturalSize.{width|height}`
- `videoSize` 应取后置摄像头录制的 `naturalSize`（作为 renderSize 基准）

---

## 历史 Spec 索引

| spec_id | 日期 | 目标 |
|---|---|---|
| ios-native-camera-module-load-20260425 | 2026-04-25 | 诊断原生模块未加载问题 |
| ios-multicam-session-redesign-20260425 | 2026-04-25 | 双摄预览同时显示（MultiCam 重构） |
| dual-camera-video-fix-20260425 | 2026-04-25 | 视频无声音 + 前置摄像头录制失败 |
| dual-cam-compositing-20260425 | 2026-04-25 | 双摄画面合成保存（照片+视频） |
