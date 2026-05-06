# 技术契约与架构设计书 — 全局画幅控制 + 可拖动画中画 + 独立变焦
# spec_id: camera2-aspect-ratio-pip-drag-zoom-20260501
# 日期: 2026-05-01
# 基于: product-spec-requirements-20260501.md + 用户 v3.0 需求补充

---

## 一、需求摘要（v3.0 增量）

用户已确认**产品原型图 v1.0 + v2.0**（见 `product-spec-requirements-20260501.md`），并补充以下 v3.0 增量：

### 1.1 全局画幅控制（左上角）
- **位置**：屏幕左上角（注意：现有 spec 描述为"左下角"，需更正为左上角）
- **默认**：`9:16`（1080×1920px）
- **可选项**：`3:4`、`1:1`
- **行为**：单击切换，当前选中项高亮
- **影响范围**：**所有摄像头画面随之等比例变化**
  - LR 布局：左右分屏宽度按新画幅重新计算，但 dualLayoutRatio 保持不变
  - SX 布局：上下分屏高度按新画幅重新计算，但 dualLayoutRatio 保持不变
  - PiP 布局：小窗 absolute size 按新画幅重新计算，pipSize 比例不变
  - 单摄布局：画面整体按新比例裁切

### 1.2 摄像头独立变焦
- **每个摄像头各自独立控制**（非同步）
- 现有实现：`frontZoomFactor` / `backZoomFactor` 已存在（DualCameraView.h），但 JS 层 zoom bar 只控制"主区域"摄像头
- **需求**：PiP 模式下，小窗摄像头也应有独立缩放控制（目前 zoom bar 控制主画面）
- **设计决策**：PiP 模式下，zoom bar 始终显示在**小窗附近**（现有实现显示在底部中央）

### 1.3 画中画区域可拖动
- **当前实现**：PiP 小窗已支持拖动（`UIPanGestureRecognizer` 未添加，但 `pipPositionX/Y` 由 JS 控制）
- **缺失**：Native 层未添加 `UIPanGestureRecognizer`，JS 层通过"调整面板"手动设置位置
- **需求**：用户可以直接用手指拖动小窗，**拖动时实时更新预览**
- **保存**：拖动结束后，拍照/录制使用**最新的 pipPositionX/Y**，确保所见即所得

### 1.4 画中画区域大小可调节
- **当前实现**：`pipSize`（0.05~0.5）存在，JS 层"调整面板"有 +/- 按钮
- **需求**：支持通过**手势（捏合缩放）**调节小窗大小
- **保存**：大小使用最新的 `pipSize`，确保所见即所得

---

## 二、现有实现审计

### 2.1 已实现功能

| 功能 | 状态 | 位置 |
|---|---|---|
| 6 种布局模式 | ✅ 已实现 | `layoutMode` prop |
| dualLayoutRatio 分割 | ✅ 已实现 | `setDualLayoutRatio:` |
| PiP size 调节 | ✅ 已实现 | `setPipSize:` |
| PiP position (JS 控制) | ✅ 已实现 | `setPipPositionX/Y:` |
| 独立 zoom factor | ✅ 已实现 | `dc_setFrontZoom:` / `dc_setBackZoom:` |
| saveAspectRatio | ✅ 已实现 | `internalTakePhoto` 合成 |
| SX/LR flip 机制 | ✅ 已实现 | `sxBackOnTop` / `pipMainIsBack` |
| 圆形 PiP 裁剪 | ✅ 已实现 | `compositePIPFront` CIBlendWithMask |
| 无镜像（WYSIWYG）| ✅ 已实现 | 预览无 mirror，保存无 transform |

### 2.2 缺失 / 需修复的功能

| # | 功能 | 缺失层 | 说明 |
|---|---|---|---|
| 1 | 左上角画幅选择器 UI | JS (App.js) | 当前在底部左下角，需移至左上角 |
| 2 | 画幅变化时预览同步更新 | Native (DualCameraView.m) | `updateLayout` 需响应画幅比例变化 |
| 3 | PiP 小窗 Native 拖动手势 | Native (DualCameraView.m) | 缺少 `UIPanGestureRecognizer` |
| 4 | PiP 小窗捏合缩放手势 | Native (DualCameraView.m) | 缺少 `UIPinchGestureRecognizer` |
| 5 | PiP 模式下 zoom bar 显示位置 | JS (App.js) | 应显示在小窗附近，而非底部中央 |
| 6 | PiP 模式下 zoom 控制主/小窗 | JS (App.js) | 当前 zoom bar 控制"主画面摄像头"，应改为控制"小窗摄像头" |

