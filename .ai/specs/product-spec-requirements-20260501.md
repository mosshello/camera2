# 产品需求说明书 & 技术方案（终版 v2.0）
# 基于原型图 v1.0 + 用户确认 v2.0
# spec_id: camera2-product-spec-20260501
# 日期: 2026-05-01

---

## 一、产品原型图分析摘要
有整体画面比例调整，左上角默认9:16，单击可以选择3:4，1:1的比例
### 截图 1：LR（左右双摄）
- 默认9:16布局，点击左上角的9:16可以选择3:4的比例和1:1的比例，两个摄像头左右并排，默认各自占画面的50%，左侧画面中有向左的箭头，后侧画面中有向右的箭头，拖动可以放大或者缩小各自区域的占比
- 左侧默认"后置"，右侧默认"前置"（单击翻转按钮，左侧默认前置，右侧默认后置）
- **分割线可拖动**调节左右比例
- 后置区放档位栏：`0.5x | 1.0x | 2.0x | 5.0x`（当前选中 1.0x）
- 右侧垂直按钮：`方` `圆` `左` `上` （当前选中"左"）
- 底部1：拍照/视频 +镜头翻转（参考苹果原来的设计）
- 底部2:拍摄按钮（参考苹果原来的设计）

### 截图 2：SX（上下双摄）
- - 默认9:16布局，点击左上角的9:16可以选择3:4的比例和1:1的比例，纵向布局，上下排列，默认各自占画面的50%，上面画面中有向上的箭头，下面画面中有向下的箭头，拖动可以放大或者缩小各自区域的占比
- 上方默认"后置"，下方默认"前置"
- **分割线可拖动**调节上下比例
- 无缩放栏（原型图中未显示，但用户确认需要有缩放功能）
- 翻转按钮在右下角

### 截图 3：PiP（画中画）
- - 默认9:16布局，点击左上角的9:16可以选择3:4的比例和1:1的比例，
- 大画面：后置摄像头（背景）
- 右下角小窗口：前置摄像头（圆角）焦距变化`0.5x | 1.0x | 2.0x | 5.0x`
- 右下角缩放档位栏：`0.5x | 1.0x | 2.0x | 5.0x`
- 翻转按钮：切换主画面与小窗口的角色

### 截图 4：单摄（后置）
- 全屏后置摄像头
- 顶部缩放档位：`0.5x | 1.0x | 2.0x | 5.0x`
- 当前选中 1.0x
- 右下角翻转按钮，变化为前置

---

## 二、产品功能需求（终版 v2.0）

### 2.1 布局模式（6种）

| 模式 | 标识 | 描述 | 默认摄像头分配 |
|---|---|---|---|
| 单摄-后 | `BACK` | 全屏后置摄像头 | 后置 |
| 单摄-前 | `FRONT` | 全屏前置摄像头 | 前置 |
| 画中画-方 | `PIP_SQUARE` | 主画面 + 右下角方形小窗 | 大窗=后置，小窗=前置 |
| 画中画-圆 | `PIP_CIRCLE` | 主画面 + 右下角圆形小窗 | 大窗=后置，小窗=前置 |
| 左右双摄 | `LR` | 左右并排 | 左=后置，右=前置 |
| 上下双摄 | `SX` | 上下排列 | 上=后置，下=前置 |

**右侧按钮（5个）**：`方` `圆` `左` `上` `⟳`
- `方`：切换到 PIP_SQUARE
- `圆`：切换到 PIP_CIRCLE
- `左`：切换到 LR
- `上`：切换到 SX
- `⟳`：翻转按钮（切换摄像头角色）
- **移除**：`后` `前` 按钮（flip 按钮已覆盖此功能）

### 2.2 缩放控制（终版 v2.0）

| 场景 | 可用档位 | 展示位置 | 控制对象 |
|---|---|---|---|
| 单摄-后 | 0.5 / 1.0 / 2.0 / 3.0 / 5.0 | 顶部栏 | 后置摄像头 |
| 单摄-前 | 0.5 / 1.0 / 2.0 | 顶部栏 | 前置摄像头 |
| LR 双摄 | 0.5 / 1.0 / 2.0 / 3.0 / 5.0 | 顶部栏 | **主区域摄像头**（左=后置） |
| SX 双摄 | 0.5 / 1.0 / 2.0 / 3.0 / 5.0 | 顶部栏 | **主区域摄像头**（上=后置） |
| PiP（方/圆）| 0.5 / 1.0 / 2.0 / 3.0 / 5.0 | 右下角小窗区域 | **小窗摄像头**（前置） |

