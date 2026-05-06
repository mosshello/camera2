# DualCamera Pod 未安装导致录制 bug 持续复现

## 基本信息
- **spec_id**: dual-cam-pod-not-installed-20260429
- **日期**: 2026-04-29
- **状态**: [OPEN]

## 根因分析

### 直接原因
`DualCamera` Pod **从未被安装**到 `ios/Pods/` 目录中。

验证方法：
```bash
ls /Users/zhengxi/vibecoding/camera2/my-app/ios/Pods/ | grep -i dual
# 返回空 — Pod 未安装
```

同时 `ios/Podfile.lock` 中也没有 DualCamera 条目：
```bash
grep -i dual /Users/zhengxi/vibecoding/camera2/my-app/ios/Podfile.lock
# 返回空
```

### 为什么看起来"正常运行"但 bug 存在
用户运行的是**上一次成功构建的 app**（可能来自 xcarchive 或之前的 Debug build）。该 app 使用的是旧版本 DualCamera 源代码，包含所有 4 条 bug：
1. SX layoutInstructions 参数颠倒（back→front 传反）
2. SX backOffsetY 多加了 topHeight
3. LR/PiP 前置无水平镜像
4. PiP 前置 scale 使用后置 naturalSize

### 为什么没有 NSLog 输出
`DualCameraModule.startSession()` 调用链：
```
JS: DualCameraModule.startSession()
  → DualCameraSessionManager.startSession()
    → [_registeredView dc_startSession]
      → DualCameraView.dc_startSession → [self internalStartSession]
```

`_registeredView` 在 DualCameraView init 时通过 `[registerView:self]` 注册。如果 Pod 未安装，`DualCameraModule` native module 不存在，但 JS 层的 `requireNativeComponent('DualCameraView')` 可能通过 fallback 渲染了某个视图。

**更可能的原因**：用户通过 Xcode 直接运行的 app（使用 workspace）包含了部分编译的旧代码。Native module 加载失败时 JS 层有 fallback，相机预览可能通过其他方式（如 expo-camera）实现。

### KB 中相关已记录修复的状态
| spec_id | 状态 | 说明 |
|---|---|---|
| dual-cam-video-compositing-complete-fix-20260429 | [FIXED] | 4条bug已修复（SX参数颠倒、backOffsetY、LR镜像、PiP scale） |
| dual-cam-photo-black-20260427 | [FIXED] | 拍照全黑修复（commit 2ee9bfc） |

## 受影响文件

| 文件路径 | 改动 |
|---|---|
| `my-app/ios/LocalPods/DualCamera/DualCameraView.m` | 视频合成逻辑（4条bug已在此文件修复） |

## 修复步骤

### 必须执行的操作

**步骤 1：安装 DualCamera Pod**
```bash
cd /Users/zhengxi/vibecoding/camera2/my-app/ios
pod install
```

验证：
```bash
ls Pods/ | grep -i dual
# 应输出：DualCamera

grep "DualCamera" Podfile.lock
# 应输出包含 DualCamera 的行
```

**步骤 2：Xcode 重新编译**
1. 打开 `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcworkspace`
2. **⌘⇧K** — Clean Build Folder
3. **⌘B** — Build，确保无红色编译错误
4. **⌘R** — Run to device

**步骤 3：验证日志**
在 Xcode Debug Area Console 中搜索 `DualCamera`，应看到：
```
[DualCamera] Session config complete — backMovieOutput=OK frontMovieOutput=OK
[DualCamera] startRecording — backMovieOutput=OK frontMovieOutput=OK
[DualCamera] Compositing — frontSize=?KB backSize=?KB frontNaturalSize=? backNaturalSize=?
```

**步骤 4：测试三种布局**
- LR（左/右）：录制后保存，确认左右都有画面
- SX（上/下）：录制后保存，确认上下都有画面
- PiP（画中画）：录制后保存，确认小窗有前置画面

## 预期结果
安装 Pod + 重新编译后，以下 4 条 bug 应全部消失：
1. ✅ SX 布局：前置不在底部遮盖后置
2. ✅ SX 布局：无多余间隙
3. ✅ LR 布局：前置画面左右正确（镜像）
4. ✅ PiP 布局：小窗前置无严重变形

## 验证命令
```bash
# 验证 Pod 安装
ls /Users/zhengxi/vibecoding/camera2/my-app/ios/Pods/ | grep DualCamera

# 验证编译（模拟器）
cd /Users/zhengxi/vibecoding/camera2/my-app/ios
xcodebuild -workspace myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -20
```
