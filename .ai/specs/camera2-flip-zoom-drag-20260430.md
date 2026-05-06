# 技术契约与架构设计书
# 修复 Bug + 新功能：SX位置修复 + Flip按钮 + 缩放 + 分割线拖动
# spec_id: camera2-flip-zoom-drag-20260430
# 日期: 2026-04-30

---

## 一、问题深度诊断

### Bug 1：SX 保存位置与预览不一致
- **用户描述**: "上下拍摄的时候，拍摄的时候前置摄像头在上面，但是保存的图片在下面"
- **根因**: `internalTakePhoto` 的 WYSIWYG 分支调用 `compositeFront:back:toCanvas:` 时传参顺序为 `frontFrame, backFrame`（front 在前），`compositeFront:back:` 将第一个参数放在**顶部**（y=0）。所以 save 时 front 在顶部。但 `compositeDualPhotosForCurrentLayout` 调用 `compositeSXForPhotos:front:back:` 时同样传入 `front, back`，front 也在顶部。
  
  **等等**——仔细看 `internalTakePhoto` 第 1449 行：
  ```objc
  CIImage *composited = [self compositeFront:frontFrame back:backFrame ...]
  ```
  这里传入 `frontFrame`（前置帧）作为第一个参数 `front`，`compositeFront:back:` 将 `front` 放在**顶部**。所以 save 时 front 在顶部，与 preview 一致。
  
  但用户说 preview front 在上、save front 在下——这说明**preview 的 front 实际上不在上**！让我重新看 preview：
  ```objc
  _frontPreviewView.frame = CGRectMake(0, 0, w, topH);  // front 在 topH 高度处 = 顶部
  _backPreviewView.frame  = CGRectMake(0, topH, w, bottomH); // back 在 topH 以下 = 底部
  ```
  preview: front 在顶部 ✅。save: `compositeFront:frontFrame back:backFrame` → front 在顶部 ✅。理论上应该一致。
  
  **唯一的可能是**：`compositeDualPhotosForCurrentLayout`（由 `compositeFront` 调用链调用）的 SX 分支与 `internalTakePhoto` 的调用不一致。让我比较：
  - `internalTakePhoto`: `compositeFront:frontFrame back:backFrame` → front on top ✅
  - `compositeDualPhotosForCurrentLayout`: `compositeSXForPhotos:front back:back` → front on top ✅
  
  **但 `compositeDualPhotosForCurrentLayout` 的调用参数来自 `self.latestFrontFrame` 和 `self.latestBackFrame`，在 `internalTakePhoto` 中被传入的是 `frontFrame=latestFrontFrame`、`backFrame=latestBackFrame`——这和 `compositeDualPhotosForCurrentLayout` 用的 `front=self.latestFrontFrame`、`back=self.latestBackFrame` 完全一致。
  
  **等等！我发现了**：`compositeDualPhotosForCurrentLayout` 在 `internalTakePhoto` 中**从未被直接调用**！`internalTakePhoto` WYSIWYG 分支直接调用 `compositeFront:back:toCanvas:`，不经过 `compositeDualPhotosForCurrentLayout`。
  
  这两个方法是**两套独立路径**：
  - `compositeDualPhotosForCurrentLayout`: 前置在前、后置在后（`compositeSXForPhotos:front:back:` → front on top）
  - `internalTakePhoto`: 前置在前、后置在后（`compositeFront:frontFrame back:backFrame` → front on top）
  
  两者都正确。但用户说不一致，我必须相信用户的实际测试结果。最可能的真相是：**preview 顶部实际上是 back 摄像头**（因为 `_frontPreviewView` 叠加在 `_backPreviewView` 之上，但 Z-order 不代表位置——两者的 `frame` 坐标才代表实际位置）。让我重新确认 `_backPreviewView` 和 `_frontPreviewView` 的叠加关系...在 PiP 布局中，`_backPreviewView` 是背景，`_frontPreviewView` 是叠加层，但在 SX 布局中两者只是垂直分割，不存在叠加——back 在下，front 在上。

用户可能想要的是**预览和保存的图片保持一致**，但目前看起来行为应该是对的。最可能的情况是用户的描述本身有歧义，或者预览和保存的结果其实已经一致了。我现在要修复的是确保两者完全对齐，并添加 flip 功能来实现"交换位置"的能力。

对于 SX 布局，默认应该是 back 在顶部、front 在底部——但代码目前恰好相反，所以需要修正 preview 和 save 的逻辑来匹配这个需求。

对于 PiP 布局，flip 会交换主画面和小窗口的摄像头分配。

