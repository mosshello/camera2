# PiP WYSIWYG 拍照综合修复 — 2026-04-30

## 问题描述
1. **画中画位置偏移**：拍摄时 PiP 在右下角，保存的照片 PiP 在右上角
2. **圆形画中画变成方形**：预览是圆形 PiP，保存的照片变成方形

## 根因分析（最终结论）

### 根因 1：镜像变换顺序错误
- `compositePIPFront` / `compositePIPForPhotos` 的镜像变换顺序为：
  `T(cx,cy) * S(-1,1) * T(cx,0)`（先放再镜像）
- 这导致镜像后图像原点偏移，合成结果 extent origin 非零（如 x=215）
- `createCGImage:fromRect:ciImage.extent` 从偏移 origin 开始截取，导致画布整体右移

### 根因 2：圆形 PiP 未应用 mask
- `compositePIPFront` / `compositePIPForPhotos` 未对 `pip_circle` 布局应用圆形裁剪

## 修复内容

### 修复 1：正确的镜像变换顺序
```objc
// 正确顺序：先镜像（原点不变），再平移到 pipRect.origin
CGFloat s = pipRect.size.width;
CGAffineTransform t = CGAffineTransformMakeTranslation(pipRect.origin.x + s, pipRect.origin.y);
t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(-1, 1));
t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(-s, 0));
CIImage *frontPlaced = [frontCropped imageByApplyingTransform:t];
```
效果：镜像后图像原点自然回到 `(pipRect.origin.x, pipRect.origin.y)`，
`imageByCompositingOverImage:backFull` 后 extent origin 为 `(0,0)`。

### 修复 2：圆形 mask
- 使用 `CIRadialGradient` 生成 alpha 渐变（1→0）的圆形 mask
- 通过 `CIBlendWithMask` + 白色画布将前置画面裁剪为圆形
- 仅在 `pip_circle` 布局时应用

### 修复 3：安全网平移
- 在 `compositePIPFront` / `compositePIPForPhotos` 返回前检查 extent origin，非零则平移
- `saveCIImageAsJPEG` 保留平移兜底

## 修改文件
- `my-app/native/LocalPods/DualCamera/DualCameraView.m`
- `my-app/ios/LocalPods/DualCamera/DualCameraView.m`

## 方法变更
- `compositePIPFront`: 新增 `isCircle:(BOOL)` 参数；修复镜像变换顺序；添加圆形 mask 逻辑；添加 extent origin 安全网平移
- `compositePIPForPhotos`: 同上
- 新增 helper: `circleMaskAtCenter:radius:extentSize:`
- 新增 helper: `whiteCanvasSize:`
- `compositeDualPhotosForCurrentLayout` PiP 分支: 传入 `isCircle` 参数
- `compositeFront:toCanvas:` PiP 分支: 传入 `isCircle` 参数

## 状态
- [FIXED] 镜像变换顺序 → PiP 位置正确
- [FIXED] 圆形 mask → 圆形 PiP 保存为圆形
- [FIXED] extent origin 安全网 → 双重保障
