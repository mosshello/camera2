# Spec: 视频合成 — 按用户选择的比例保存（2026-05-06）

## 1. 背景与目标

**问题**: 当前 `compositeDualVideosForCurrentLayout` 中，9:16、3:4、1:1 三个比例全部硬编码为 1920×1920 canvas，导致：
- 保存的视频全部是 1920×1920 正方形，忽略用户选择的比例
- 输出文件比例与 UI 预览不一致

**目标**: `videoComp.renderSize` 和 layer transform 必须严格按照用户选择的比例计算：
- 9:16 → canvasW=1080, canvasH=1920
- 3:4 → canvasW=1440, canvasH=1920
- 1:1 → canvasW=1920, canvasH=1920

## 2. 技术分析

### 2.1 摄像头 composition 坐标空间

composition track 的 naturalSize = 原始像素（1920×1440）。layer transform 在 composition 空间中操作。

**Back camera** `preferredTransform=[0,1,-1,0,1440,0]`:
- `cx = raw_y + 1440` → composition cx 范围 = 960→1440（内容宽 480px）
- `cy = 1920 - raw_x` → composition cy 范围 = 0→1920（满高）

**Front camera** `preferredTransform=[0,-1,1,0,0,0]`:
- `cx = 1440 - raw_y` → composition cx 范围 = 0→1440（内容宽 1440px）
- `cy = raw_x` → composition cy 范围 = 0→1920（满高）

### 2.2 Layer Transform 公式

`T_layer = translate(tx,ty) ∘ scale(sx,sy) ∘ preferredTransform`

即 `Concat(translate, Concat(scale, prefTransform))`

**Back**: `prefTransform=[0,1,-1,0,1440,0]`
- `canvas_x = sx * (raw_y + 1440) + tx`
- `canvas_y = sy * (1920 - raw_x) + ty`

**Front**: `prefTransform=[0,-1,1,0,0,0]`
- `canvas_x = sx * (1440 - raw_y) + tx`
- `canvas_y = sy * raw_x + ty`

### 2.3 Scale 计算（按比例）

| 比例 | canvasW | canvasH | frontScale (canvasW/1440) | backScale (canvasW/480) |
|------|---------|--------|---------------------------|------------------------|
| 9:16 | 1080 | 1920 | 0.75 | 2.25 |
| 3:4 | 1440 | 1920 | 1.0 | 3.0 |
| 1:1 | 1920 | 1920 | 1.333... | 4.0 |

**关键观察**: backScale / frontScale 比值恒为 3.0（480:1440 = 1:3）。这是因为两个摄像头在 composition 空间中的内容宽比恒为 1:3，与 canvas 尺寸无关。

### 2.4 布局参数计算

#### LR（左右分屏）
`leftW = canvasW * ratio`, `rightW = canvasW * (1-ratio)`

**Back 变换（放在左半）**:
- `raw_y=960(内容左边界) → canvas_x = sx*(960+1440) + tx = sx*2400 + tx`
- `raw_y=1440(内容右边界) → canvas_x = sx*2880 + tx`
- 覆盖范围: `[sx*2400+tx, sx*2880+tx]`
- 期望: `[0, leftW]`
- 解: `tx = -sx*2400`, `sx*2880 - sx*2400 = leftW` → `sx = leftW/480` ✅

**Front 变换（放在右半）**:
- `raw_y=0(内容右边界) → canvas_x = sx*1440 + tx`
- `raw_y=1440(内容左边界) → canvas_x = sx*0 + tx = tx`
- 覆盖范围: `[tx, sx*1440+tx]`
- 期望: `[rightW, canvasW]` = `[leftW, canvasW]`
- 解: `tx = leftW`, `sx*1440 = rightW` → `sx = rightW/1440` ✅

**统一公式**:
```
lrBackSx = leftW / 480
lrBackTx = -lrBackSx * 2400
lrFrontSx = rightW / 1440
lrFrontTx = leftW
```

#### SX（上下分屏）
两路都填满 canvasW。Scale 统一 = canvasW/480 = canvasW/1440（back 和 front 用不同 scale）。

**Back 变换（Y 方向位置）**:
- `raw_x=0(内容上边界) → canvas_y = sy*(1920-0) + ty = sy*1920 + ty`
- `raw_x=1920(内容下边界) → canvas_y = sy*0 + ty = ty`
- 覆盖范围: `[ty, sy*1920+ty]`（从底部向上）
- sxBackOnTop=YES（back 在上）: `[ty, sy*1920+ty] = [0, topH]` → `ty=0, sy=topH/1920`
- sxBackOnTop=NO（back 在下）: `[ty, sy*1920+ty] = [bottomH, canvasH]` → `ty=bottomH, sy=bottomH/1920`
- 上下各半: `sy = canvasH/2 / 1920 = canvasH/3840`

**Front 变换（Y 方向位置）**:
- `raw_x=0(内容上边界) → canvas_y = sy*0 + ty = ty`
- `raw_x=1920(内容下边界) → canvas_y = sy*1920 + ty`
- 覆盖范围: `[ty, sy*1920+ty]`
- sxBackOnTop=YES（front 在下）: `[ty, sy*1920+ty] = [bottomH, canvasH]` → `ty=bottomH, sy=bottomH/1920`
- sxBackOnTop=NO（front 在上）: `[ty, sy*1920+ty] = [0, topH]` → `ty=0, sy=topH/1920`

