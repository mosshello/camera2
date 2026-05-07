# 技术契约与架构设计书 — 双摄录制视频合成三布局黑边/错位一次性修复

## 1. 问题概述

三个独立的录制保存 bug，同时存在于 `compositeDualVideosForCurrentLayout` 方法中：

| Bug | 用户现象 | 根因 |
|-----|---------|------|
| Bug 1 — 左右录制 | 保存视频左侧有黑色背景，右边正常；左右颠倒 | LR layout transform 错位：front camera 缩放基准用 `canvasH` 导致 scaledWidth > halfWidth，产生 gap；另 `sxBackOnTop` 逻辑未在 LR 中应用 |
| Bug 2 — 上下录制 | 保存视频左右布局，上下右均有黑色背景 | SX layout `sxBackOnTop` 逻辑缺失，保存时总是 back 在上、front 在下，与预览不一致 |
| Bug 3 — 画中画录制 | 保存视频左右布局，且有黑色背景 | PiP layout 使用了同样的 `makeLayerTransformWithTargetRect` 变换链，与 LR 有相同的 gap 问题 |

---

## 2. 数据模型层（Schema）

无变更。视频合成沿用 `AVMutableVideoComposition` + `AVMutableVideoCompositionLayerInstruction` 架构。

---

## 3. 后端服务层（Native — `DualCameraView.m`）

### 3.1 Bug 1 修复 — LR layout 变换链重建

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**根因**: LR 布局中，左半区域（`CGRectMake(0, 0, leftW, canvasH)`）和右半区域（`CGRectMake(leftW, 0, rightW, canvasH)`）的宽高比不一致：
- LR layout 下 canvas 是 portrait：`canvasW < canvasH`
- 左半：`leftW × canvasH`，比例 `leftW/canvasH < 1`（portrait）
- 右半：`rightW × canvasH`，比例 `rightW/canvasH < 1`（portrait）
- 后置摄像头 naturalSize 是 landscape（`backOrigW > backOrigH`），填满 canvasH 时 scaledWidth > leftW → 后置溢出到右半
- 前置摄像头用 `makeLayerTransformWithTargetRect`：计算 `scale = MAX(canvasH/backOrigH, leftW/backOrigW)` = `canvasH/backOrigH`（因为前置 portrait），再平移到右半中央，导致前置 scaledWidth = `frontOrigW * canvasH/frontOrigH` >> rightW，左侧 gap + 右侧 overflow

**修复内容**:

第 1518–1548 行（LR 分支）整体替换为独立的两套 transform，**不使用** `makeLayerTransformWithTargetRect`：

```objc
  } else if ([self.currentLayout isEqualToString:@"lr"]) {
    // LR: portrait canvas, split left/right
    // Left half: back camera fills height, scaled width may exceed leftW
    // Right half: front camera fills its half-width, NOT canvas height
    CGFloat leftW  = canvasW * ratio;
    CGFloat rightW = canvasW * (1 - ratio);

    // Back (left half): scale by canvasH (fill height), center in left half
    CGFloat backScaleByH = canvasH / backOrigH;
    CGFloat backScaledW = backOrigW * backScaleByH;
    CGFloat backOffsetX = (leftW - backScaledW) / 2.0; // center in left half

    CGAffineTransform backTransform = CGAffineTransformMakeTranslation(backOrigW / 2.0, backOrigH / 2.0);
    backTransform = CGAffineTransformRotate(backTransform, atan2(backSrcTransform.b, backSrcTransform.a));
    backTransform = CGAffineTransformConcat(backTransform, CGAffineTransformMakeScale(backScaleByH, backScaleByH));
    backTransform = CGAffineTransformTranslate(backTransform,
                                               backOffsetX - backOrigW / 2.0,
                                               -backOrigH / 2.0);

    // Front (right half): scale by RIGHT HALF width, NOT canvas height
    // This ensures front scaledWidth = rightW exactly, no gap, no overflow
    CGFloat frontScaleByHalfW = rightW / frontOrigW;
    // frontScaledH = frontOrigH * frontScaleByHalfW (≤ canvasH, fits vertically)
    // Center front vertically within right half
    CGFloat frontScaledH = frontOrigH * frontScaleByHalfW;
    CGFloat frontOffsetY = (canvasH - frontScaledH) / 2.0; // center vertically
    // Translate front to right half (x = leftW)
    CGFloat frontOffsetX = leftW; // front's left edge = leftW, no horizontal offset needed

    CGAffineTransform frontTransform = CGAffineTransformMakeTranslation(frontOrigW / 2.0, frontOrigH / 2.0);
    frontTransform = CGAffineTransformRotate(frontTransform, atan2(frontSrcTransform.b, frontSrcTransform.a));
    frontTransform = CGAffineTransformConcat(frontTransform, CGAffineTransformMakeScale(frontScaleByHalfW, frontScaleByHalfW));
    frontTransform = CGAffineTransformTranslate(frontTransform,
                                                frontOffsetX - frontOrigW / 2.0,
                                                frontOffsetY - frontOrigH / 2.0);

    AVMutableVideoCompositionLayerInstruction *frontLayer = [self layerForTrack:frontVideoTrack];
    AVMutableVideoCompositionLayerInstruction *backLayer  = [self layerForTrack:backVideoTrack];
    if (frontLayer) [frontLayer setTransform:frontTransform atTime:kCMTimeZero];
    if (backLayer)  [backLayer  setTransform:backTransform  atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = @[
      (id)(backLayer  ?: (id)[NSNull null]),  // layers[0] = back (left, bottom)
      (id)(frontLayer ?: (id)[NSNull null])    // layers[1] = front (right, top)
    ];
    videoComp.instructions = @[instruction];
```

