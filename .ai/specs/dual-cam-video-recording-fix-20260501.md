# 双摄视频录制修复 — 技术契约与架构设计书

**spec_id**: dual-cam-video-recording-fix-20260501
**日期**: 2026-05-01
**状态**: 设计阶段
**优先级**: P0（阻塞用户核心使用场景）

---

## 背景与用户问题

用户报告双摄模式（LR/SX/PiP）录制视频时：
1. **保存的视频只有后置摄像头画面**，前置摄像头内容丢失
2. **分辨率不是 1080p**（期望输出）
3. **帧率不是 30fps**

---

## 一、代码现状分析

### 1.1 视频录制启动 — 架构正确

`internalStartRecording`（约 1899 行）正确地：
- 同时启动 `backMovieOutput` 和 `frontMovieOutput`
- 分别写入 `dual_back_*.mov` 和 `dual_front_*.mov`
- 设置 `isDualRecordingActive` 锁防止重复启动

**结论**：录制启动逻辑正确，不是根因。

### 1.2 视频合成 — 前置轨道可能丢失

`compositeDualVideosForCurrentLayout`（约 1344 行）合成逻辑：

```
composition.addTrack(frontVideoTrack)  ← layer[0] 底部
composition.addTrack(backVideoTrack)   ← layer[1] 顶部（遮盖下方）
```

**前置轨道丢失的可能路径**：

1. **LR 布局前置轨道 transform 错误**：前置 scale 计算用后置 naturalSize（已知 bug，2026-04-29 记录但可能未完全修复）

2. **session 配置路径**：`configureForDualMode` 中前置 camera 添加 `frontMovieOutput`，但某些配置路径（如设备不支持 MultiCam 的 fallback）可能跳过了前置 movie output 初始化

3. **frontMovieOutput 未正确连接到 session**：`AVCaptureMultiCamSession` 需要 `addOutput:forPort:toSession:` 而非普通 `addOutput:`。如果前置使用了错误方法，连接可能静默失败

4. **PiP 布局合成时前置视频轨尺寸为 0**：PiP 小窗前置使用硬编码 `refW/refH`，如果前置摄像头未成功初始化，轨道 naturalSize 为 (0,0)，scale 计算为除零

### 1.3 分辨率问题根因

当前合成输出尺寸 = `canvasW × canvasH`（由 `canvasSizeAtRecording` 决定）。

- `canvasSizeAtRecording` 在录制开始时从 `self.bounds` 捕获，但 portrait 模式下：
  - `UIScreen.main.bounds` = 393 × 852（iPhone 点数）
  - 渲染到 CIContext 输出约 393 × 852 像素
  - **远低于 1080p（1920 × 1080）标准**

修复方向：固定输出分辨率。9:16 输出 1080 × 1920，3:4 输出 1080 × 1440，1:1 输出 1080 × 1080。

### 1.4 帧率问题根因

`videoComp.frameDuration = CMTimeMake(1, 30)` 已正确设置 30fps。

但如果两个视频轨的原生帧率不一致（如前置 30fps、后置 60fps），`AVMutableVideoComposition` 的 `frameDuration` 只是渲染帧率，最终输出仍可能丢帧或混合。

需要在合成时对每个轨设置 `preferredTransform` 和 `preferredVolume`，并通过 `AVMutableVideoCompositionInstruction` 明确指定 `timeRange`。

---

## 二、待确认清单（需用户决策）

在实施前必须确认以下问题：

| # | 问题 | 选项 |
|---|---|---|
| Q1 | 分辨率标准 | A：固定 1080p（9:16=1080×1920）；B：保持当前自适应，按 saveAspectRatio 计算 |
| Q2 | 帧率处理 | A：强制 30fps（统一两个轨的帧率）；B：保留原生帧率 |
| Q3 | 音频策略 | A：只保留后置音频；B：同时录制两个音频轨并混音 |
| Q4 | 单摄模式视频 | 是否需要同步修复单摄模式的分辨率问题？ |

---

## 三、目标文件清单

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 修改 | 修复双摄视频合成、分辨率固定、帧率统一 |
| `my-app/native/LocalPods/DualCamera/DualCameraEventEmitter.m` | 无改动 | — |
| `my-app/ios/LocalPods/DualCamera/DualCameraView.m` | 同步 | 副本，同步 native 改动 |
| `my-app/App.js` | 无改动 | — |
| `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m` | 待确认 | 可能有 RCT_CUSTOM_VIEW_PROPERTY 需要补充 |

---

## 四、关键实现要点（草案）

### 4.1 前置轨道丢失修复

**诊断方法**：在 `compositeDualVideosForCurrentLayout` 入口处添加日志：
```objc
NSLog(@"[DualCamera] composite: frontPath=%@ backPath=%@", frontPath, backPath);
NSArray *fvt = [frontAsset tracksWithMediaType:AVMediaTypeVideo];
NSArray *bvt = [backAsset tracksWithMediaType:AVMediaTypeVideo];
NSLog(@"[DualCamera] front tracks=%lu, back tracks=%lu",
      (unsigned long)fvt.count, (unsigned long)bvt.count);
if (fvt.count > 0) {
  NSLog(@"[DualCamera] front naturalSize=%@", 
        NSStringFromCGSize(fvt.firstObject.naturalSize));
}
```

**预期结果**：如果 `fvt.count == 0`，说明前置录制文件损坏或为空。