**技术说明**：
- 缩放控制**每个摄像头独立控制**（后置用 `backZoom`，前置用 `frontZoom`）
- **0.5x 是超广角**，仅 `AVCaptureDeviceTypeBuiltInWideAngleCamera` 支持；若设备不支持，`minAvailableVideoZoomFactor > 1.0`，则不显示 0.5x 档位
- **3.0x 是长焦镜头**，仅部分设备支持；若不支持，同上逻辑
- 缩放栏**按需显示**：只展示该摄像头**实际支持**的档位，不显示不支持的档位
- LR/SX 模式的缩放**只影响主区域摄像头**（大面积的那个），小区域不受缩放影响
- PiP 模式的缩放**只影响小窗口摄像头**，大窗不受缩放影响

### 2.3 翻转镜头按钮

| 当前模式 | 点击翻转后的效果 |
|---|---|
| 单摄-后/前 | 切换前后摄像头（单摄模式切换） |
| LR | 交换左右摄像头位置（左变右，右变左） |
| SX | 交换上下摄像头位置（上变下，下变上） |
| PiP（方/圆） | 大画面和小窗口**互换角色**（后置↔前置） |

**关键 UX 要求**：翻转后，**预览画面**和**保存的图片/视频**必须完全一致（WYSIWYG）。

### 2.4 分割线拖动

| 模式 | 拖动方向 | 说明 |
|---|---|---|
| LR（左右） | 左右拖动 | 调节左右区域比例 |
| SX（上下） | 上下拖动 | 调节上下区域比例 |

- 比例范围限制：`[10%, 90%]`
- 拖动时实时预览更新（`dualLayoutRatio` → native → `updateLayout`）
- PiP **不支持分割线拖动**（通过 +/- 按钮调节大小）

### 2.5 PiP 小窗口控制（终版 v2.0）

- **大小调节**：通过 +/- 按钮（步长 5%），范围 `[5%, 50%]`
- **位置调节**：**支持拖动** — 用户可以拖动小窗口到任意位置
- **圆形 PiP**：应用 `cornerRadius = size/2` 圆角裁剪
- **位置约束**：拖动后 clamp 到画布范围内（不能拖出屏幕）
- 缩放控制（小窗档位）：同 2.2 节，PiP 模式下缩放控制小窗摄像头

### 2.6 拍照功能

- **单摄模式**：直接调用 `AVCapturePhotoOutput` 全分辨率拍摄
- **双摄模式（LR/SX/PiP）**：
  - WYSIWYG：同时从 `VideoDataOutput` 获取前后摄像头最新帧
  - CIImage 合成：按当前布局将两帧合并
  - 输出分辨率：`width × 3`（约 1080-1440px 宽）
- **保存比例**：`9:16`、`3:4`、`1:1` 三档可选（仅影响输出画布比例，不影响摄像头分割比例）
- **无镜像处理**：所有保存内容与预览完全一致

### 2.7 视频录制功能（终版 v2.0）

| 参数 | 值 |
|---|---|
| 最大时长 | 30 分钟 |
| 帧率 | 30 fps |
| 分辨率 | 1080p（1920×1080） |
| 视频编码 | H.264 |
| 码率 | 8–12 Mbps（目标 10 Mbps） |
| 音频编码 | AAC |

**时长限制实现**：
- 录制时长由用户自由选择（无强制限制）
- 到达 30 分钟时，**自动调用 stopRecording** 停止录制
- 可通过 NSTimer 在 30 分钟时强制停止

**双摄录制**：
- 同时从两个摄像头录制（`DualCameraSession` 双流）
- 录制结束后合成：`AVMutableVideoComposition` 按布局合成为单一视频
- 音频：默认使用后置摄像头的麦克风

**单摄录制**：
- 直接从 `AVCaptureMovieFileOutput` 录制

---

## 三、技术规格（终版 v2.0）

### 3.1 视频录制配置