### 3.2 Bug 2 修复 — SX layout 添加 `sxBackOnTop` 逻辑

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**根因**: SX 分支中 `sxBackOnTop` 逻辑缺失，保存时总是 back 在上（top）、front 在下（bottom），但预览中 `sxBackOnTop` 可通过 flip 切换，导致保存与预览不一致。

**修复内容**:

第 1550–1589 行（SX 分支）添加 `sxBackOnTop` 条件判断（与 `compositeFront:back:toCanvas:` 照片合成逻辑完全对称）：

```objc
  } else if ([self.currentLayout isEqualToString:@"sx"]) {
    // SX: portrait canvas, split top/bottom
    // sxBackOnTop=YES → back gets largeH region (top), front gets smallH (bottom)
    // sxBackOnTop=NO  → front gets largeH region (top), back gets smallH (bottom)
    CGFloat largeH  = canvasH * ratio;
    CGFloat smallH = canvasH * (1 - ratio);
    CGRect backRect, frontRect;
    if (self.sxBackOnTop) {
      backRect  = CGRectMake(0,         0, canvasW, largeH);  // back: top (large)
      frontRect = CGRectMake(0, largeH, canvasW, smallH);      // front: bottom (small)
    } else {
      frontRect = CGRectMake(0,         0, canvasW, largeH);  // front: top (large)
      backRect  = CGRectMake(0, largeH, canvasW, smallH);      // back: bottom (small)
    }

    // Scale each camera to fill its assigned region (by canvasW)
    // Back: scale by canvasW (fill width), center in backRect
    CGFloat backScaleByW = backRect.size.width / backOrigW;
    CGFloat backScaledH = backOrigH * backScaleByW;
    CGFloat backOffsetY = (backRect.size.height - backScaledH) / 2.0;
    CGAffineTransform backTransform = CGAffineTransformMakeTranslation(backOrigW / 2.0, backOrigH / 2.0);
    backTransform = CGAffineTransformRotate(backTransform, atan2(backSrcTransform.b, backSrcTransform.a));
    backTransform = CGAffineTransformConcat(backTransform, CGAffineTransformMakeScale(backScaleByW, backScaleByW));
    backTransform = CGAffineTransformTranslate(backTransform,
                                                -backOrigW / 2.0,
                                                backOffsetY - backOrigH / 2.0);

    // Front: scale by canvasW (fill width), center in frontRect
    CGFloat frontScaleByW = frontRect.size.width / frontOrigW;
    CGFloat frontScaledH = frontOrigH * frontScaleByW;
    CGFloat frontOffsetY = (frontRect.size.height - frontScaledH) / 2.0;
    CGAffineTransform frontTransform = CGAffineTransformMakeTranslation(frontOrigW / 2.0, frontOrigH / 2.0);
    frontTransform = CGAffineTransformRotate(frontTransform, atan2(frontSrcTransform.b, frontSrcTransform.a));
    frontTransform = CGAffineTransformConcat(frontTransform, CGAffineTransformMakeScale(frontScaleByW, frontScaleByW));
    frontTransform = CGAffineTransformTranslate(frontTransform,
                                                 -frontOrigW / 2.0,
                                                 frontOffsetY - frontOrigH / 2.0);

    AVMutableVideoCompositionLayerInstruction *frontLayer = [self layerForTrack:frontVideoTrack];
    AVMutableVideoCompositionLayerInstruction *backLayer  = [self layerForTrack:backVideoTrack];
    if (frontLayer) [frontLayer setTransform:frontTransform atTime:kCMTimeZero];
    if (backLayer)  [backLayer  setTransform:backTransform  atTime:kCMTimeZero];

    AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = timeRange;
    instruction.layerInstructions = @[
      (id)(backLayer  ?: (id)[NSNull null]),  // layers[0] = bottom (small or back)
      (id)(frontLayer ?: (id)[NSNull null])    // layers[1] = top (large or front)
    ];
    videoComp.instructions = @[instruction];
```