---

## 三、数据模型与契约

### 3.1 JS → Native Props（已声明，需确认 RCT_CUSTOM_VIEW_PROPERTY）

```objc
// DualCameraView.h
@property (nonatomic, assign) CGFloat dualLayoutRatio;   // ✅ 已有
@property (nonatomic, assign) CGFloat pipSize;            // ✅ 已有
@property (nonatomic, assign) CGFloat pipPositionX;      // ✅ 已有
@property (nonatomic, assign) CGFloat pipPositionY;      // ✅ 已有
@property (nonatomic, assign) CGFloat frontZoomFactor;   // ✅ 已有
@property (nonatomic, assign) CGFloat backZoomFactor;    // ✅ 已有
@property (nonatomic, copy)   NSString *saveAspectRatio;  // ✅ 已有
@property (nonatomic, assign) BOOL sxBackOnTop;           // ✅ 已有
@property (nonatomic, assign) BOOL pipMainIsBack;         // ✅ 已有
// ————————————————————————— 新增 ——————————————————————————————
@property (nonatomic, assign) CGFloat canvasAspectWidth;  // 画幅宽度比例（9/4/3）
@property (nonatomic, assign) CGFloat canvasAspectHeight; // 画幅高度比例（16/4/1）
```

### 3.2 Canvas Aspect Ratio Schema

```
saveAspectRatio      canvasAspectWidth   canvasAspectHeight
──────────────────────────────────────────────────────────
9:16                 9                   16
3:4                  3                   4
1:1                  1                   1
```

### 3.3 Native → JS 事件（已声明，需新增）

```objc
// DualCameraEventEmitter.m
// 新增事件：
- (void)sendPipPositionChanged:(CGFloat)x y:(CGFloat)y;
// 新增事件：
- (void)sendPipSizeChanged:(CGFloat)size;
```

---

## 四、技术规格

### 4.1 左上角画幅选择器 UI（App.js）

```
┌─────────────────────────────────────────────┐
│ [9:16] [3:4] [1:1]                         │  ← 左上角，绝对定位
│                                             │
│              相机画面                         │
│                                             │
└─────────────────────────────────────────────┘
```

**实现要点**：
- 位置：`position: absolute; left: 12; top: Platform.OS === 'ios' ? 60 : 44`
- 样式：`flexDirection: 'row'; gap: 6`
- 每个按钮：圆角胶囊形，padding `8px 12px`
- 选中态：`backgroundColor: 'rgba(77,166,255,0.8)'` + `borderColor: '#4da6ff'`
- 点击时：`setSaveAspectRatio(r)` → Native 自动响应（通过 prop change 触发 layout 更新）
- **全模式显示**：所有模式（单摄 + 双摄 + PiP）均显示画幅选择器

### 4.2 画幅变化时 Native 预览同步（DualCameraView.m）

**原理**：`updateLayout` 的 viewport 基于 `self.bounds`（屏幕实际像素），画幅变化**不改变 viewport**，只影响**内容裁切策略**。

但对于 WYSIWYG 拍照保存，`saveAspectRatio` 已在 `internalTakePhoto` 中使用，**预览无需修改**。

**真正需要处理的场景**：
- 若未来需要"预览画面等比例缩放以适应选定画幅"（即画面不变黑边），则需要：
  - Native 层根据 `canvasAspectWidth/Height` 计算 letterbox 区域（黑色边框）
  - 将 letterbox 区域叠加在预览层之上

**当前决策**：预览始终全屏显示（aspect ratio 由摄像头硬件决定），画幅选择**仅影响输出画布比例**，不影响预览。这与"所见即所得"原则一致（预览框就是最终输出框）。

### 4.3 PiP 拖动手势（Native 实现）

```objc
// DualCameraView.m — commonInit 或 createPlaceholderViews 中添加
UIPanGestureRecognizer *pipPan = [[UIPanGestureRecognizer alloc]
  initWithTarget:self action:@selector(handlePipPan:)];
pipPan.delegate = self;
[_frontPreviewView addGestureRecognizer:pipPan];
_frontPreviewView.userInteractionEnabled = YES;

// UIPinchGestureRecognizer — 小窗缩放
UIPinchGestureRecognizer *pipPinch = [[UIPinchGestureRecognizer alloc]
  initWithTarget:self action:@selector(handlePipPinch:)];
pipPinch.delegate = self;
[_frontPreviewView addGestureRecognizer:pipPinch];
```

