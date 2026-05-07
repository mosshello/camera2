# Dual Camera WYSIWYG Recording Spec

## 背景

当前应用使用 `AVCaptureMultiCamSession` 同时预览前置和后置摄像头。JS 层通过 `DualCameraView` 属性传入布局参数，原生层在 `updateLayout` 中调整两个 `AVCaptureVideoPreviewLayer` 所在的 UIKit view。

用户反馈的问题是：选择左右、上下或画中画布局后，最终视频和拍摄时看到的预览不一致。

## 当前实现结论

### 数据路径

- 预览：`DualCameraView.updateLayout` 直接摆放 `_backPreviewView` 和 `_frontPreviewView`。
- 录制：前后摄像头分别通过 `AVCaptureMovieFileOutput` 录成两个临时文件。
- 导出：两个文件录制结束后，`compositeDualVideosForCurrentLayout:backPath:` 使用 `AVMutableVideoComposition` 重新生成一个合成视频。
- 拍照：双摄拍照改用 `AVCaptureVideoDataOutput` 的最新帧，再通过 Core Image 合成。

### 确定的不一致点

1. LR 预览与视频导出左右顺序相反。
   - 预览代码：`updateLayout` 中 `lr` 固定 `back` 在左，`front` 在右。
   - 视频导出代码：`compositeDualVideosForCurrentLayout` 中 `lr` 写成 `frontRect` 在左、`backRect` 在右。
   - 这会直接导致“选了左右布局，成片左右不对”。

2. LR 翻转状态没有进入视频导出。
   - JS 传入 `sxBackOnTop={... !isFlipped ...}`，原生 `dc_flipCamera` 也会切换 `sxBackOnTop`。
   - 预览的 `lr` 分支没有使用 `sxBackOnTop`，视频导出也没有按 `sxBackOnTop` 切左右。
   - 当前注释和实现互相冲突，说明这个属性被拿来同时表达 LR 和 SX，但没有统一语义。

3. PiP 翻转状态没有进入视频导出。
   - 预览支持 `pipMainIsBack=YES/NO`：后置主画面或前置主画面。
   - 视频导出 `pip_square/pip_circle` 分支始终把 `back` 当全屏、`front` 当小窗。
   - 拍照的 `compositeFront` 中 `pipMainIsBack == NO` 分支也没有真正交换参数，仍然调用同一个 `compositePIPFront:front back:back`。

4. 录制布局没有快照。
   - `internalStartRecording` 只保存了 `canvasSizeAtRecording`，但导出时继续读取 `self.currentLayout/self.dualLayoutRatio/self.pipSize/self.pipPositionX/self.pipPositionY/self.sxBackOnTop/self.pipMainIsBack`。
   - 如果录制期间切换布局、调整比例、拖动 PiP，最终导出会使用停止时或导出时的状态，不是开始录制时看到的状态。

5. 视频合成和预览使用两套几何算法。
   - 预览依赖 UIKit frame + `AVLayerVideoGravityResizeAspectFill`。
   - 视频导出用 `makeLayerTransformWithTargetRect` 手动计算 transform。
   - 两套算法长期维护会持续产生边缘差异，尤其是裁切、镜像、旋转和画中画圆角。

## 外部调研

- Apple `AVMultiCamPiP` 样例的目标是使用 `AVCaptureMultiCamSession` 同时捕获多个摄像头，并录制到单个 movie 文件。
- WWDC 2019 多摄介绍明确提到双 `VideoDataOutput`，再把两路画面合成为一个视频 buffer，然后交给 `AVAssetWriter` 写成单个视频轨。
- DoubleTake by FiLMiC 支持 Split View 和 Picture-in-Picture，成片无需后期即可得到分屏或画中画。
- 现有双摄产品常见能力包括 PiP、side-by-side、top/bottom、录制时切布局、保存单个合成文件，部分产品还提供前后摄像头独立文件导出。

## 唯一推荐方案

唯一推荐方案是：把“预览布局”和“成片布局”收敛到同一个布局模型，并改成实时合成写入单个视频文件。

不再继续沿用“前后摄像头各录一个临时文件，结束后再用 `AVMutableVideoComposition` 二次导出”的路线。这个路线可以局部修补，但它天然有两套几何计算、导出等待、状态快照和录制中布局变化难以同步的问题，不适合作为最终架构。

### 架构目标

使用两个 `AVCaptureVideoDataOutput` 分别接收前后摄像头帧，在原生层维护一个 `DualCameraLayoutState`，每帧根据同一份布局状态合成到一个目标像素 buffer，再用 `AVAssetWriter` 写入一个视频轨。音频通过 `AVAssetWriterInput` 写入同一个文件。

这个方案必须满足：