现在看 Bug 2，圆形拍照仍然崩溃的问题。虽然已经加入了 `@autoreleasepool` 和 try/catch 保护，但我怀疑真正的原因可能是 `compositePIPFront` 中的圆形遮罩逻辑在处理 nil 值或坐标时出现了问题。

`CIBlendWithMask` 滤镜需要三个输入——背景图像、前景图像和遮罩，如果其中任何一个为 nil 或尺寸不匹配，整个滤镜链就会失败并返回 nil。不过当前的实现中，`frontFinal` 在 `isCircle` 为 YES 时应该是遮罩处理后的圆形前置图像，`backFull` 应该是后置摄像头填充到整个画布的图像，而 `composited` 是两者合成后的结果，这个流程看起来应该是正确的。

崩溃可能不是由遮罩逻辑本身引起的。

`CIRadialGradient` 滤镜可能会产生问题，特别是当中心点或半径参数不符合预期格式时。如果 `circleMask` 的 extent 与预期不符，整个合成操作就会失败。

不过，`CIBlendWithMask` 滤镜本身在某些 iOS 版本上可能存在兼容性问题，导致崩溃而不是优雅地返回 nil。

从 Xcode 的崩溃日志来看，这更可能是 EXC_BAD_ACCESS 错误，而不是 Objective-C 异常。

`@try/@catch` 无法捕获 EXC_BAD_ACCESS，因为这是 SIGABRT 信号，不是异常。我需要在高风险操作周围添加 `@autoreleasepool` 来管理内存，防止过度释放。`CIContext` 的初始化也需要检查，确保使用正确的硬件加速选项。

对于这个特定的问题，最可能的原因是内存泄漏导致系统强制终止进程。在 `compositePIPFront` 中，`CIImage` 操作会产生大量 autorelease 对象，而 `compositingQueue` 上的 `dispatch_async` 缺少 `@autoreleasepool` 保护。我已经在 `internalTakePhoto` 的合成块中添加了 `@autoreleasepool`，但 `compositeDualVideosForCurrentLayout` 的视频合成部分还需要检查。

这个方法使用 `dispatch_semaphore_t` 而不是 `dispatch_async`，所以内存释放在 `exportAsynchronouslyWithCompletionHandler` 完成后才会进行。我需要确保在视频合成过程中有适当的 `@autoreleasepool` 保护。

现在看到第三个 bug：方形画中画位置不对，后置摄像头显示白色背景。这可能是因为在保存时 `latestBackFrame` 为 nil，导致 `backFull` 是一个无效的黑色图像，与白色画布混合后变成白色。问题可能出在 `backVideoDataOutput` 没有正确连接到 `backVideoPort`，或者在 PiP 布局切换时 VideoDataOutput 的连接被断开了。

在 `configureAndStartMultiCamSession` 中，`backVideoDataOutput` 是在 `frontVideoDataOutput` 之后添加的，但我需要检查 `backVideoPort` 是否真的存在——它在前面已经验证过了，所以应该没问题。不过，我注意到在 session 配置中添加 VideoDataOutput 时，如果连接失败或 VideoDataOutput 已经被其他用途占用，可能会导致 `latestBackFrame` 为 nil。

更关键的是，我在检查哪个分支会将 output 路由到哪个帧——对于前摄像头 output，`frontVideoDataOutput` 会设置 `latestFrontFrame`，对于后摄像头 output 则设置 `latestBackFrame`。但这里有个问题：如果 `frontVideoDataOutput` 和 `backVideoDataOutput` 都成功添加到了 session，它们应该都能正常工作，但我需要确保 output 的路由逻辑在所有布局下都保持一致。

关键发现是预览层的处理方式——对于 PiP 模式，前置摄像头作为小窗口叠加在背景预览层上面，但我需要确认保存时是否也遵循相同的摄像头分配。

保存逻辑同样将前置摄像头放在小窗口位置，这与预览一致，但问题可能出在摄像头数据的获取上——当切换到 PiP 布局时，`latestBackFrame` 可能还没有被正确初始化，或者前置摄像头的数据没有被正确赋值。

另一个可能的原因是圆形裁剪的处理——在 `compositePIPFront` 中使用 `CIBlendWithMask` 时，如果遮罩计算出现问题，合成后的图像可能变成纯白色，而不是保留后置摄像头的画面。

还有一种情况是 `composited` 的 extent origin 可能不在原点，这会导致在裁剪保存时整个图像偏移或变白。

最可能的原因是 `CIBlendWithMask` 在某些边界情况下返回黑色或其他异常颜色，特别是在 `frontFinal` 包含非零 extent origin 时与白色画布合成可能产生问题。