```objc
// PiP 拖动处理
- (void)handlePipPan:(UIPanGestureRecognizer *)pan {
  CGPoint translation = [pan translationInView:self];
  CGPoint center = _frontPreviewView.center;
  center.x += translation.x;
  center.y += translation.y;

  // Clamp：小窗中心不能拖出画布边界
  CGFloat halfW = _frontPreviewView.bounds.size.width / 2;
  CGFloat halfH = _frontPreviewView.bounds.size.height / 2;
  center.x = MAX(halfW, MIN(self.bounds.size.width - halfW, center.x));
  center.y = MAX(halfH, MIN(self.bounds.size.height - halfH, center.y));

  _frontPreviewView.center = center;
  [pan setTranslation:CGPointZero inView:self];

  // 实时更新归一化坐标（用于保存）
  _pipPositionX = center.x / self.bounds.size.width;
  _pipPositionY = center.y / self.bounds.size.height;

  if (pan.state == UIGestureRecognizerStateEnded) {
    [[DualCameraEventEmitter shared] sendPipPositionChanged:_pipPositionX y:_pipPositionY];
  }
}
```

```objc
// PiP 捏合缩放处理
- (void)handlePipPinch:(UIPinchGestureRecognizer *)pinch {
  static CGFloat lastPipSize = 0;
  if (pinch.state == UIGestureGestureRecognizerBegan) {
    lastPipSize = _pipSize;
  }
  CGFloat newSize = lastPipSize * pinch.scale;
  _pipSize = MAX(0.05, MIN(0.5, newSize));

  // 更新视图 frame
  [self updateLayout];

  if (pinch.state == UIGestureRecognizerStateEnded) {
    [[DualCameraEventEmitter shared] sendPipSizeChanged:_pipSize];
  }
}
```

**注意事项**：
- `_frontPreviewView` 在 PiP 模式下是**小窗视图**（非主画面），拖动它不会与主画面手势冲突
- 需要 `UIGestureRecognizerDelegate` 防止与系统手势冲突

### 4.4 PiP 模式 Zoom Bar 跟随小窗（终版 v3.0）

**用户决策**：zoom bar 跟随 PiP 小窗动态移动，用户将小窗拖到任意位置时，zoom bar 自动跟随。

**算法**（见 §7.7 详细设计）：
- bar 放在小窗**左侧**，竖向排列（每行一个档位）
- `barLeft = 小窗中心X - 小窗宽度/2 - bar宽度 - 8`
- `barTop = 小窗中心Y - bar高度/2`
- clamp 防止超出屏幕边界
- `transition: left 0.1s ease-out, top 0.1s ease-out` 动画过渡

**竖向排列 vs 横排**：竖排（`flexDirection: 'column'`），每行一个档位，适合放在小窗左侧窄空间。

**Native → JS 同步**：`sendPipPositionChanged` 事件通知 JS 更新 `pipPosition` state → zoom bar 重新渲染。

**取消 +/- 按钮**：PiP 小窗大小完全通过**捏合手势**调节，移除 JS 调整面板的 `+`/`-` 按钮。

```
PiP 小窗在右下角时:
┌─────────────────────────────┐
│ [9:16]                     │ ← 左上角
│                             │
│       [相机画面]              │
│ [0.5x]                      │
│ [1.0x] [小窗 PiP]           │ ← zoom bar 在小窗左侧，竖排
│ [2.0x] [0.5x]              │ ← bar 跟随小窗移动
│          [3.0x]             │
│                             │
└─────────────────────────────┘

PiP 小窗在左上角时（跟随后）:
┌─────────────────────────────┐
│ [9:16] [0.5x]              │ ← 左上角
│        [1.0x]               │
│        [2.0x]               │ ← bar 在小窗左侧
│        [小窗 PiP]           │
│                             │
│       [相机画面]              │
│                             │
└─────────────────────────────┘
```

### 4.5 摄像头独立变焦（Native 实现确认）

现有 `dc_setFrontZoom:` 和 `dc_setBackZoom:` 方法已完整实现，JS 层通过 `DualCameraModule.setZoom(camera, factor)` 调用。

