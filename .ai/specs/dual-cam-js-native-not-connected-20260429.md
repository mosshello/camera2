# DualCamera JS-Native 连接问题诊断

## 基本信息
- **spec_id**: dual-cam-js-native-not-connected-20260429
- **日期**: 2026-04-29
- **状态**: [OPEN — 诊断中]

## 问题描述
- 症状：Xcode 控制台没有 `[DualCamera]` 日志
- 原生代码已编译链接（app 二进制包含 `DualCameraModule`、`DualCameraView` 等符号）
- 但模块的 `+load`/`init`/`startSession` 都没有打印日志
- ExpoCamera 的模块日志正常出现，说明 React Native bridge 正常工作
- 相机录制出现超时（转圈）

## 根因分析

### 阶段 1：已排除的问题
1. ✅ Pod 未安装 — 已排除（Pod 已安装，Headers symlinks 存在）
2. ✅ 编译失败 — 已排除（app 二进制包含所有 DualCamera 符号）
3. ✅ Main Thread Checker — 已修复（`self.bounds` 在后台线程访问）
4. ✅ Metro 连接失败 — 已启用 `DEBUG_EMBED_BUNDLE=1`

### 阶段 2：当前诊断
原生模块的 `+load` 和 `init` 方法没有被调用。原因可能是：

**假设 1：React Native 没有扫描到 DualCamera 模块**
- `RCT_EXPORT_MODULE()` 宏应该自动注册
- 但可能因为 Expo autolinking 的配置问题

**假设 2：JS 层的 CameraPermissionModule 返回 null**
- `App.js` 第 75 行：`if (!CameraPermissionModule)`
- 如果 `CameraPermissionModule` 为 null，`cameraStatus` 被设为 `'unavailable'`
- 导致相机预览不渲染（fallback view）
- `DualCameraView` 从未被实例化 → `commonInit` 不执行

**假设 3：权限状态问题**
- `cameraStatus` 可能是 `'denied'` 或 `'unavailable'`
- 这会导致 UI 显示"无法使用相机"而不是相机预览

## 已添加的诊断日志
在以下位置添加了 `NSLog(@" [DualCamera] ...")`：

| 文件 | 方法 | 目的 |
|---|---|---|
| DualCameraModule.m | `+load` | 确认模块被加载 |
| DualCameraModule.m | `-init` | 确认模块初始化 |
| DualCameraEventEmitter.m | `-init` | 确认事件发射器初始化 |
| DualCameraView.m | `commonInit` | 确认视图初始化 |
| DualCameraView.m | `dc_startSession` | 确认 JS 调用到达 |
| DualCameraView.m | `internalStartSession` | 确认会话启动 |
| DualCameraSessionManager.m | `registerView` | 确认视图注册 |
| DualCameraSessionManager.m | `startSession` | 确认会话管理器调用 |

## 待验证的假设
- [ ] 如果 `[DualCamera] DualCameraModule +load called` 不出现 → RN 没有扫描到模块
- [ ] 如果 `[DualCamera] DualCameraModule init called` 不出现 → 模块加载了但未初始化
- [ ] 如果 `[DualCamera] DualCameraView commonInit called` 不出现 → JS 没有渲染 DualCameraView
- [ ] 如果 `[DualCamera] SessionManager registerView called` 不出现 → JS 没有创建 DualCameraView

## 修复步骤

### 步骤 1：重新编译（用户执行）
```bash
cd /Users/zhengxi/vibecoding/camera2/my-app/ios
pod install
```
然后在 Xcode 中 ⌘⇧K → ⌘B → ⌘R

### 步骤 2：观察日志顺序
在 Xcode Console 中搜索 `DualCamera`，应该看到：
```
[DualCamera] DualCameraModule +load called
[DualCamera] DualCameraModule init called
[DualCamera] DualCameraEventEmitter init called
[DualCamera] DualCameraView commonInit called
[DualCamera] SessionManager registerView called
[DualCamera] SessionManager startSession called
[DualCamera] dc_startSession called
[DualCamera] internalStartSession called
```

### 步骤 3：根据日志诊断
如果哪一步缺失，对应的问题：
- 缺失 `+load`/`init` → RN bridge 没有注册模块
- 缺失 `commonInit` → JS 没有渲染 `<NativeDualCameraView>`
- 缺失 `registerView` → DualCameraView init 成功但没有注册