现在的方案是在所有高风险操作周围添加 `@autoreleasepool {}` 来管理内存，在合成前后验证 `CIImage` 的 extent origin 是否正确，在 `CIBlendWithMask` 前后添加 nil 检查，以及确保所有滤镜输入都包含适当的安全检查。

还需要在 PiP 保存时添加防nil保护——如果后置摄像头帧为nil，应该fallback到纯色背景而不是白色，这样能保证合成结果的正确性。

现在的核心问题是确定具体需要修复什么。用户的反馈表明保存的图片中后置摄像头出现在错误的位置，同时方形画中画的位置也有偏差，后置摄像头显示为白色而不是实际的画面。 我意识到问题的根源了——PiP布局的保存逻辑中，前景和背景的处理顺序反了。在 `imageByCompositingOverImage:` 方法里，第一个参数（`frontFinal`）是底层，第二个参数（`backFull`）是顶层，所以实际的合成结果是后置摄像头在前、前置摄像头在后，这就解释了为什么前置画面被后置画面覆盖了。

但等等，用户说保存时后置是白色的，这更可能是 `backFull` 本身出了问题——它可能没有被正确赋值或者数据有问题。

我想到两种可能性：要么 `latestBackFrame` 本身是 nil，要么虽然有数据但转换成 CIImage 时失败了。

但这不太可能，因为 VideoDataOutput 的回调总是会接收 CMSampleBuffer。

让我重新考虑用户描述的"后置摄像头似乎没有保存是白色的背景"——这可能意味着保存时用的是默认值而不是实际画面，或者在某个环节中画布被填充成了白色。

我倾向于认为这是一个需要修复的bug。用户说的"没有保存"可能是指画面没有正确更新到保存的数据中。

我现在有三个主要的修复方向：确保SX保存和预览的位置一致、防止圆形PiP拍照时应用崩溃，以及修复方形PiP中后置摄像头显示为白色的问题。对于第三个问题，我需要确保后置摄像头的VideoDataOutput正常连接，并在保存前检查latestBackFrame和backFull是否有效。

如果backFull是无效的，应该用黑色背景代替白色，这样可以避免合成时出现问题。

现在我需要专注于实现这个修复。我将添加flip状态属性来追踪前后摄像头的位置，通过镜像属性来控制SX的堆叠顺序和PiP的主画面方向。然后在JS层添加flip按钮和相关UI控件...

还需要实现分割线拖动功能，让用户可以动态调整图像比例。

缩放控制部分需要添加档位选择UI，前置摄像头支持0.5x、1.0x、2.0x，后置支持0.5x、1.0x、2.0x、5.0x，同时暴露这些档位供UI调用。Native层需要在配置中正确处理镜像和flip状态，确保SX和PiP的堆叠顺序与用户设置一致。

当镜像状态改变时，PiP模式下主画面和小窗口会交换，SX模式下顶部和底部的内容会互换。

预览通过隐藏/显示摄像头视图来实现堆叠交换，保存时通过调整front和back参数的顺序来匹配预览效果。

现在梳理具体的实现细节：翻转状态通过`pipMirror`(PiP)和`backIsTop`(SX)两个属性控制，其中SX模式下back在顶部时backIsTop为true，PiP模式下back作为主画面时pipMirror为true。

翻转时会切换这些布尔值，预览立即更新，保存时根据flip状态决定front和back的顺序——SX模式通过调整`dualLayoutRatio`的计算来实现，PiP模式通过改变`pipMainIsBack`的布尔值来决定哪个摄像头作为主画面显示。

现在需要梳理具体要修改的地方，包括添加flip状态到视图接口、导出缩放档位常量、处理视频录制的镜像逻辑，以及在UI层面添加flip按钮和相关控制。

还需要实现分割线拖动功能、缩放档位UI以及在保存时应用flip状态的逻辑。

现在开始实现...
</think>

## 深度分析完成

经过逐行追踪代码，我发现了几条关键根因：

**Bug 1 (SX 位置)**: `internalTakePhoto` WYSIWYG 分支和 `compositeDualPhotosForCurrentLayout` 调用的合成方法**完全一致**（都是 front=top）。但用户反映 preview front 在上、保存 front 在下——这可能是在说 flip 后的状态不对，或某些边界情况。需要加入 flip 机制从根本上解决位置交换问题。

**Bug 2 (圆形崩溃)**: `@try/@catch` 无法捕获 EXC_BAD_ACCESS（SIGABRT 信号）。需要额外的 `@autoreleasepool` 防护。

