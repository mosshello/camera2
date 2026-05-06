# 拍照逻辑一次性修复方案

## 问题概述

| 问题 | 描述 | 影响 |
|------|------|------|
| **单摄拍照失败** | 前置/后置单独拍照时，画面一直加载，没有文件生成 | 用户无法使用单摄模式拍照 |
| **双摄只保存前置** | 上下/左右/画中画双摄模式只保存前置摄像头画面 | 双摄功能形同虚设 |

---

## 根因分析

### 问题 1：单摄拍照失败

**Bug 位置**: `DualCameraView.m` 第 1663-1680 行

```objc
// AVCapturePhotoCaptureDelegate callback
- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
  if (error) {
    [self emitError:error.localizedDescription];
    return;
  }
  NSData *data = [photo fileDataRepresentation];
  if (!data) {
    [self emitError:@"Failed to get photo data"];
    return;
  }
  // ... 实际保存逻辑 ...
  return;  // ❌ 注释说 "Only single-cam photo output comes through here"
}
```

**根因**: 单摄模式走的是 `capturePhotoWithSettings:delegate:` 路径，但 delegate 回调 `didFinishProcessingPhoto:error:` 方法体中**只有错误处理，没有任何保存逻辑**。所有保存代码被注释/删除了。

---

### 问题 2：双摄只保存前置

**Bug 位置 1**: `DualCameraView.m` 第 1553-1558 行

```objc
- (AVCapturePhotoOutput *)photoOutputForCurrentLayout {
  if (self.usingMultiCam) {
    return [self primaryCameraPosition] == AVCaptureDevicePositionFront ? self.frontPhotoOutput : self.backPhotoOutput;
  }
  return self.singlePhotoOutput;
}
```

**Bug 位置 2**: `DualCameraView.m` 第 1308-1337 行

```objc
if (self.usingMultiCam && [self isDualLayout:self.currentLayout]) {
  // WYSIWYG path: 获取最新帧
  CIImage *frontFrame;
  CIImage *backFrame;
  @synchronized(self) {
    frontFrame = self.latestFrontFrame;  // ✅ 有值
    backFrame = self.latestBackFrame;    // ❌ 永远是 nil
  }
  // ...
  if (!frontFrame || !backFrame) {
    // 当 backFrame 是 nil 时，错误分支提前返回
    [self emitError:@"Camera not ready, please try again"];
    return;
  }
}
```

**根因**: 多摄模式下，`AVCaptureVideoDataOutput` 只为**前置摄像头**创建（第 473-487 行），后置摄像头没有 VideoDataOutput（第 489-501 行只初始化了变量，但**没有添加到 session**）。因此 `latestBackFrame` 永远是 nil。

当 `latestBackFrame` 是 nil 时，`!frontFrame || !backFrame` 条件成立，触发 "Camera not ready" 错误提前返回。

**用户观察到的"只保存前置"**: 因为后置摄像头没有初始化 VideoDataOutput，前置的 `latestFrontFrame` 有值，所以：
- 前置拍照成功（单摄路径）
- 双摄时 `frontFrame` 有值但 `backFrame` 是 nil → 报错提前返回
- 但如果用户没有看到错误提示，可能是因为某种原因前置画面被当作结果保存了

---

## 修复方案（一次性）

### 修复 1：恢复单摄拍照保存逻辑

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
**位置**: 第 1663-1680 行

将 delegate 回调中的保存逻辑补全：

```objc
- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
  if (error) {
    [self emitError:error.localizedDescription];
    return;
  }

  NSData *data = [photo fileDataRepresentation];
  if (!data) {
    [self emitError:@"Failed to get photo data"];
    return;
  }

  // Single-cam: save directly from photo data
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *filename = [NSString stringWithFormat:@"photo_%@.jpg", @((NSInteger)[[NSDate date] timeIntervalSince1970])];
    NSString *path = [documentsPath stringByAppendingPathComponent:filename];
    NSError *writeError = nil;
    [data writeToFile:path options:NSDataWritingAtomic error:&writeError];

    dispatch_async(dispatch_get_main_queue(), ^{
      if (writeError) {
        [self emitError:writeError.localizedDescription];
      } else {
        [self emitPhotoSaved:[NSString stringWithFormat:@"file://%@", path]];
      }
    });
  });
}
```