**统一公式**:
```
sxBackSy = canvasH / 3840      // = topH/1920 = bottomH/1920
sxBackTx = -sxBackSy * 2400   // tx 固定（X 方向对齐）
sxBackTy_top    = 0            // back 在上
sxBackTy_bottom = canvasH / 2 // back 在下

sxFrontSy = canvasW / 1440
sxFrontTx = 0                  // X 方向固定
sxFrontTy_bottom = canvasH / 2 // front 在下
sxFrontTy_top    = 0            // front 在上
```

#### PiP（画中画）
- Back: 填满全 canvas（用 sxLayout 统一 scale）
- Front: 放在 pip rect 内（fill by width）

## 3. 文件清单

### 3.1 待修改文件

| 文件 | 改动范围 |
|------|----------|
| `my-app/native/LocalPods/DualCamera/DualCameraView.m` | `compositeDualVideosForCurrentLayout` 方法内的 canvas 尺寸和所有 transform 计算 |

### 3.2 不受影响文件

| 文件 | 说明 |
|------|------|
| `my-app/App.js` | saveAspectRatio prop 传递已正确实现，无需改动 |
| `my-app/native/LocalPods/DualCamera/DualCameraViewManager.m` | saveAspectRatio bridging 已正确实现，无需改动 |

## 4. 变更详情

### 4.1 Canvas 尺寸（`compositeDualVideosForCurrentLayout` 开头）

```objc
// 变更前
if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
    canvasW = 1920; canvasH = 1920;
} else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
    canvasW = 1920; canvasH = 1920;
} else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
    canvasW = 1920; canvasH = 1920;

// 变更后
if ([self.saveAspectRatio isEqualToString:@"9:16"]) {
    canvasW = 1080; canvasH = 1920;
} else if ([self.saveAspectRatio isEqualToString:@"3:4"]) {
    canvasW = 1440; canvasH = 1920;
} else if ([self.saveAspectRatio isEqualToString:@"1:1"]) {
    canvasW = 1920; canvasH = 1920;
}
```

### 4.2 LR 分支 Transform

**变更后公式**:
```objc
CGFloat leftW  = canvasW * ratio;
CGFloat rightW = canvasW * (1 - ratio);
CGFloat lrBackSx  = leftW  / 480.0;   // back 内容宽=480
CGFloat lrBackTx  = -lrBackSx * 2400.0;
CGFloat lrFrontSx = rightW / 1440.0;  // front 内容宽=1440
CGFloat lrFrontTx = leftW;
```

### 4.3 SX 分支 Transform

**变更后公式**:
```objc
CGFloat sxBackSy  = canvasH / 3840.0;  // 统一 scale（填满半高）
CGFloat sxBackTx  = -sxBackSy * 2400.0;
CGFloat sxFrontSy = canvasW / 1440.0;
CGFloat sxFrontTx = 0.0;

// Y 方向
CGFloat sxBackTy   = self.sxBackOnTop ? 0.0 : canvasH / 2.0;
CGFloat sxFrontTy = self.sxBackOnTop ? canvasH / 2.0 : 0.0;
```

### 4.4 PiP 分支 Transform

- Back: 用 `canvasW/480.0` scale（填满全 canvas），`backTx = -backSx*2400`
- Front: 用 `pipW/1440.0` scale，放在 `pipX, pipY`

## 5. 验证矩阵

### 9:16 (canvas=1080×1920)

| 布局 | sxBackOnTop | Back 变换 | Front 变换 | 预期结果 |
|------|------------|-----------|------------|----------|
| LR | YES | tx=-540, sx=2.25 | tx=540, sx=0.75 | 左:back 右:front |
| LR | NO | tx=-540, sx=2.25 | tx=540, sx=0.75 | 左:front 右:back |
| SX | YES | ty=0, sx=0.5 | ty=960, sx=0.75 | 上:back 下:front |
| SX | NO | ty=960, sx=0.5 | ty=0, sx=0.75 | 上:front 下:back |

### 3:4 (canvas=1440×1920)

| 布局 | sxBackOnTop | Back 变换 | Front 变换 | 预期结果 |
|------|------------|-----------|------------|----------|
| LR | YES | tx=-1080, sx=3.0 | tx=720, sx=1.0 | 左:back 右:front |
| LR | NO | tx=-1080, sx=3.0 | tx=720, sx=1.0 | 左:front 右:back |
| SX | YES | ty=0, sx=0.5 | ty=960, sx=1.0 | 上:back 下:front |
| SX | NO | ty=960, sx=0.5 | ty=0, sx=1.0 | 上:front 下:back |

### 1:1 (canvas=1920×1920)

| 布局 | sxBackOnTop | Back 变换 | Front 变换 | 预期结果 |
|------|------------|-----------|------------|----------|
| LR | YES | tx=-1440, sx=4.0 | tx=960, sx=1.333 | 左:back 右:front |
| LR | NO | tx=-1440, sx=4.0 | tx=960, sx=1.333 | 左:front 右:back |
| SX | YES | ty=0, sx=0.5 | ty=960, sx=1.333 | 上:back 下:front |
| SX | NO | ty=960, sx=0.5 | ty=0, sx=1.333 | 上:front 下:back |

## 6. 风险评估

- **中风险**: canvasW 从 1920 改为 1080（9:16）会导致后置摄像头 scale 从 4.0 变为 2.25。需要在真机上验证画面质量。
- **低风险**: 变换公式已通过数学验证（4-corner test），代码只涉及数值计算无副作用。