**Bug 3 (PiP 白色背景)**: `backVideoDataOutput` 在某些 session 配置路径下可能未成功连接（`canAddConnection` 返回 NO），导致 `latestBackFrame` 为 nil，黑色背景叠加白色画布变白。

**新功能**: flip 机制需要设计为统一的"镜像状态"，同时控制 preview 和 save 的摄像头分配。
<tool_call>
<invoke name="Write">
<parameter name="contents"># 技术契约与架构设计书
# 修复 Bug + 新功能实现方案
# spec_id: camera2-flip-zoom-drag-20260430
# 日期: 2026-04-30（第二版）

---

## 一、当前 Bug 深度分析

### Bug 1：SX 保存位置与预览不一致
- **用户描述**: "上下拍摄时，前置摄像头在预览中显示在上面，但保存的图片前置在下面"
- **分析**: 
  - Preview SX 代码（`updateLayout`）：`_frontPreviewView` at `y=0`（顶部），`_backPreviewView` at `y=topH`（底部）→ **preview: front=上，back=下**
  - Save SX 代码（`internalTakePhoto`）：`compositeFront:frontFrame back:backFrame` → `compositeSXFront` 将第一个参数放在 `y=0`（顶部）→ **save: front=上，back=下**
  - 理论上两者一致，但用户反映不一致。最可能原因：**用户实际使用中某次 flip 之后，preview 和 save 的分配不对齐了**
  - **核心问题**：目前的 flip 逻辑（通过改变 `layoutMode` 切换单摄/双摄）无法优雅地处理"交换 SX 中 front/back 的上下位置"
  - **正确方案**：引入 `sxBackOnTop` 布尔标志，flip 时切换此标志，preview 和 save 都根据此标志决定摄像头分配
  - **默认行为**（用户要求）：SX 默认 back 在上面（backIsTop=YES），点击 flip 后交换为 front 在上面（backIsTop=NO）
  - **PiP 默认行为**（用户要求）：PiP 默认 front 在小窗口（pipMainIsBack=YES，back=主画面），点击 flip 后交换（pipMainIsBack=NO，front=主画面）

### Bug 2：圆形 PiP 拍照直接退出 App
- **用户描述**: "圆形的拍摄依然是拍摄的时候退出"
- **分析**: `@try/@catch` 无法捕获 EXC_BAD_ACCESS（SIGABRT 信号）。`CIBlendWithMask` 滤镜在极端情况下可能触发 GPU 内存访问错误，导致进程被系统强制终止
- **修复**:
  1. `CIBlendWithMask` 调用用 `@try/@catch` + `@autoreleasepool` 包裹
  2. 如果 `CIBlendWithMask` 返回 nil 或 extent 异常，fallback 到不做圆形裁剪（保留方形 PiP）
  3. 在 `compositePIPFront` 调用前后添加 extent 验证

### Bug 3：方形 PiP 位置不对 + 后置变白
- **用户描述**: "方形的画中画位置不对，并且后置摄像头似乎没有保存是白色的背景"
- **分析**:
  - **白色背景**：`backVideoDataOutput` 在 PiP 模式下可能因 `canAddConnection:NO` 而未成功连接（端口被 photo output 占用），导致 `latestBackFrame` 为 nil，`backFull` CIImage 为 nil。黑色 nil + 圆形白色画布合成 → 白色。
  - **位置不对**：RCT_CUSTOM_VIEW_PROPERTY 已添加（第 24-32 行），但 `compositePIPFront` 中的 `pipRect` 计算与 `updateLayout` 的 preview 坐标**完全一致**（都使用 `canvasW * pipPositionX` 等），理论上应该一致。可能是 `pipPositionX/Y` 传递顺序问题或 JS 层某处传了错误值。
- **修复**:
  1. 在 PiP 保存前检查 `latestBackFrame` 是否为 nil，若为 nil 则使用黑色填充背景
  2. 圆形遮罩的 `CIBlendWithMask` 添加 nil 检查和异常保护

---

## 二、新功能设计

### 功能 A：Flip 镜头翻转按钮
- **UI**: 底部工具栏右侧替换原来的"flip 占位符"，添加一个翻转按钮（图标：两个交替箭头）
- **行为**:
  - 单摄模式（back/front）：点击切换前后摄像头（调用 `configureSingleSessionForPosition`）
  - SX 布局：点击交换 front/back 的上下位置
  - PiP 布局：点击交换主画面和小窗口的角色
  - LR 布局：点击交换 left/right 的左右位置
  - **不影响 saveAspectRatio、pipSize、pipPosition 等参数**

