# 双摄 WYSIWYG 拍照诊断日志方案（2026-04-30）

## 问题描述

用户报告双摄模式下拍照只保存后置摄像头的内容，前置画面丢失。

---

## 诊断策略

由于代码逻辑看起来正确，需要通过日志定位问题所在。

### 诊断点 1：captureOutput:didOutputSampleBuffer: 数据路由

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**添加日志**:
```objc
// Debug: log which output received the frame
BOOL isFrontOutput = (output == self.frontVideoDataOutput);
BOOL isBackOutput = (output == self.backVideoDataOutput);
NSLog(@"[DualCamera] captureOutput: output=%p isFront=%d isBack=%d frontVDO=%p backVDO=%p frameSize=%@",
      (void *)output, isFrontOutput, isBackOutput,
      (void *)self.frontVideoDataOutput, (void *)self.backVideoDataOutput,
      NSStringFromCGSize(ciImage.extent.size));
```

**预期结果**: 控制台应同时出现 `isFront=1` 和 `isBack=1` 的日志，表示两个 VideoDataOutput 都收到了数据。

### 诊断点 2：internalTakePhoto 帧状态

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**添加日志**:
```objc
NSLog(@"[DualCamera] internalTakePhoto WYSIWYG — frontFrame=%@ backFrame=%@ layout=%@",
      frontFrame ? @"OK" : @"NIL",
      backFrame ? @"OK" : @"NIL",
      self.currentLayout);
```

**预期结果**: `frontFrame=OK backFrame=OK` 两个都应该是OK。

### 诊断点 3：frontVideoDataOutput 连接状态

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`

**添加日志**:
```objc
NSLog(@"[DualCamera] frontVideoDataOutput connected to frontVideoPort");
```

---

## 验证步骤

1. 在真机上运行应用
2. 切换到双摄模式（左右/上下/画中画）
3. 打开 Xcode 控制台
4. 观察以下日志序列：
   - `[DualCamera] frontVideoDataOutput connected to frontVideoPort` - 前置连接成功
   - `[DualCamera] backVideoDataOutput connected to backVideoPort` - 后置连接成功
   - `[DualCamera] captureOutput: ... isFront=1 ...` - 前置数据流
   - `[DualCamera] captureOutput: ... isBack=1 ...` - 后置数据流
   - `[DualCamera] internalTakePhoto WYSIWYG — frontFrame=OK backFrame=OK` - 拍照成功

5. 如果 `isFront=1` 和 `isBack=1` 都出现但结果仍不正确，问题可能在 `compositeLRFront:back:` 等合成方法中。

---

## 修改文件清单

| 文件路径 | 修改类型 |
|----------|----------|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 添加诊断日志 |
| `my-app/ios/LocalPods/DualCamera/DualCameraView.m` | 同步日志 |

---

## 状态

**状态**: [OPEN] - 待真机测试验证
