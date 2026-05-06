# 双摄录制只保存前置摄像头画面 — Bug 分析与修复规格

**spec_id**: dual-cam-video-back-recording-bug-20260429
**日期**: 2026-04-29
**优先级**: P0 — 录制功能严重损坏

---

## Bug 现象

- 双摄布局（lr/sx/pip）下录制视频，最终保存的文件**只包含前置摄像头的画面**，后置摄像头内容完全丢失。
- 拍照（WYSIWYG）功能正常，双摄预览正常。

---

## 根因分析（两条独立 Bug）

### Bug 1（SX 布局致命）：`layerInstructions` 参数顺序颠倒

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
**位置**: `compositeDualVideosForCurrentLayout` 方法，约第 1200 行

**问题代码**:
```objc
// 第 1200 行 — 参数顺序颠倒！
instruction.layerInstructions = [self layersWithBack:frontVideoTrack front:backVideoTrack];
```

**方法签名**:
```objc
// 第 1036 行 — 正确签名
- (NSArray<AVMutableVideoCompositionLayerInstruction *> *)layersWithBack:(AVMutableCompositionTrack *)backTrack
                                                                  front:(AVMutableCompositionTrack *)frontTrack
```

**调用分析**:

| 布局 | 调用代码 | 效果 |
|------|---------|------|
| LR (正确) | `layersWithBack:backVideoTrack front:frontVideoTrack` | back 在底部，front 在上方 ✅ |
| PiP (正确) | `layersWithBack:backVideoTrack front:frontVideoTrack` | back 在底部，front 在上方 ✅ |
| **SX (错误)** | `layersWithBack:frontVideoTrack front:backVideoTrack` | 参数颠倒 ❌ |

**AVMutableVideoComposition 的 z-order 规则**：`layerInstructions` 数组中 index=0 的层在最底部（最先合成），index=n-1 的层在最顶部（最后合成，遮盖下方层）。

- SX 布局：front(前置) 本应显示在 y=0 到 y=topHeight，back(后置) 本应显示在 y=topHeight 到 y=canvasH
- 错误传入后：front 层在 index=0（底部），back 层在 index=1（顶部，遮盖 front）
- **后置画面完全遮盖前置画面**（back 层是不透明的），最终输出中前置不可见

---

### Bug 2（SX 布局）：`backOffsetY` 偏移量计算多加了 topHeight

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
**位置**: `compositeDualVideosForCurrentLayout` 方法，约第 1178–1179 行

**问题代码**:
```objc
// 第 1178-1179 行 — backOffsetY 错误地额外加了 topHeight
CGFloat backFillH = refH * backScale;
CGFloat backOffsetY = topHeight + (bottomHeight - backFillH) / 2; // ← topHeight 不应加
```

**正确推导**：
- `CGAffineTransformMakeScale` + `CGAffineTransformTranslate(tx, ty)` 的语义：**先 scale 后 translate**
- back 层填满 bottomHeight 高度，正确变换链：`translate(0, backOffsetY_correct) * scale`
- `backOffsetY_correct = (bottomHeight - backFillH) / 2`（居中裁剪/填充逻辑，不含 topHeight）
- 错误的 `backOffsetY = topHeight + (bottomHeight - backFillH) / 2` 会导致后置画面在 Y 方向偏移错误

---

### Bug 3（所有布局）：后置摄像头视频缺少水平镜像

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
**位置**: `compositeDualVideosForCurrentLayout` 方法，LR/PiP 的 `backTransform`

前置摄像头在录制时已做镜像（`captureOutput:didOutputSampleBuffer` 中），但合成的 `AVMutableVideoCompositionLayerInstruction` 中的 `backTransform` 没有镜像，导致录制的后置视频在合成输出中是"镜像"的（左右反转），与预览不一致。

---

## 修复方案

### Fix 1: 修正 SX 布局 `layerInstructions` 参数顺序

**文件**: `DualCameraView.m`，第 1200 行

```objc
// 修复前（错误）
instruction.layerInstructions = [self layersWithBack:frontVideoTrack front:backVideoTrack];

// 修复后（正确）
instruction.layerInstructions = [self layersWithBack:backVideoTrack front:frontVideoTrack];
```

### Fix 2: 修正 SX 布局 `backOffsetY` 偏移量

**文件**: `DualCameraView.m`，第 1178–1179 行

```objc
// 修复前（错误）
CGFloat backFillH = refH * backScale;
CGFloat backOffsetY = topHeight + (bottomHeight - backFillH) / 2;

// 修复后（正确）
CGFloat backFillH = refH * backScale;
CGFloat backOffsetY = (bottomHeight - backFillH) / 2;
```

### Fix 3（可选，后置视频镜像）

在 `compositeDualVideosForCurrentLayout` 方法的 LR/PiP 布局中，为 `backTransform` 添加水平镜像。

---

## 全栈影响面分析

| 层级 | 文件 | 改动 |
|------|------|------|
| 视图层 | `my-app/native/LocalPods/DualCamera/DualCameraView.m` | Fix 1, Fix 2（核心逻辑修复） |
| 视图管理器 | `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m` | 无需改动 |
| JS 桥接层 | `my-app/plugin/withDualCamera.js` | 无需改动 |
| JS 页面层 | 无 | 无需改动 |

---

## 验证方案

1. **双摄 SX 布局录制**：切换到 sx 布局，点击录制，停止，验证保存的视频同时包含前置和后置画面，且位置正确
2. **双摄 LR 布局录制**：同上
3. **双摄 PiP 布局录制**：同上
4. **拍照功能回归**：验证拍照（WYSIWYG）不受影响

---

## 与 KB 中已知缺陷的关联

- 本次 bug 与"双摄拍照全黑"（KB 条目 `dual-cam-photo-black-20260427`）**无关**，拍照使用 `AVCaptureVideoDataOutput` 实时帧，不经过视频合成路径
- 本次 bug 与"视频合成变换：禁止硬编码 scale factor"（KB 条目）**有关联**，属于视频合成路径中的另一类错误