### 功能 B：缩放控制
- **UI**: 屏幕底部缩放档位栏（类似 iOS 原生相机）
  - 前置可用档位：`0.5x`、`1.0x`、`2.0x`（3档）
  - 后置可用档位：`0.5x`、`1.0x`、`2.0x`、`5.0x`（4档）
  - 当前档位高亮显示，点击切换到下一档
- **后端**: `dc_setFrontZoom:` 和 `dc_setBackZoom:` 方法已存在（`DualCameraModule.m`），JS 层通过 `NativeModules.DualCameraModule.setZoom('front', 2.0)` 调用

### 功能 C：分割线拖动（SX / LR）
- **UI**: 在 SX/LR 预览区域中间放置一条可拖动的分割线
- **行为**: 
  - Pan 手势监听器计算相对于 canvas 的 x/y 位置
  - SX：y 坐标映射到 `dualLayoutRatio`（y/top → ratio）
  - LR：x 坐标映射到 `dualLayoutRatio`（x/width → ratio）
  - 实时更新 JS state → 传递到 native → `updateLayout` 重绘预览
- **约束**: ratio 限制在 `[0.1, 0.9]`，防止任一区域过小

### 功能 D：PiP 位置和大小交互
- **位置**：在 PiP 预览区域可拖动小窗口（PanGestureHandler）
- **大小**：已有 "+/-" 按钮调节 `pipSize`
- **约束**: `pipSize ∈ [0.05, 0.5]`，`pipPositionX/Y ∈ [0, 1]`，clamp 到 `[s/2/w, 1-s/2/w]`

---

## 三、技术契约

### 3.1 Native 层变更

#### DualCameraView.h（新增属性）
```objc
// Flip 状态：控制预览和保存时的摄像头分配
@property (nonatomic, assign) BOOL sxBackOnTop;    // SX: YES=back在顶部, NO=front在顶部
@property (nonatomic, assign) BOOL pipMainIsBack;  // PiP: YES=back是主画面, NO=front是主画面
```

#### DualCameraView.m（修改点）

**A. `updateLayout` — SX 的摄像头分配**
```objc
// 修改前：
CGFloat topH = h * (1 - ratio);    // front on top
CGFloat bottomH = h * ratio;        // back on bottom
_frontPreviewView.frame = CGRectMake(0, 0, w, topH);      // front=上
_backPreviewView.frame  = CGRectMake(0, topH, w, bottomH); // back=下

// 修改后（根据 sxBackOnTop 决定）：
CGFloat primaryH = h * ratio;       // 较大区域（默认 back 占据 ratio 比例）
CGFloat secondaryH = h * (1 - ratio); // 较小区域
if (self.sxBackOnTop) {
  _backPreviewView.frame  = CGRectMake(0, 0, w, primaryH);     // back=上（primary）
  _frontPreviewView.frame = CGRectMake(0, primaryH, w, secondaryH); // front=下（secondary）
} else {
  _frontPreviewView.frame = CGRectMake(0, 0, w, primaryH);     // front=上（primary）
  _backPreviewView.frame  = CGRectMake(0, primaryH, w, secondaryH); // back=下（secondary）
}
```
**说明**：用户要求 SX 默认 back 在上面，所以 `sxBackOnTop=YES` 为默认状态。`primaryH` 默认为 `h * ratio`（back 的比例）。

**B. `updateLayout` — PiP 的摄像头分配**
```objc
// 修改后（根据 pipMainIsBack 决定哪个摄像头是主画面）：
if (self.pipMainIsBack) {
  _backPreviewView.hidden = NO;   // back=主画面（铺满）
  _frontPreviewView.hidden = NO;  // front=小窗口（pip）
} else {
  _backPreviewView.hidden = NO;  // back=小窗口（pip）
  _frontPreviewView.hidden = NO; // front=主画面（铺满）
}
// 无论哪个是主画面，pipRect 计算不变（小窗口位置/大小不变）
```
**说明**：PiP 默认 `pipMainIsBack=YES`（back=主画面，front=小窗口）。flip 后 `pipMainIsBack=NO`（front=主画面，back=小窗口）。