```objc
// AVCaptureMovieFileOutput 配置（当前代码已有，需确认/增强）
AVCaptureMovieFileOutput *movieOutput;

// 1. 分辨率：AVCaptureSessionPreset1920x1080
//    当前代码: session.sessionPreset = AVCaptureSessionPresetHigh;
//    需改为: session.sessionPreset = AVCaptureSessionPreset1920x1080;

// 2. 帧率：30fps
//    当前代码: device.activeVideoMinFrameDuration = CMTimeMake(1, 30); ✅

// 3. H.264 编码 + 码率控制（AVCaptureMovieFileOutput 不直接支持，需通过 AVAssetWriter）
//    对于 DualCamSession 的双摄录制，当前使用 AVCaptureMovieFileOutput（直接写入 .mov）
//    → H.264/码率控制需要用 AVCaptureVideoDataOutput + AVAssetWriter 替代
//    或：在 AVCaptureMovieFileOutput 后通过 AVAssetExportSession 重新编码

// 4. 30 分钟自动停止
NSTimer *recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1800
  target:self selector:@selector(autoStopRecording) ...];
```

### 3.2 缩放档位计算

```objc
// 获取设备支持的缩放档位（动态）
- (NSArray<NSNumber *> *)availableZoomLevelsForDevice:(AVCaptureDevice *)device {
    CGFloat minZoom = device.minAvailableVideoZoomFactor;
    CGFloat maxZoom = device.maxAvailableVideoZoomFactor;
    NSMutableArray *levels = [NSMutableArray array];
    
    // 前置固定档位: 0.5, 1.0, 2.0
    // 后置固定档位: 0.5, 1.0, 2.0, 3.0, 5.0
    // 但只添加设备支持的档位（介于 minZoom 和 maxZoom 之间）
    NSArray *candidateLevels = (isBack) 
        ? @[@0.5, @1.0, @2.0, @3.0, @5.0]
        : @[@0.5, @1.0, @2.0];
    
    for (NSNumber *level in candidateLevels) {
        CGFloat v = level.doubleValue;
        if (v >= minZoom && v <= maxZoom) {
            [levels addObject:level];
        }
    }
    return levels;
}
```

### 3.3 PiP 拖动实现

```objc
// Native: DualCameraView.m 中添加 UIPanGestureRecognizer
UIPanGestureRecognizer *pipPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePipPan:)];
[_frontPreviewView addGestureRecognizer:pipPan]; // 小窗视图可拖动
_frontPreviewView.userInteractionEnabled = YES;

- (void)handlePipPan:(UIPanGestureRecognizer *)pan {
  CGPoint translation = [pan translationInView:self];
  CGPoint center = _frontPreviewView.center;
  center.x += translation.x;
  center.y += translation.y;
  
  // Clamp to canvas bounds (小窗不能拖出画布)
  CGFloat halfW = _frontPreviewView.bounds.size.width / 2;
  CGFloat halfH = _frontPreviewView.bounds.size.height / 2;
  center.x = MAX(halfW, MIN(self.bounds.size.width - halfW, center.x));
  center.y = MAX(halfH, MIN(self.bounds.size.height - halfH, center.y));
  
  _frontPreviewView.center = center;
  [pan setTranslation:CGPointZero inView:self];
  
  // Update normalized position for save
  _pipPositionX = center.x / self.bounds.size.width;
  _pipPositionY = center.y / self.bounds.size.height;
  
  if (pan.state == UIGestureRecognizerStateEnded) {
    // Notify JS of new position
    [[DualCameraEventEmitter shared] sendPipPositionChanged:_pipPositionX y:_pipPositionY];
  }
}
```

### 3.4 摄像头分配逻辑（对称性保证）

```
┌────────────────────────────────────────────────────────┐
│ Preview Layer (Native: updateLayout)                  │
│                                                        │
│ LR:  sxBackOnTop=YES → back.left + front.right       │
│      sxBackOnTop=NO  → front.left + back.right        │
│                                                        │
│ SX:  sxBackOnTop=YES → back.top + front.bottom        │
│      sxBackOnTop=NO  → front.top + back.bottom        │
│                                                        │
│ PiP: pipMainIsBack → back=bg + front=PiP(小窗)       │
│      !pipMainIsBack → front=bg + back=PiP(小窗)      │
│      小窗可拖动，pipPositionX/Y 实时更新               │
└────────────────────────────────────────────────────────┘
                         ↕ 完全对称
┌────────────────────────────────────────────────────────┐
│ Save/Record (Native: compositeFront:back:)             │
│                                                        │
│ LR:  sxBackOnTop=YES → back.left + front.right       │
│      sxBackOnTop=NO  → front.left + back.right        │
│                                                        │
│ SX:  sxBackOnTop=YES → back.top + front.bottom       │
│      sxBackOnTop=NO  → front.top + back.bottom        │
│                                                        │
│ PiP: pipMainIsBack → back=bg + front=PiP位置(用最新pipPosition) │
│      !pipMainIsBack → front=bg + back=PiP位置         │
└────────────────────────────────────────────────────────┘
```