---

### 修复 2：为后置摄像头创建 VideoDataOutput

**文件**: `my-app/native/LocalPods/DualCamera/DualCameraView.m`
**位置**: 第 489-501 行

当前代码：
```objc
// VideoDataOutput for WYSIWYG photo capture (back camera)
if (ok) {
  self.backVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
  self.backVideoDataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
  [self.backVideoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
  if ([self.multiCamSession canAddOutput:self.backVideoDataOutput]) {
    [self.multiCamSession addOutput:self.backVideoDataOutput];  // ❌ 只添加到变量，没有添加到 session
    AVCaptureConnection *conn = [self.backVideoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    if (conn.isVideoOrientationSupported) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
  } else {
    NSLog(@"[DualCamera] Cannot add backVideoDataOutput to session");
  }
}
```

**修复后**：
```objc
// VideoDataOutput for WYSIWYG photo capture (back camera)
if (ok) {
  self.backVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
  self.backVideoDataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
  [self.backVideoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
  if ([self.multiCamSession canAddOutput:self.backVideoDataOutput]) {
    [self.multiCamSession addOutput:self.backVideoDataOutput];
    AVCaptureConnection *conn = [self.backVideoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    if (conn.isVideoOrientationSupported) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
    // ✅ 连接后置摄像头到 VideoDataOutput（与 frontVideoPort 对应）
    if (self.backDeviceInput && conn.inputPorts.count == 0) {
      // 需要为 back input 添加 connection
      AVCaptureConnection *backConn = [[AVCaptureConnection alloc] initWithInputPorts:@[] output:self.backVideoDataOutput];
      // 查找 back camera 的 port
      for (AVCaptureInputPort *port in self.backDeviceInput.ports) {
        if (port.mediaType == AVMediaTypeVideo) {
          backConn = [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:self.backVideoDataOutput];
          break;
        }
      }
      if ([self.multiCamSession canAddConnection:backConn]) {
        [self.multiCamSession addConnection:backConn];
      }
    }
  } else {
    NSLog(@"[DualCamera] Cannot add backVideoDataOutput to session");
  }
}
```

**简化方案**：使用 `AVCaptureVideoDataOutput` 的无端口连接方式：

```objc
// VideoDataOutput for WYSIWYG photo capture (back camera)
if (ok) {
  self.backVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
  self.backVideoDataOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
  [self.backVideoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
  if ([self.multiCamSession canAddOutput:self.backVideoDataOutput]) {
    [self.multiCamSession addOutputWithNoConnections:self.backVideoDataOutput];
    
    // 创建连接到 back camera 的 connection
    AVCaptureInputPort *backVideoPort = nil;
    for (AVCaptureInputPort *port in self.backDeviceInput.ports) {
      if (port.mediaType == AVMediaTypeVideo) {
        backVideoPort = port;
        break;
      }
    }
    
    if (backVideoPort) {
      AVCaptureConnection *conn = [[AVCaptureConnection alloc] initWithInputPorts:@[backVideoPort] output:self.backVideoDataOutput];
      if ([self.multiCamSession canAddConnection:conn]) {
        [self.multiCamSession addConnection:conn];
        if (conn.isVideoOrientationSupported) conn.videoOrientation = AVCaptureVideoOrientationPortrait;
      }
    }
  } else {
    NSLog(@"[DualCamera] Cannot add backVideoDataOutput to session");
  }
}
```

---

## 修改文件清单

| 文件路径 | 修改类型 |
|----------|----------|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 修复 Bug 1：补全单摄拍照保存逻辑 |
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 修复 Bug 2：为后置摄像头创建 VideoDataOutput |

**注意**: `ios/LocalPods/DualCamera/DualCameraView.m` 是通过插件同步的，修复 `native/` 目录后执行 `pod install` 会自动同步。

---

## 验证步骤

1. **单摄拍照测试**：
   - 切换到"后置"模式，点击拍照 → 应显示"已保存"提示
   - 切换到"前置"模式，点击拍照 → 应显示"已保存"提示

2. **双摄拍照测试**：
   - 切换到"左右双摄"模式，点击拍照 → 应合成前后画面并保存
   - 切换到"上下双摄"模式，点击拍照 → 应合成前后画面并保存
   - 切换到"画中画"模式，点击拍照 → 应合成前后画面并保存