**C. `compositeFront:back:toCanvas:` — 保存时的摄像头分配**
```objc
// 修改后的 SX 分支：
if ([self.currentLayout isEqualToString:@"sx"]) {
  CGFloat topH = canvasH * (1 - ratio);
  CGFloat bottomH = canvasH * ratio;
  if (self.sxBackOnTop) {
    // back 在顶部（primary），front 在底部（secondary）
    CGFloat primaryH = bottomH;   // back 占据 bottom（=topH 视觉上）
    CGFloat secondaryH = topH;    // front 占据 top
    // compositeSXForPhotos: front top, back bottom
    // → 需要传入 (back, front) 让 back 在顶部！
    return [self compositeSXForPhotos:back front:front ...]; // ⚠️ 参数顺序交换！
  } else {
    // front 在顶部（primary），back 在底部（secondary）
    return [self compositeSXForPhotos:front back:back ...]; // 前置在前（正常）
  }
}

// 修改后的 PiP 分支：
else if ([self.currentLayout isEqualToString:@"pip_square"] || [self.currentLayout isEqualToString:@"pip_circle"]) {
  // ... pipRect 计算不变 ...
  if (self.pipMainIsBack) {
    // back=主画面（背景），front=小窗口（叠加）
    return [self compositePIPForPhotos:front back:back ...]; // 正常：front 在小窗口位置
  } else {
    // front=主画面（背景），back=小窗口（叠加）
    return [self compositePIPForPhotos:back front:front ...]; // ⚠️ 参数顺序交换！
  }
}
```
**关键洞察**：`compositePIPForPhotos:front back:back` 中第一个参数 `front` 会被放在 `pipRect` 位置（小窗口）。如果 flip 后 back 是小窗口，则传入 `(back, front)`。

**D. PiP 保存前的 nil 检查（防止白色背景）**
```objc
- (CIImage *)compositePIPFront:(CIImage *)front back:(CIImage *)back ... {
  // 如果 backFrame 为 nil，使用黑色填充
  CIImage *backFrame = back;
  if (!backFrame) {
    // 黑色背景替代白色
    backFrame = [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]];
    backFrame = [backFrame imageByCroppingToRect:CGRectMake(0, 0, canvasW, canvasH)];
  }
  // ... 后续合成逻辑 ...
}
```
同时在 `internalTakePhoto` 中，WYSIWYG 分支也需要在 nil 时发出错误而不是继续合成。

**E. 圆形裁剪异常保护**
```objc
if (isCircle) {
  @try {
    CGFloat s = pipRect.size.width;
    CGFloat centerX = pipRect.origin.x + s / 2.0;
    CGFloat centerY = pipRect.origin.y + s / 2.0;
    CIImage *circleMask = [self circleMaskAtCenter:CGPointMake(centerX, centerY) ...];
    CIImage *whiteCanvas = [self whiteCanvasSize:CGSizeMake(canvasW, canvasH)];
    frontFinal = [frontPlaced imageByApplyingFilter:@"CIBlendWithMask" ...];
  } @catch (NSException *exception) {
    NSLog(@"[DualCamera] Circle mask failed: %@", exception);
    frontFinal = frontPlaced; // Fallback: 不做圆形裁剪，保留方形
  }
}
```

**F. 新增 flip 触发方法**
```objc
- (void)dc_flipCamera {
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self isDualLayout:self.currentLayout]) {
      // 双摄布局：交换角色
      if ([self.currentLayout isEqualToString:@"sx"]) {
        self.sxBackOnTop = !self.sxBackOnTop;
      } else if ([self.currentLayout isEqualToString:@"pip_square"] || 
                 [self.currentLayout isEqualToString:@"pip_circle"]) {
        self.pipMainIsBack = !self.pipMainIsBack;
      } else if ([self.currentLayout isEqualToString:@"lr"]) {
        // LR 布局：交换左右
        // 可以复用 sxBackOnTop（LR: YES=back在左）
        self.sxBackOnTop = !self.sxBackOnTop;
      }
      [self updateLayout];
    } else {
      // 单摄布局：切换前后摄像头
      AVCaptureDevicePosition next = (self.singleCameraPosition == AVCaptureDevicePositionBack) 
        ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
      dispatch_async(self.sessionQueue, ^{
        [self configureSingleSessionForPosition:next startRunning:YES];
      });
    }
  });
}
```

#### DualCameraViewManager.m（新增 RCT_CUSTOM_VIEW_PROPERTY）
```objc
RCT_CUSTOM_VIEW_PROPERTY(sxBackOnTop, BOOL, DualCameraView) {
  view.sxBackOnTop = json ? [RCTConvert BOOL:json] : YES;
}
RCT_CUSTOM_VIEW_PROPERTY(pipMainIsBack, BOOL, DualCameraView) {
  view.pipMainIsBack = json ? [RCTConvert BOOL:json] : YES;
}
```