### 3.5 视频合成规格

```
双摄视频录制流程：
1. startRecording → backMovieOutput + frontMovieOutput 同时开始
                   → 启动 30 分钟 timer 备用
2. stopRecording  → 两个 output 均停止
3. 等待两个文件写入完成（AVCaptureFileOutputRecordingDelegate）
4. compositeDualVideosForCurrentLayout：
   - AVMutableComposition（双视频轨道 + 后置音频轨道）
   - AVMutableVideoComposition（renderSize = 1920×1080）
   - CGAffineTransform 布局（同 save 的 composite 逻辑）
   - AVAssetExportSession（H.264，目标码率 10Mbps）
5. 删除原始临时文件
6. 发送 onRecordingFinished
```

### 3.6 分割线拖动（JS + Native）

```javascript
// JS: PanGesture 处理分割线
const panGesture = Gesture.Pan()
  .onStart(() => { setShowAdjustment(true); }) // 开始拖动时显示调整面板
  .onUpdate(e => {
    if (cameraMode === 'LR') {
      const newRatio = Math.max(0.1, Math.min(0.9, e.absoluteX / screenWidth));
      setDualLayoutRatio(newRatio);
    } else if (cameraMode === 'SX') {
      // Y越大 → ratio越小（back在下方的区域越小）
      const newRatio = Math.max(0.1, Math.min(0.9, 1 - (e.absoluteY / screenHeight)));
      setDualLayoutRatio(newRatio);
    }
  })
  .onEnd(() => { setShowAdjustment(false); });

// Native: setDualLayoutRatio: → updateLayout → 重绘预览
```

---

## 四、修改文件清单

| 文件 | 改动 | 说明 |
|---|---|---|
| `DualCameraView.m` | 核心 | PiP 拖动手势、30分钟录制timer、1080p/H.264/10Mbps配置、缩放档位动态计算 |
| `DualCameraView.h` | 新增方法 | `-availableZoomLevelsForDevice:` |
| `DualCameraEventEmitter.m` | 新增事件 | `sendPipPositionChanged:` |
| `App.js` | UI 调整 | 按钮精简(5个)、PiP拖动、缩放栏按布局显示 |

---

## 五、交互流程图

```
用户启动 App
    ↓
权限检测 → 未授权 → 授权页 → 授权后
    ↓
后置单摄模式（默认）
    ↓
右侧按钮点击:
  方/圆 → PiP模式（后置大窗+前置小窗）
  左   → LR模式（左后右前）
  上   → SX模式（上后下前）
    ↓
顶部/右下缩放栏:
  点击档位 → setZoom(camera, factor) → AVCaptureDevice.videoZoomFactor
    ↓
⟳ 翻转按钮:
  单摄 → 切换前后
  LR   → 交换左右（sxBackOnTop toggled）
  SX   → 交换上下（sxBackOnTop toggled）
  PiP  → 互换大窗小窗（pipMainIsBack toggled）
    ↓
拍摄（快门按钮）:
  单摄 → AVCapturePhotoOutput（全分辨率）
  双摄 → VideoDataOutput帧 → CIImage合成 → JPEG
    ↓
保存到相册 + 提示
```

---

## 六、需再次确认的问题

> 以下问题已在上轮明确，此处作为最终确认：

| # | 问题 | 确认结果 |
|---|---|---|
| 1 | SX 需要缩放功能 | ✅ 是 |
| 2 | 前置0.5/1.0/2.0，后置0.5/1.0/2.0/3.0/5.0 | ✅ 是，不支持的不显示 |
| 3 | 视频30分钟上限 | ✅ 是 |
| 4 | PiP 支持拖动+修改占比 | ✅ 是 |
| 5 | saveAspectRatio(9:16/3:4/1:1)与dualLayoutRatio的关系 | 两者独立：dualLayoutRatio控制摄像头分割比例，saveAspectRatio控制输出画布比例 |
| 6 | 所有缩放独立控制每个摄像头 | ✅ 是（backZoom/frontZoom 分离） |
| 7 | 移除前/后按钮 | ✅ 是（5按钮） |
