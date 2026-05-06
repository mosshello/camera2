# 双摄录制只保存前置 + 画面与预览不一致 — 完整根因分析与一次性修复方案

**spec_id**: dual-cam-video-compositing-complete-fix-20260429
**日期**: 2026-04-29
**优先级**: P0
**用户要求**: 拍摄中的画面和保存的画面必须完全一致（WYSIWYG），不能出现与布局定义不符的情况

---

## 问题描述

双摄布局（lr/sx/pip）录制视频时，存在两个独立问题：
1. **只保存了前置摄像头的画面**（后置完全丢失）
2. **保存的画面与预览不一致**（与布局定义不符）

---

## 完整根因分析：视频合成管道全链路追踪

### 管道概览

```
录制阶段
  frontMovieOutput → dual_front_xxx.mov  (前置摄像头原始 .mov)
  backMovieOutput  → dual_back_xxx.mov  (后置摄像头原始 .mov)
       ↓
合成阶段
  frontAsset = dual_front_xxx.mov → frontVideoTrack
  backAsset  = dual_back_xxx.mov  → backVideoTrack
       ↓
  compositingQueue → compositeDualVideosForCurrentLayout
       ↓
  AVAssetExportSession → dual_composited_xxx.mp4
```

---

## Bug 1（SX 致命）：`layerInstructions` 参数颠倒 → 只保存前置

**文件**: `DualCameraView.m`
**位置**: 第 1200 行

```objc
// 错误（当前）
instruction.layerInstructions = [self layersWithBack:frontVideoTrack front:backVideoTrack];

// 方法签名
- (NSArray<...> *)layersWithBack:(AVMutableCompositionTrack *)backTrack
                            front:(AVMutableCompositionTrack *)frontTrack
```

**分析**：传参 `frontVideoTrack` 给 `backTrack`，`backVideoTrack` 给 `frontTrack`，完全颠倒。

`layersWithBack:front:front:` 实现：
```objc
AVMutableVideoCompositionLayerInstruction *back  = [self layerForTrack:frontVideoTrack]; // 前置 track
AVMutableVideoCompositionLayerInstruction *front = [self layerForTrack:backVideoTrack];  // 后置 track
[layers addObject:back];   // layers[0] = 前置
[layers addObject:front];  // layers[1] = 后置
```

**AVMutableVideoComposition z-order 规则**：index=0 底部（最先合成），index=1 顶部（最后合成，遮盖下方）。

| layers 数组 | 实际内容 | 实际 z-order |
|------------|---------|-------------|
| [0]（底部）| 前置摄像头（但使用 `backTransform`）| 底部 |
| [1]（顶部）| 后置摄像头（但使用 `frontTransform`）| 顶部 |

后置摄像头（完全不透明）在顶部叠在前置之上，完全遮盖前置。

**为什么后置录制是 nil**：检查 `configureAndStartMultiCamSession` 第 432-439 行：

```objc
if (![self addOutput:backMovieOutput forPort:backVideoPort toSession:...]) {
    backMovieOutput = nil;  // ← 局部变量被设为 nil
}
...
self.backMovieOutput = backMovieOutput;  // ← 实例变量被赋 nil
```

当 `addOutput` 失败（`AVCaptureMultiCamSession` 有同时输出数量限制）时，`backMovieOutput` 实例变量为 nil，`startRecording` 在 nil 上调用方法，后置摄像头不录制。`frontMovieOutput` 因为多路输出数量充足而成功。

**结果**：前置录制成功（不为 nil），后置录制失败（为 nil）。front 层虽然被遮盖，但 back 层无内容 → 前置画面透过显示。

---

## Bug 2（SX）：`backOffsetY` 多加了 `topHeight`

**文件**: `DualCameraView.m`
**位置**: 第 1179 行

```objc
// 错误（当前）
CGFloat backOffsetY = topHeight + (bottomHeight - backFillH) / 2;

// 正确（修复后）
CGFloat backOffsetY = (bottomHeight - backFillH) / 2;
```

`CGAffineTransformMakeScale` + `CGAffineTransformTranslate` 的语义是**先 scale 后 translate**。back 变换链是 `translate(0, backOffsetY) * scale`。translate 作用于已经 scale 过的坐标系，不是直接像素偏移。正确偏移应为 `(bottomHeight - backFillH) / 2`（居中裁剪），`topHeight` 不应出现。

---

## Bug 3（LR + PiP）：前置摄像头录制时未做水平镜像

**文件**: `DualCameraView.m`
**位置**: `compositeDualVideosForCurrentLayout` 方法

**问题根因**：
- `AVCaptureVideoPreviewLayer` 在配置时通过 `connection.videoMirrored = YES` 做水平镜像
- `AVCaptureMovieFileOutput` 录制的原始 `.mov` 文件**不包含**预览层的镜像变换
- 合成时，前置摄像头的内容在保存的视频中是**未镜像**的（原始的"镜子里"的像），与预览不一致

**修复方法**：在 `frontTransform` 中加入水平镜像。