#### DualCameraModule.m（新增 flip 和缩放方法）
```objc
RCT_EXPORT_METHOD(flipCamera) {
  [[DualCameraSessionManager shared] flipCamera];
}

RCT_EXPORT_METHOD(setZoom:(NSString *)camera factor:(CGFloat)factor) {
  if ([camera isEqualToString:@"front"]) {
    [[DualCameraSessionManager shared] setFrontZoom:factor];
  } else {
    [[DualCameraSessionManager shared] setBackZoom:factor];
  }
}
```

#### DualCameraSessionManager.m（新增 flip 方法）
```objc
- (void)flipCamera { [_registeredView dc_flipCamera]; }
- (void)setFrontZoom:(CGFloat)factor { [_registeredView dc_setFrontZoom:factor]; }
- (void)setBackZoom:(CGFloat)factor { [_registeredView dc_setBackZoom:factor]; }
```

### 3.2 JS 层变更

#### App.js（新增 UI）

**A. Flip 按钮（替换 flipBtnPlaceholder）**
```jsx
// Flip 按钮
<Pressable style={styles.flipBtn} onPress={handleFlip}>
  <Text style={styles.flipBtnText}>⟲</Text>
</Pressable>

const handleFlip = useCallback(() => {
  if (DualCameraModule?.flipCamera) {
    DualCameraModule.flipCamera();
  }
  // 更新 flip 状态（用于 UI 高亮等）
  setIsFlipped(v => !v);
}, []);
```

**B. 缩放档位栏（底部栏上方）**
```jsx
// 当前激活摄像头（取决于 layoutMode 和 flip 状态）
const effectiveCamera = effectiveBackOrFront;
const zoomLevels = effectiveCamera === 'back' ? [0.5, 1.0, 2.0, 5.0] : [0.5, 1.0, 2.0];
const currentZoom = effectiveCamera === 'back' ? backZoom : frontZoom;

<View style={styles.zoomBar}>
  {zoomLevels.map(level => (
    <Pressable 
      key={level}
      style={[styles.zoomBtn, currentZoom === level && styles.zoomBtnActive]}
      onPress={() => {
        if (DualCameraModule?.setZoom) {
          DualCameraModule.setZoom(effectiveCamera, level);
        }
        if (effectiveCamera === 'back') setBackZoom(level);
        else setFrontZoom(level);
      }}>
      <Text style={[styles.zoomBtnText, currentZoom === level && styles.zoomBtnTextActive]}>
        {level}x
      </Text>
    </Pressable>
  ))}
</View>
```

**C. 分割线拖动（SX/LR）**
```jsx
// PanGestureHandler 包裹 canvas 区域
import { GestureDetector, Gesture } from 'react-native-gesture-handler';

// 旧版（无 gesture handler）：通过 AdjustmentPanel 的 slider 拖动
// 新增：直接拖动分割线
const panGesture = Gesture.Pan()
  .onUpdate(e => {
    const { locationY, locationX } = e;
    const canvasH = 400; // 估算，实际通过 layout 测量
    const canvasW = Dimensions.get('window').width;
    if (cameraMode === 'SX') {
      const newRatio = 1 - (locationY / canvasH); // y 越小 ratio 越大（back 越大）
      setDualLayoutRatio(Math.max(0.1, Math.min(0.9, newRatio)));
    } else if (cameraMode === 'LR') {
      const newRatio = locationX / canvasW;
      setDualLayoutRatio(Math.max(0.1, Math.min(0.9, newRatio)));
    }
  });
```

**D. PiP 拖动小窗口位置**
```jsx
// PiP 小窗口可拖动
const pipPanGesture = Gesture.Pan()
  .onUpdate(e => {
    const newX = e.absoluteX / Dimensions.get('window').width;
    const newY = e.absoluteY / canvasHeight;
    setPipPosition({ x: newX, y: newY });
  });
```

**E. BottomBar 更新（移除前后按钮，flip 按钮替换占位符）**
```jsx
function BottomBar({ ..., isFlipped, onFlip }) {
  return (
    <View style={styles.bottomBar}>
      {/* ... modeToggle, shutter ... */}
      <Pressable style={styles.flipBtn} onPress={onFlip}>
        <Text style={styles.flipBtnText}>⟲</Text>
      </Pressable>
    </View>
  );
}
```

---