**修复路径**（取决于诊断结果）：

**路径 A**（前置 .mov 文件为空或损坏）：
- 检查 `frontMovieOutput` 是否正确添加到 session
- 检查前置 `AVCaptureConnection` 是否包含视频端口
- 在 `configureForDualMode` 中验证前置 movie output 的 session 连接

**路径 B**（前置轨道存在但 transform 错误）：
- 检查 LR 布局的 `frontTransform` 计算
- 检查 PiP 布局的 `frontTransform` 是否使用前置自身的 naturalSize

**路径 C**（session 配置失败导致只有后置在录）：
- `configureForDualMode` 中添加错误处理：如果 `isUsingMultiCam = NO`（设备不支持），回退到单摄模式录制并告知用户

### 4.2 分辨率固定

```objc
// 固定输出分辨率（saveAspectRatio 控制宽高比）
+ (CGSize)fixedOutputSizeForAspectRatio:(NSString *)aspectRatio {
  if ([aspectRatio isEqualToString:@"9:16"]) {
    return CGSizeMake(1080, 1920); // 9:16
  } else if ([aspectRatio isEqualToString:@"3:4"]) {
    return CGSizeMake(1080, 1440); // 3:4
  } else {
    return CGSizeMake(1080, 1080); // 1:1
  }
}
```

在 `compositeDualVideosForCurrentLayout` 中：
```objc
CGSize outputSize = [DualCameraView fixedOutputSizeForAspectRatio:self.saveAspectRatio];
canvasW = outputSize.width;
canvasH = outputSize.height;
videoComp.renderSize = outputSize;
```

### 4.3 帧率统一

```objc
// 强制 30fps：所有轨的 timeRange 必须对齐，且 frameDuration 匹配
videoComp.frameDuration = CMTimeMake(1, 30);

// 如果前后轨原生帧率不一致，需要用 AVMutableCompositionTrack segements 处理
// 或使用 AVMutableVideoCompositionFrameDuration 统一
```

---

## 五、架构陷阱与注意事项

1. **`canvasSizeAtRecording` 必须在 `beginConfiguration` 之前捕获**：避免在 session 配置过程中读取 UIView bounds（必须主线程）

2. **分辨率固定不能影响预览**：预览始终由 `self.bounds` 决定，分辨率只在最终合成输出时应用

3. **PiP 小窗尺寸比例保持**：PiP 布局中，`pipSize` 是相对于 `canvasW` 的比例。分辨率变化后，小窗像素尺寸等比放大，但比例不变

4. **前后轨道 z-order**：AVMutableVideoComposition 中 layer[1]（后插入）遮盖 layer[0]（先插入）。LR 布局：前置在左（layer[0]），后置在右（layer[1]）→ 后置遮盖前置右侧；SX 布局同理

---

## 六、交互流程图（双摄视频录制）

```
用户点击录制
    │
    ▼
internalStartRecording
    │─ [isDualLayout?] ─Yes─▶ 同时 startRecordingToOutputFileURL
    │                              (backMovieOutput + frontMovieOutput)
    │                              isDualRecordingActive = YES
    │─ [isDualLayout?] ─No─▶ 单摄录制
    │
    ▼
用户点击停止
    │
    ▼
internalStopRecording
    │─ stopRecording() on backMovieOutput
    │─ stopRecording() on frontMovieOutput
    │
    ▼
captureOutput:didFinishRecordingToOutputFileAtURL:（两次回调）
    │─ 第一：标记 backFinished=YES
    │─ 第二：标记 frontFinished=YES + 两项都为YES → trigger
    │
    ▼
compositeDualVideosForCurrentLayout(frontPath, backPath)
    │─ 加载 frontAsset + backAsset
    │─ 固定 outputSize（saveAspectRatio → 1080p）
    │─ 添加 audio from backAsset
    │─ 添加 frontVideoTrack → layer[0]
    │─ 添加 backVideoTrack  → layer[1]
    │─ 计算 frontTransform + backTransform（按布局）
    │─ 统一 frameDuration=CMTime(1,30)
    │─ AVAssetExportSession 导出
    │
    ▼
emitRecordingFinished(file://path)
    │
    ▼
JS: onRecordingFinished → MediaLibrary.saveToLibraryAsync
```

---

## 七、验收标准

| # | 标准 | 验证方法 |
|---|---|---|
| V1 | LR/SX/PiP 录制后保存的视频包含**前后两个摄像头**的画面 | 用 QuickTime 或 VLC 打开保存的 .mp4，验证两个摄像头内容都可见 |
| V2 | 输出分辨率：9:16 → 1080×1920，3:4 → 1080×1440，1:1 → 1080×1080 | 用 ffprobe 或 MediaInfo 查看视频分辨率 |
| V3 | 帧率：30fps（前后轨一致） | 用 ffprobe 查看 `r_frame_rate` |
| V4 | 音频存在且来自后置摄像头 | 播放视频验证有声音 |
| V5 | 录制开始/停止不崩溃，不退出 App | 手动测试 10 次起停 |
| V6 | PiP 录制时前置/后置画面位置与预览一致 | 录制时拖动小窗，保存后验证位置 |
| V7 | LR 录制时左/右画面比例与预览一致 | 对比预览截图和保存视频 |
| V8 | SX 录制时上/下画面比例与预览一致 | 对比预览截图和保存视频 |