前置摄像头内容原始坐标 [0, refW]，需要映射到 [leftWidth, leftWidth+rightW]（LR）或 [pipX, pipX+s]（PiP）。关于 x = leftWidth 做镜像：
```
镜像公式：translate(leftWidth, 0) * scale(-1, 1) * translate(-leftWidth, 0)
```
等价于 `translate(leftWidth, 0) * scale(-1, 1)`（直接关于目标位置镜像）。

---

## Bug 4（PiP）：前置摄像头 scale 计算使用错误的 ref 尺寸

**文件**: `DualCameraView.m`
**位置**: 第 1221-1223 行

```objc
// 错误（当前）— 使用后置摄像头的 naturalSize 作为参考
CGFloat frontScaleX = s / refW;
CGFloat frontScaleY = s / refH;
CGFloat frontScale = MIN(frontScaleX, frontScaleY);

// 正确（修复后）— 使用前置摄像头自身的 naturalSize
CGFloat frontOrigW = refW;  // 前置摄像头 naturalSize.width
CGFloat frontOrigH = refH;  // 前置摄像头 naturalSize.height
CGFloat frontScaleX = s / frontOrigW;
CGFloat frontScaleY = s / frontOrigH;
CGFloat frontScale = MIN(frontScaleX, frontScaleY);
```

`refW` 和 `refH` 是从 `backAsset`（后置摄像头）获取的 `AVAssetTrack.naturalSize`，用于前置摄像头会导致比例严重失真。

---

## 一次性修复方案（4 个改动）

### Fix 1: SX — `layerInstructions` 参数顺序（第 1200 行）

```objc
// 修复前
instruction.layerInstructions = [self layersWithBack:frontVideoTrack front:backVideoTrack];

// 修复后
instruction.layerInstructions = [self layersWithBack:backVideoTrack front:frontVideoTrack];
```

### Fix 2: SX — `backOffsetY` 移除多余的 topHeight（第 1179 行）

```objc
// 修复前
CGFloat backOffsetY = topHeight + (bottomHeight - backFillH) / 2;

// 修复后
CGFloat backOffsetY = (bottomHeight - backFillH) / 2;
```

### Fix 3: LR + PiP — 前置摄像头添加水平镜像

**LR 布局**（第 1145-1146 行，替换）：

```objc
// 修复前
CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
frontTransform = CGAffineTransformTranslate(frontTransform, frontOffsetX, 0);

// 修复后
CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
frontTransform = CGAffineTransformConcat(
    CGAffineTransformMakeTranslation(frontOffsetX + leftWidth, 0),
    CGAffineTransformMakeScale(-1, 1));
```

**PiP 布局**（第 1228-1229 行，替换）：

```objc
// 修复前
CGAffineTransform frontTransform = CGAffineTransformMakeScale(frontScale, frontScale);
frontTransform = CGAffineTransformTranslate(frontTransform, frontOffsetX, frontOffsetY);

// 修复后
CGAffineTransform frontTransform = CGAffineTransformConcat(
    CGAffineTransformMakeTranslation(frontOffsetX + pipRect.size.width, frontOffsetY),
    CGAffineTransformMakeScale(-1, frontScale));
```

### Fix 4: PiP — 前置摄像头 scale 使用自身尺寸（第 1221-1223 行）

```objc
// 修复前
CGFloat frontScaleX = s / refW;
CGFloat frontScaleY = s / refH;
CGFloat frontScale = MIN(frontScaleX, frontScaleY);

// 修复后
// frontOrigW/OrigH 从 frontAsset 获取（前置摄像头自身的 naturalSize）
// 如果 frontAsset.track 自然尺寸已知，直接使用；否则 fallback 到 refW/refH
CGFloat frontOrigW = frontOrigWidth > 0 ? frontOrigWidth : refW;
CGFloat frontOrigH = frontOrigHeight > 0 ? frontOrigHeight : refH;
CGFloat frontScaleX = pipRect.size.width / frontOrigW;
CGFloat frontScaleY = pipRect.size.height / frontOrigH;
CGFloat frontScale = MIN(frontScaleX, frontScaleY);
```

需要从 `frontAsset` 获取 `AVAssetTrack.naturalSize`：

```objc
// 在 PiP 分支开头获取前置的 naturalSize
CGSize frontNaturalSize = [self videoSizeForAsset:frontAsset];
CGFloat frontOrigW = frontNaturalSize.width;
CGFloat frontOrigH = frontNaturalSize.height;
```

---

## 受影响文件清单

| 文件 | 改动 |
|------|------|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | Fix 1 (第1200行)、Fix 2 (第1179行)、Fix 3 (第1145-1146行、第1228-1229行)、Fix 4 (第1221-1223行 + 新增变量) |

无 JS 层改动、无其他 Native 文件改动。

---

## 验证方案

| 测试用例 | 预期结果 |
|---------|---------|
| LR 布局录制 | 左右两侧画面与预览一致，前置水平镜像正确 |
| SX 布局录制 | 上下两半画面与预览一致，前置在顶部，后置在底部 |
| PiP 布局录制 | 大画面（后置）与预览一致，小窗内前置镜像正确、比例正确 |
| 单摄 back 录制 | 不受影响（单摄路径完全独立）|
| 单摄 front 录制 | 不受影响 |
| 拍照（WYSIWYG）| 不受影响 |