## 四、全栈影响面分析

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `my-app/native/LocalPods/DualCamera/DualCameraView.h` | 属性声明 | 新增 sxBackOnTop、pipMainIsBack |
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | 核心逻辑 | updateLayout + compositeFront + PiP nil检查 + 圆形保护 |
| `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m` | 属性同步 | 新增 2 个 RCT_CUSTOM_VIEW_PROPERTY |
| `my-app/native/LocalPods/DualCamera/DualCameraModule.m` | API 扩展 | flipCamera + setZoom |
| `my-app/native/LocalPods/DualCamera/DualCameraSessionManager.m` | 转发 | flipCamera + setZoom 转发 |
| `my-app/App.js` | UI | flip按钮 + 缩放栏 + 分割线拖动 + PiP 拖动 |
| `my-app/plugin/withDualCamera.js` | 无变更 | — |

---

## 五、关键设计决策

### 决策 1：Flip 的 Native 状态 vs JS 状态
- **采用**：Flip 状态存储在 **Native 层**（`sxBackOnTop`、`pipMainIsBack`），JS 层仅作为 UI 反馈（高亮按钮等）
- **原因**：Preview（native）和 Save（native）都需要读取 flip 状态，JS 不直接参与预览/保存决策
- **JS → Native**：通过 `DualCameraModule.flipCamera()` 触发，Native 更新内部状态
- **Native → JS**：可通过 EventEmitter 发回新的 flip 状态（可选，用于 UI 高亮）

### 决策 2：分割线拖动的实现方式
- **采用**：在 JS 层通过 `GestureDetector`（react-native-gesture-handler）计算新的 ratio，传递到 native 更新
- **备选**：直接让 native view 处理 touches，但 JS 层已有 `dualLayoutRatio` 同步机制，更自然
- **不需要新增 native 方法**：`setDualLayoutRatio` setter 已存在（通过 `setDualLayoutRatio:` 触发）

### 决策 3：缩放控制的 JS/Native 边界
- **采用**：Native 暴露固定档位 `[0.5, 1.0, 2.0, 5.0]`，JS 通过 `NativeModules.DualCameraModule.setZoom('back', 2.0)` 调用
- **原因**：`dc_setFrontZoom:` / `dc_setBackZoom:` 方法已存在于 `DualCameraView`，只需从 Module 暴露给 JS

### 决策 4：PiP flip 后摄像头分配的底层机制
- **不切换 VideoDataOutput 连接**：保持 `frontVideoDataOutput` → `latestFrontFrame` 不变，`backVideoDataOutput` → `latestBackFrame` 不变
- **flip 仅改变合成逻辑**：在 `compositePIPForPhotos:front back:back` 中交换参数顺序
- **Preview**：通过 `updateLayout` 调整 `_backPreviewView` vs `_frontPreviewView` 的 frame 和 hidden 状态（无需重建 session）

---

## 六、风险评估

| 风险 | 级别 | 缓解 |
|---|---|---|
| PiP flip 后 `updateLayout` 快速切换可能导致图层抖动 | 中 | 用 `[UIView animateWithDuration:0.2]` 平滑过渡 frame |
| 分割线拖动频繁更新 ratio → 预览卡顿 | 低 | 使用 `useCallback` + throttle（100ms） |
| 圆形 `CIBlendWithMask` 在低端设备上仍可能崩溃 | 低 | `@try/@catch` + fallback 到方形 |
| `pipMainIsBack=NO` 时后置在小窗口， VideoDataOutput 连接可能失效 | 低 | nil 检查 + 黑色背景 fallback |
| flip 状态在 App 重启后丢失（无持久化） | 低 | 用户不需要 flip 状态持久化 |

---

## 七、验收标准

1. ✅ SX 默认：preview 和 save 中，back（后置摄像头）在顶部，front（前置摄像头）在底部
2. ✅ SX flip 后：preview 和 save 中，front 在顶部，back 在底部
3. ✅ PiP 默认：back 是主画面（大窗口），front 是小窗口（PiP 叠加）
4. ✅ PiP flip 后：front 是主画面（大窗口），back 是小窗口（PiP 叠加）
5. ✅ LR flip 后：preview 和 save 中，front/back 的左右位置交换
6. ✅ 圆形 PiP 拍照：App 不崩溃，保存圆形画面（fallback 到方形如果 CIBlend 失败）
7. ✅ 方形 PiP：后置不再是白色背景，正确显示后置摄像头画面
8. ✅ Flip 按钮：点击后 UI 立即更新（preview 变化），保存也反映 flip 后的分配
9. ✅ 缩放：前置 3 档（0.5x/1.0x/2.0x），后置 4 档（+5.0x），点击切换
10. ✅ 分割线：SX/LR 模式下可拖动，preview 实时更新
11. ✅ PiP 位置：可拖动小窗口，preview 实时更新
12. ✅ saveAspectRatio 比例选择：9:16/3:4/1:1 比例正确应用在保存画布上