**PiP 模式变焦语义**：
- `setZoom('front', factor)` → 前置摄像头缩放（无论是否为小窗）
- `setZoom('back', factor)` → 后置摄像头缩放（无论是否为主画面）
- PiP flip 后：zoom bar 显示新小窗摄像头的档位，并控制该摄像头

### 4.6 WYSIWYG 保存时画幅处理

```objc
// DualCameraView.m — internalTakePhoto 中的 saveCanvas 计算
// 现有逻辑保持不变：
if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
  saveCanvas = CGSizeMake(refW, round(refW * 16.0 / 9.0));
} else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
  saveCanvas = CGSizeMake(refW, round(refW * 4.0 / 3.0));
} else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
  saveCanvas = CGSizeMake(refW, refW);
}
```

**关键**：`dualLayoutRatio` 在不同画幅下**保持不变**（即摄像头分割比例不变），但绝对像素值随画幅宽度等比变化。

---

## 五、全栈文件修改清单

### 5.1 DualCameraView.m（Native 核心）

| 改动 | 说明 |
|---|---|
| `commonInit` 中添加 `UIPanGestureRecognizer` + `UIPinchGestureRecognizer` 到 `_frontPreviewView` | PiP 拖动 + 捏合缩放 |
| 添加 `handlePipPan:` 方法 | 拖动处理，实时更新 `_pipPositionX/Y` |
| 添加 `handlePipPinch:` 方法 | 捏合缩放，实时更新 `_pipSize` |
| 添加 `UIGestureRecognizerDelegate` | 防止手势冲突 |
| 确认 `updateLayout` PiP 分支使用 `_pipPositionX/Y` 归一化计算（已存在 ✅） | 保证预览与保存一致 |
| 确认 `compositeFront:back:` PiP 分支使用 `_pipPositionX/Y` 归一化计算（已存在 ✅） | 保证保存与预览一致 |

### 5.2 DualCameraEventEmitter.m（事件通知）

| 改动 | 说明 |
|---|---|
| 添加 `sendPipPositionChanged:y:` 方法 | 拖动结束时通知 JS |
| 添加 `sendPipSizeChanged:` 方法 | 捏合结束时通知 JS |
| 在 `DualCameraEventEmitter.h` 中声明新方法 | 头文件声明 |

### 5.3 App.js（JS UI 调整）

| 改动 | 说明 |
|---|---|
| 画幅选择器移至左上角（`top: 60`） | 从 `bottom: 110` 改为 `top: 60` |
| 画幅选择器所有模式均显示 | 移除 `isDualCamMode` 条件 |
| PiP 模式 zoom bar 跟随小窗（动态绝对定位） | `left/top` 基于 `pipPosition + pipSize` 实时计算，竖向排列 |
| PiP 模式 zoom bar 控制小窗摄像头 | `isFlipped ? 'back' : 'front'`（flip 前=前置小窗，flip 后=后置小窗） |
| 监听 `onPipPositionChanged` 事件 | 更新 JS state 以便 JS 层也能访问最新位置 |
| 监听 `onPipSizeChanged` 事件 | 更新 JS state 以便 JS 层也能访问最新大小 |
| LR/SX 新增 `activeZoomTarget` state | `'primary'`（主区域=后置）/ `'secondary'`（次区域=前置） |
| LR/SX 新增摄像头切换按钮 `[后置▼]/[前置▼]` | 放在 zoom bar 左侧，点击切换 `activeZoomTarget` |
| `handleModeSwitch` 重置 `activeZoomTarget('primary')` | 布局切换时重置 zoom 目标为主区域 |
| PiP 移除调整面板的 `+`/`-` 按钮 | 大小完全通过捏合手势调节 |

### 5.4 DualCameraViewManager.m（确认 RCT_CUSTOM_VIEW_PROPERTY）

| 属性 | 确认状态 |
|---|---|
| `layoutMode` | ✅ 已有 |
| `saveAspectRatio` | ✅ 已有 |
| `dualLayoutRatio` | ✅ 已有 |
| `pipSize` | ✅ 已有 |
| `pipPositionX` | ✅ 已有 |
| `pipPositionY` | ✅ 已有 |
| `sxBackOnTop` | ✅ 已有 |
| `pipMainIsBack` | ✅ 已有 |
| `frontZoomFactor` | ✅ 已有 |
| `backZoomFactor` | ✅ 已有 |

### 5.5 新增依赖