### 3.3 Bug 3 修复 — PiP layout 验证（canvas 修复后自动解决）

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**PiP 根因**: PiP 的 back 填充整个 canvas（`CGRectMake(0, 0, canvasW, canvasH)`），front 填充 PiP rect。由于 LR/SX 的 canvas 修复后 canvas 始终为 portrait（`canvasW < canvasH`），PiP 的计算会自然正确。无需额外修改。

---

## 4. 关键设计洞察

### 4.1 为什么 LR 用 `canvasH` 作为缩放基准会产生黑边

`makeLayerTransformWithTargetRect` 对 LR 的两个 half 都使用 `scale = MAX(scaleX, scaleY) = MAX(canvasH/frontOrigH, leftW/frontOrigW)`：

- **后置**：landscape（`backOrigW > backOrigH`），`canvasH/backOrigH < leftW/backOrigW`，取 `leftW/backOrigW` → scaledW = backOrigW × `leftW/backOrigW` = leftW ✅ 填满 leftW
- **前置**：portrait（`frontOrigW < frontOrigH`），`canvasH/frontOrigH > leftW/frontOrigW`，取 `canvasH/frontOrigH` → scaledW = frontOrigW × `canvasH/frontOrigH` = frontOrigW × `canvasH/frontOrigH` >> rightW（overflow）

前置 scaledW 溢出右半宽度，且因 centering transform，左侧在 leftW 处开始但 overflow 超出 canvas 右边界；后置因 overflow 也超出 canvas。两者均溢出 canvas 边界，互相遮盖导致 gap。

### 4.2 正确策略：各区域独立缩放

- **LR**：前置按 **rightW** 缩放（填满右半宽），后置按 **canvasH** 缩放（填满左半高）
- **SX**：前置按 **frontRect.width** 缩放，后置按 **backRect.width** 缩放，各自垂直居中

### 4.3 Canvas 维度策略

`canvasW/canvasH` 由前置摄像头录制文件的 `videoSizeForAsset` 决定。该函数已正确应用 `preferredTransform` 旋转校正，返回摄像头在屏幕上的有效像素尺寸。竖屏录制 → portrait canvas；横屏录制 → landscape canvas。无需额外 swap。

---

## 5. 前端交互层（View）

无变更。JS 层通过 `layoutMode` prop 控制布局，`sxBackOnTop` 通过 `flipCamera` 事件更新 native 状态，`currentLayout` 由 native 内部维护。

---

## 6. 全栈影响面分析

| 层级 | 影响 |
|------|------|
| Native video composition | ✅ LR 分支重建；SX 分支添加 sxBackOnTop；PiP 无需修改（canvas 修复后自动正确） |
| JS 层 | 无 |
| Pod 编译 | 无 |

---

## 7. 技术验证要点

### Bug 1 验证（LR）
1. 切换到左右布局（lr）双摄模式
2. 点击录制，保存后检查：
   - 左半边为后置摄像头画面，右半边为前置摄像头画面（无左右颠倒）
   - 左侧无黑色背景
   - 右侧无黑色背景
3. 预期：`backRect = CGRectMake(0, 0, leftW, canvasH)` + `frontScaleByHalfW = rightW / frontOrigW` → 前置正确填满右半

### Bug 2 验证（SX）
1. 切换到上下布局（sx）双摄模式
2. 默认状态（sxBackOnTop=YES）：后置在上，前置在下
3. 点击 flip：前端 `sxBackOnTop` 变为 NO，前后互换位置
4. 录制保存，检查保存视频的上下分布与预览一致
5. 预期：`sxBackOnTop=YES` → back 在 top；`sxBackOnTop=NO` → front 在 top

### Bug 3 验证（PiP）
1. 切换到画中画布局（pip_square 或 pip_circle）
2. 录制，保存后检查：
   - 主画面为全屏摄像头（无黑边）
   - PiP 小窗在正确位置（与预览一致）
   - 无左右颠倒
   - 无黑色背景
3. 预期：PiP 在 canvas 修复后自动正确

---

## 8. 涉及文件清单

| 文件 | 修改类型 |
|------|---------|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 修改 `compositeDualVideosForCurrentLayout` 的 LR 分支和 SX 分支 |

---

## 9. 相关已有 KB 条目

- `⚠️ CIImage 合成顺序：先 crop 再 scale（2026-04-27）`: 先 scale 再 crop 导致不同分辨率拼接线处出现间隙
- `⚠️ 视频合成变换：禁止硬编码 scale factor（2026-04-28）`: 必须从 `AVAssetTrack.naturalSize` 动态计算
- `⚠️ videoSizeForAsset 不考虑 preferredTransform 旋转（2026-05-01）`: 已修复，返回有效像素尺寸
- `⚠️ 前置摄像头镜像策略（2026-04-30）`: 所有拍摄不做镜像处理，合成中使用 `mirrored:NO`
- `左右录制保存只有后置 + 30% 黑屏（2026-05-01）`: `mirrored:YES` → `NO` 已修复（commit 中）