- 所见即所得最稳定，预览和录制可共用同一份几何函数。
- 不需要结束录制后再等二次导出。
- 支持录制中切换布局，布局变化能按时间实时写入成片。
- 后续可自然支持水印、滤镜、边框、圆形 PiP、独立导出等能力。

### 设计代价

- 实现复杂度高于当前 `MovieFileOutput + AVMutableVideoComposition`。
- 需要处理帧同步、丢帧策略、音视频时间戳、像素缓冲池和性能。
- 建议使用 Core Image 起步，性能瓶颈出现后再迁移 Metal。

## 核心设计

### 1. 统一布局状态

新增 `DualCameraLayoutState`，作为预览、拍照、录制的唯一布局事实来源。

字段：

- `layoutMode`
- `dualLayoutRatio`
- `pipSize`
- `pipPositionX`
- `pipPositionY`
- `sxBackOnTop`
- `pipMainIsBack`
- `canvasSize`
- `outputSize`
- `frontMirrored`
- `backMirrored`

### 2. 统一布局几何函数

抽出共享 helper：

- `rectsForLayoutState:canvasSize:`
- `drawCameraFrame:camera:targetRect:mirrored:context:`
- `aspectFillRectForSourceSize:targetRect:`
- `maskForPipCircleIfNeeded:`

矩形规则：

- `back/front` 单摄：全画布。
- `lr`：
  - `sxBackOnTop == YES` 表示 back 在左、front 在右。
  - `sxBackOnTop == NO` 表示 front 在左、back 在右。
- `sx`：
  - `sxBackOnTop == YES` 表示 back 在上、front 在下。
  - `sxBackOnTop == NO` 表示 front 在上、back 在下。
- `pip`：
  - `pipMainIsBack == YES` 表示 back 全屏、front 小窗。
  - `pipMainIsBack == NO` 表示 front 全屏、back 小窗。

### 3. 实时录制管线

替换双 `AVCaptureMovieFileOutput`：

- 前置视频：`frontVideoDataOutput`
- 后置视频：`backVideoDataOutput`
- 音频：`AVCaptureAudioDataOutput`
- 合成：Core Image 先实现，必要时迁移 Metal
- 写入：`AVAssetWriter`
- 视频输入：`AVAssetWriterInput` + `AVAssetWriterInputPixelBufferAdaptor`
- 音频输入：`AVAssetWriterInput`

帧处理规则：

- 使用同一个输出尺寸，建议 MVP 固定 `1080x1920`、`30fps`。
- 以主时钟时间戳驱动写入，允许某一路摄像头短暂复用最近一帧。
- 当 writer backpressure 出现时，丢弃视频帧，不阻塞采集队列。
- 音频只写一份麦克风输入，不从两个 movie 文件复制音轨。

### 4. 镜像策略

当前目标是 WYSIWYG，因此前置预览和最终视频必须使用同一镜像策略。

- 如果前置预览不镜像，最终视频也不镜像。
- 如果产品后续决定自拍预览镜像，成片也必须镜像，除非 UI 明确告诉用户预览和成片方向不同。

### 5. 拍照路径

双摄拍照继续使用 `VideoDataOutput` 最新帧合成，但必须改为同一套 `DualCameraLayoutState` 和同一套布局 helper。这样照片和视频的布局规则一致。

## 实施顺序

1. 新增 `DualCameraLayoutState` 和共享布局 helper。
2. 修改 `updateLayout`，让预览矩形来自共享 helper。
3. 修改双摄拍照，使用共享 helper 合成图片。
4. 新增 `AVAssetWriter` 实时录制管线。
5. 移除双摄录制中的 `backMovieOutput/frontMovieOutput` 临时文件合成路径。
6. 加入录制日志、掉帧统计、writer 错误上报和真机验证。

## 验证矩阵

- LR 默认：back 左，front 右。
- LR 翻转：front 左，back 右。
- SX 默认：back 上，front 下。
- SX 翻转：front 上，back 下。
- PiP 默认：back 全屏，front 小窗。
- PiP 翻转：front 全屏，back 小窗。
- PiP 拖动：小窗位置与预览一致。
- PiP 缩放：小窗大小与预览一致。
- 前置镜像：预览和成片左右方向一致。
- 录制中调整布局：最终视频必须实时反映布局变化。

## 目标文件清单

- `my-app/native/LocalPods/DualCamera/DualCameraView.h`
- `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- `my-app/App.js`

## 参考资料

- Apple Developer: AVMultiCamPiP, Capturing from Multiple Cameras
- Apple Developer WWDC 2019: Introducing Multi-Camera Capture for iOS
- Macworld: DoubleTake by FiLMiC review
- App Store: SplitCam, Dual Camera Video App
- Double Camera MixCam product page