**无新增外部依赖**。所有功能使用已有 API：
- `UIPanGestureRecognizer`（iOS SDK）
- `UIPinchGestureRecognizer`（iOS SDK）
- `UIGestureRecognizerDelegate`（iOS SDK）
- `DualCameraEventEmitter`（已有基础设施）

---

## 六、交互流程图（v3.0 增量部分）

```
用户点击左上角画幅选择器
    ↓
setSaveAspectRatio('3:4')
    ↓
JS state 更新 → Native prop 变化
    ↓
Native: 无需重建 session，layout 不变（viewport 由屏幕决定）
Native: saveAspectRatio 属性变化
    ↓
用户拍照
    ↓
internalTakePhoto → compositeFront:back: → saveCanvas = (refW, refW*4/3)
    ↓
保存 /3:4 比例的照片

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用户拖动 PiP 小窗
    ↓
UIPanGestureRecognizer 触发 → handlePipPan:
    ↓
_frontPreviewView.center 更新（主线程）
_pipPositionX/Y 更新（归一化）
    ↓
用户松手 → sendPipPositionChanged 事件
    ↓
JS 侧可选择性更新 state（用于调整面板显示）
    ↓
用户拍照 → compositePIPFront: → 使用最新 _pipPositionX/Y
    ↓
保存位置与预览完全一致（WYSIWYG）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用户捏合缩放 PiP 小窗
    ↓
UIPinchGestureRecognizer 触发 → handlePipPinch:
    ↓
_pipSize 更新 → updateLayout 重新计算 frame
    ↓
小窗尺寸实时变化（主线程）
    ↓
用户松手 → sendPipSizeChanged 事件
    ↓
用户拍照 → compositePIPFront: → 使用最新 _pipSize
    ↓
保存大小与预览完全一致（WYSIWYG）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PiP 模式下用户点击 zoom bar
    ↓
setZoom('front', 2.0) — 小窗摄像头是前置
    ↓
dc_setFrontZoom: 2.0 → AVCaptureDevice.videoZoomFactor = 2.0
    ↓
小窗画面实时缩放
    ↓
用户翻转 → 小窗变成后置
    ↓
zoom bar 显示后置档位 [0.5, 1.0, 2.0, 5.0]
    ↓
setZoom('back', 1.0) — 小窗现在是后置
    ↓
dc_setBackZoom: 1.0 → 后置摄像头缩放到 1.0x
```

---

## 七、已知陷阱与注意事项

### 7.1 PiP 拖动手势的坐标系
- `UIPanGestureRecognizer translationInView:` 使用传入的 view 坐标系
- 计算新 center 时：`center += translation`，然后 `[pan setTranslation:CGPointZero]` 重置增量
- clamp 时使用 `self.bounds`（画布坐标系），而非小窗自身的 bounds

### 7.2 PiP 拖动时 `_frontPreviewView` 是小窗还是主画面？
- `_frontPreviewView` 是**前置摄像头对应的预览视图**
- 在 PiP 模式下，它可能是小窗（`pipMainIsBack=YES`）或主画面（`pipMainIsBack=NO`）
- 只有当 `_frontPreviewView` 是小窗时，才应该添加拖动手势
- **解决方案**：始终给 `_frontPreviewView` 添加手势，但在 `handlePipPan:` 中判断：
  - 若当前 `_frontPreviewView.hidden == YES`（不是当前布局的活跃视图），忽略
  - 或：根据 `pipMainIsBack` 判断 `_frontPreviewView` 是否为小窗
  - **最佳方案**：当 `_frontPreviewView` 是小窗时启用拖动；是主画面时禁用

### 7.3 捏合缩放与拖动同时进行
- `UIPinchGestureRecognizer` 和 `UIPanGestureRecognizer` 可以同时识别（设置 `allowsSimultaneousRecognition`）
- 但 `handlePipPinch` 需要记录 `lastPipSize`，在 `Began` 时保存，在 `Changed` 时应用

### 7.4 PiP 圆形模式下的拖动
- 圆形 PiP 的 `cornerRadius = s/2` 在 `updateLayout` 中设置
- 拖动时 `cornerRadius` 会随 `_frontPreviewView.bounds` 自动更新（因为每次 `updateLayout` 都会重新计算）
- 无需额外处理

