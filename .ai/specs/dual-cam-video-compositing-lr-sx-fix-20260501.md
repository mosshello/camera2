# 技术契约与架构设计书 — 双摄录制视频合成修复（左右/上下布局）

## 1. 问题概述

两个独立的录制保存 bug，同时存在于 `compositeDualVideosForCurrentLayout` 方法中：

| Bug | 用户现象 | 根因位置 |
|-----|---------|---------|
| Bug 1 — 左右录制 | 保存后只有后置摄像头画面，左侧约 30% 黑屏 | `mirrored:YES` 对前置做了水平镜像，与预览不对称 |
| Bug 2 — 上下录制 | 保存画面是横向的，比例也不对 | `canvasW = videoSize.width` 使用横向宽高 |

---

## 2. 数据模型层（Schema）

无变更。视频合成沿用现有的 `AVMutableVideoComposition` + `AVMutableVideoCompositionLayerInstruction` 架构。

---

## 3. 后端服务层（Native — `DualCameraView.m`）

### 2.1 Bug 1 修复 — 移除视频合成中的前置摄像头镜像

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**根因**: 2026-04-29 的 `mirrored:YES` 修复是为了解决"预览层做了镜像但 .mov 不包含镜像"的问题。但根据 2026-04-30 的决策变更（KB 条目：`前置摄像头镜像策略变更 — 彻底移除镜像`），所有拍摄不做镜像处理。视频合成中的 `mirrored:YES` 与最新策略冲突，导致前置摄像头画面在保存时被水平翻转（左右颠倒）。

**修复内容**:

- **第 1530 行**（LR 左右布局，`frontTransform`）：
  ```objc
  // 修复前
  mirrored:YES
  // 修复后
  mirrored:NO
  ```

- **第 1575 行**（SX 上下布局，`frontTransform`）：
  ```objc
  // 修复前
  mirrored:YES
  // 修复后
  mirrored:NO
  ```

- **第 1607 行**（PiP 画中画布局，`frontTransform`）：
  ```objc
  // 修复前
  mirrored:YES
  // 修复后
  mirrored:NO
  ```

**涉及文件**:
- `my-app/native/LocalPods/DualCamera/DualCameraView.m`

### 2.2 Bug 2 修复 — 强制 canvas 为纵向

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**根因**: `canvasW = videoSize.width` 直接使用 `videoSizeForAsset` 的宽高。当设备物理横向录制时，`AVCaptureMovieFileOutput` 的 `preferredTransform` 告知播放器旋转，但录制文件的原始 naturalSize 仍为横向（宽 > 高）。导致 `videoSize` 为横向，`canvasW > canvasH`，保存结果为横向视频。

**修复内容**:

第 1448–1449 行（`compositeDualVideosForCurrentLayout` 方法开头）：

```objc
// 修复前
CGFloat canvasW = videoSize.width;
CGFloat canvasH = videoSize.height;

// 修复后
// Ensure canvas is always portrait (h > w). If front camera recorded landscape
// (due to phone being physically rotated), transpose the dimensions so that
// saved video is always portrait — consistent with the user's shooting orientation.
CGFloat canvasW = (videoSize.height > videoSize.width) ? videoSize.width : videoSize.height;
CGFloat canvasH = (videoSize.height > videoSize.width) ? videoSize.height : videoSize.width;
```

**涉及文件**:
- `my-app/native/LocalPods/DualCamera/DualCameraView.m`

---

## 4. 前端交互层（View）

无变更。JS 层通过 `layoutMode` prop 控制布局，`currentLayout` 由 native 内部维护。

---

## 5. 全栈影响面分析

| 层级 | 影响 |
|------|------|
| Native video composition | ✅ 修复 `mirrored:YES` → `NO`；修复 canvasW/canvasH 横纵判断 |
| JS 层 | 无 |
| Pod 编译 | 无 |

---

## 6. 技术验证要点

### Bug 1 验证
1. 切换到左右布局（lr）双摄模式
2. 点击录制
3. 检查保存视频：前置在左半边、无黑屏、无水平镜像

### Bug 2 验证
1. 切换到上下布局（sx）双摄模式
2. 物理横向持握手机（landscape）
3. 点击录制
4. 检查保存视频：纵向（高 > 宽），比例为拍摄时的 9:16 竖屏

---

## 7. 相关已有 KB 条目

- `⚠️ 前置摄像头镜像策略变更 — 彻底移除镜像（2026-04-30）`: 所有拍摄不做镜像处理。视频合成中的前置镜像与该策略冲突。
- `⚠️ videoSizeForAsset 不考虑 preferredTransform 旋转（2026-05-01）`: `videoSizeForAsset` 已正确处理 preferredTransform 旋转，天然支持横向录制。