### 7.5 拖动后布局切换的安全性
- 如果用户在拖动 PiP 后立即切换布局（如从 PiP 切到 LR），`_pipPositionX/Y` 的值会保留
- 下次回到 PiP 模式时，会从上次拖动的位置恢复
- 这是**预期行为**，无需重置

### 7.6 LR/SX 独立双 zoom 的 UI 方案（终版 v3.0）
**用户决策**：LR/SX 模式下，每个摄像头独立变焦，默认控制主区域（后置），但**两个摄像头都可通过切换按钮控制**。

**方案否决**：每区域各自显示一套 zoom bar（竖屏空间太窄，会遮挡画面，且 UX 割裂）。

**最终方案**：单 zoom bar + 摄像头切换按钮：

```
LR/SX 顶部栏:
┌─────────────────────────────────────────┐
│ [9:16]  [后置▼]  [0.5x][1.0x][2.0x][5.0x] │
│          ← 点击"后置▼"展开为 "[后置▼]/[前置▼]" 二选一
└─────────────────────────────────────────┘

点击 [后置▼] → effectiveCamera = 'back'   → zoom bar 显示后置档位 [0.5, 1.0, 2.0, 3.0, 5.0]
点击 [前置▼] → effectiveCamera = 'front'  → zoom bar 显示前置档位 [1.0, 2.0]（0.5x 动态检测，支持则显示）
```

**JS state 设计**：
```javascript
const [activeZoomTarget, setActiveZoomTarget] = useState('primary');
// primary   = 主区域摄像头（LR左=后置，SX上=后置）
// secondary = 次区域摄像头（LR右=前置，SX下=前置）

// effectiveCamera 逻辑（终版）：
const effectiveCamera = (() => {
  if (cameraMode === CAMERA_MODE.BACK) return 'back';
  if (cameraMode === CAMERA_MODE.FRONT) return 'front';
  if (cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX) {
    // 顶部栏：切换按钮控制 current target，bar 显示对应档位
    return activeZoomTarget === 'primary' ? 'back' : 'front';
  }
  // PiP: 小窗摄像头
  return isFlipped ? 'back' : 'front';
})();

// activeZoomTarget 切换按钮文字：
const targetLabel = activeZoomTarget === 'primary' ? '后置▼' : '前置▼';
```

**0.5x 档位两种方案（都实现）**：
- 前置摄像头的 `minAvailableVideoZoomFactor` 通常为 1.0，当前所有 iOS 设备前置不支持 0.5x
- 代码按**方案 B（动态检测）**实现：从 `AVCaptureDevice.minAvailableVideoZoomFactor` 动态判断，只添加设备实际支持的档位
- 最终效果与方案 A 相同（前置 0.5x 不会显示），但代码更通用，为未来设备留有余地

**布局切换时的处理**：
- `handleModeSwitch` 中 `setActiveZoomTarget('primary')`（切到任何模式都重置为主区域）
- 保证进入新模式时 zoom bar 始终显示主区域的档位

**按钮样式**：
- `[后置▼]` / `[前置▼]`：小字圆角胶囊，backgroundColor: 'rgba(0,0,0,0.4)'，放在 zoom bar 左侧
- 切换按钮只出现在 LR/SX/PiP 模式下（单摄模式不需要，因为只有一个摄像头）

### 7.7 PiP zoom bar 跟随小窗 — 详细算法（终版 v3.0）

**UI 布局**：zoom bar 跟随 PiP 小窗，放在小窗**左侧**，**竖向排列**（每行一个档位）。

**跟随算法**：
```javascript
// 小窗相关参数
const pipW = pipSize * screenWidth;    // 小窗宽度（像素）
const pipH = pipSize * screenHeight;   // 小窗高度（像素）
const pipCenterX = pipPosition.x * screenWidth;
const pipCenterY = pipPosition.y * screenHeight;

// bar 放在小窗左侧，竖向排列
// bar 宽度约 44px，高度 = 档位数量 * 44px（每个按钮 44px 高）
const barW = 44;
const barH = effectiveZoomLevels.length * 44;

// 小窗左侧 x = 小窗中心X - 小窗宽度/2
// bar 右侧 x = 小窗左侧 x - 8（间距）
// bar 左侧 x = bar 右侧 x - bar 宽度
const rawBarLeft = pipCenterX - pipW / 2 - 8 - barW;
const clampedBarLeft = Math.max(0, Math.min(screenWidth - barW, rawBarLeft));

// bar 垂直居中于小窗中心
// 小窗上边缘 y = 小窗中心Y - 小窗高度/2
// bar 上边缘 y = 小窗上边缘 y + (小窗高度 - bar 高度) / 2
// 即：小窗上边缘 y + 小窗高度/2 - bar 高度/2
const rawBarTop = pipCenterY - pipH / 2 + pipH / 2 - barH / 2;
//                              = 小窗中心Y - bar 高度/2
const clampedBarTop = Math.max(0, Math.min(screenHeight - barH, rawBarTop));

const zoomBarStyle = {
  position: 'absolute',
  left: clampedBarLeft,
  top: clampedBarTop,
  width: barW,
  flexDirection: 'column',    // 竖向排列
  alignItems: 'center',
  gap: 4,
  // 动画过渡
  transition: 'left 0.1s ease-out, top 0.1s ease-out',
};
```

**边界碰撞**：`clampedBarLeft` / `clampedBarTop` 保证 bar 不会超出屏幕（无论小窗被拖到哪个角落）。

**竖向排列优势**：竖排宽度仅 44px，适合放在小窗左侧窄空间；横排宽度约 170px，空间不足。

**Native → JS 同步**：
- Native 拖动时实时更新 `_pipPositionX/Y`
- JS 监听 `onPipPositionChanged` 事件 → 更新 `pipPosition` state → zoom bar 重新渲染
- 手势结束时（`UIGestureRecognizerStateEnded`）发送事件，`transition` 动画让 bar 平滑跟随

**取消 +/- 按钮**：PiP 小窗大小完全通过**捏合手势**调节，JS 调整面板移除 `+`/`-` 按钮。

### 7.8 布局切换时重置 PiP 位置/大小
**用户决策**：切换布局模式后，PiP 位置/大小重置为默认值。

```javascript
const handleModeSwitch = useCallback((mode) => {
  setCameraMode(mode);
  setDualLayoutRatio(0.5);
  setPipSize(0.28);       // 重置大小
  setPipPosition({ x: 0.85, y: 0.80 }); // 重置位置
  setActiveZoomTarget('primary'); // 重置 zoom 目标
  setShowAdjustment(false);
  setIsFlipped(false);
}, []);
```

**注意**：`DualCameraView` 的 `_pipPositionX/Y` 也会随 JS state 同步更新（通过 prop）。

---

## 八、LR/SX 独立双 zoom — 扩展规格

### 8.1 JS 层修改（App.js）

| 改动 | 说明 |
|---|---|
| 新增 `activeZoomTarget` state | `'primary'` \| `'secondary'` |
| 新增 `[后置▼]/[前置▼]` 切换按钮 | 放在 zoom bar 上方 |
| `effectiveCamera` 逻辑扩展 | LR/SX 模式按 `activeZoomTarget` 决定 |
| `handleModeSwitch` 中重置 `activeZoomTarget` | 切模式时重置为主区域 |
| PiP 模式 zoom bar 改为动态绝对定位 | `left/top` 跟随小窗位置 |

### 8.2 Native 层无需修改

`dc_setFrontZoom:` / `dc_setBackZoom:` 已完整实现，JS 层调用 `setZoom('front', level)` / `setZoom('back', level)` 即可。

---

## 九、PiP zoom bar 跟随小窗 — 扩展规格

### 9.1 JS 层修改（App.js）

| 改动 | 说明 |
|---|---|
| 监听 `onPipPositionChanged` 事件 | 更新 `pipPosition` state |
| `zoomBarStyle` 改为动态计算 | `left/top` 基于 `pipPosition` + `pipSize` |
| 竖向排列 zoom bar | `flexDirection: 'column'` |
| `transition` 动画 | `left 0.1s, top 0.1s` |

### 9.2 Native 层修改（DualCameraEventEmitter.m）

| 改动 | 说明 |
|---|---|
| `supportedEvents` 增加 `onPipPositionChanged` | 事件名注册 |
| 新增 `sendPipPositionChanged:y:` 方法 | 拖动结束时发送 |

### 9.3 事件 Schema

```javascript
// Native → JS
NativeModules.DualCameraEventEmitter
  .addListener('onPipPositionChanged', (event) => {
    // event = { x: 0.72, y: 0.65 }（归一化坐标）
    setPipPosition({ x: event.x, y: event.y });
  });
```

---


## 十、用户决策记录（终版 v3.0 — 2026-05-01 确认）

| # | 问题 | 用户决策 |
|---|---|---|
| 1 | 画幅切换时 dualLayoutRatio 行为 | 保持当前比例（不变） |
| 2 | LR/SX 两个摄像头变焦方式 | 独立缩放（非同步），两个都可通过切换按钮控制 |
| 3 | PiP zoom bar 定位 | 跟随小窗位置（动态绝对定位），动画过渡 |
| 4 | PiP 位置/大小跨布局保留？ | 切换模式时重置（不保留） |
| 5 | PiP zoom bar 控制对象 | 小窗摄像头（非主画面） |
| 6 | 画幅选择器位置 | 左上角（所有模式均显示） |
| 7 | PiP +/- 调整按钮 | 取消，仅通过捏合手势调节大小 |
| 8 | SX zoom bar 屏幕位置 | 顶部（与 LR 一致），跟随竖向布局 |
| 9 | 前置 0.5x 档位 | 动态检测（方案 B），代码支持但当前 iOS 设备前置不支持故不显示 |
| 10 | activeZoomTarget 默认值 | 默认 primary（主区域=后置），可切换到 secondary（次区域=前置） |
| 11 | LR/SX zoom bar 展示方式 | 单 bar + 摄像头切换按钮（[后置▼]/[前置▼]），顶部栏 |
| 12 | PiP zoom bar 排列方式 | 竖向排列（flexDirection: column），放在小窗左侧 |

---

## 十一、验收标准（终版 v3.0 — 2026-05-01 更新）

| # | 验收项 | 验证方法 |
|---|---|---|
| 1 | 左上角画幅选择器：点击 9:16/3:4/1:1 切换，当前选中高亮 | 手动点击观察 UI 变化 |
| 2 | 画幅切换后，拍照保存的画幅与选择一致 | 拍照 → 相册 → 查看比例 |
| 3 | 画幅切换时，LR/SX 分屏比例（dualLayoutRatio）保持不变 | 调节分割线到 30% → 切换画幅 → 确认仍为 30% |
| 4 | PiP 小窗可被手指拖动到任意位置 | 手指拖动，观察预览实时更新 |
| 5 | 拖动后拍照，小窗位置与预览完全一致 | 拖动 → 拍照 → 对比预览位置 |
| 6 | PiP 小窗可通过捏合手势放大/缩小 | 两指捏合，观察小窗实时缩放 |
| 7 | 捏合后拍照，小窗大小与预览完全一致 | 捏合 → 拍照 → 对比预览大小 |
| 8 | PiP 模式下 zoom bar 显示小窗摄像头的档位 | 点击 flip，观察 zoom bar 档位变化 |
| 9 | PiP 模式下 zoom bar 控制小窗摄像头（非主画面） | 调节 zoom → 观察小窗画面变化（而非主画面） |
| 10 | 所有模式（单摄/双摄/PiP）左上角均显示画幅选择器 | 切换各模式，确认左上角始终可见 |
| 11 | 布局切换后，PiP 位置/大小重置为默认值 | 拖动 PiP → 切换到 LR → 切回 PiP → 位置回到默认 |
| 12 | LR/SX 模式下，切换摄像头（[后置▼]/[前置▼]）后 zoom bar 显示正确档位 | 点击 [前置▼] → 显示前置档位 [1.0, 2.0]（0.5x 动态检测） |
| 13 | LR/SX 独立 zoom：后置 zoom 变化不影响前置 zoom | 调节后置到 2.0x → 切换到前置 → 调节前置到 1.0x → 切回后置 → 确认为 2.0x |
| 14 | PiP zoom bar 跟随小窗拖动 | 拖动小窗 → zoom bar 跟随移动（动画过渡） |
| 15 | 小窗拖到屏幕左边缘时，zoom bar 不会超出屏幕 | 将小窗拖到最左 → 确认 zoom bar 可见 |
| 16 | LR/SX 顶部栏默认控制主区域（后置），可切换到前置 | 进入 LR/SX → zoom bar 显示后置档位 → 点击 [前置▼] → 切换到前置档位 |
| 17 | 布局切换后 activeZoomTarget 重置为 primary | 调节前置 zoom → 切换到其他布局 → 切回 → 确认 bar 仍显示后置档位 |
| 18 | PiP 无 +/- 按钮，仅捏合调节大小 | 切换到 PiP → 确认无 +/- 按钮 → 两指捏合可缩放 |
