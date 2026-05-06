# 技术契约与架构设计书

## 方案 B 实施版：Debug 离线启动兜底（No script URL provided）

| 属性 | 值 |
|---|---|
| spec_id | ios-no-script-url-planb-implementation-20260429 |
| 日期 | 2026-04-29 |
| 关联缺陷 | ios-no-script-url-20260429 |
| 目标 | 在 Metro 不可达时，真机 Debug 仍可启动 |

---

## 设计目标

在不破坏现有 Expo dev workflow 的前提下，为 iOS Debug 增加“可控内嵌 bundle + 原生 fallback”双保险：

1. **默认行为保持不变**：Debug 继续走 Metro（开发体验不变）
2. **按开关启用离线兜底**：仅在设置开关时为 Debug 生成 `main.jsbundle`
3. **原生端兜底加载**：Metro URL 为空时，回退到 `Bundle.main/main.jsbundle`

---

## 现状约束

### 已有可复用机制

`Bundle React Native code and images` 脚本已包含：

- 对 `.xcode.env` / `.xcode.env.local` 的 source
- 对 `.xcode.env.updates` 的 source（在 `SKIP_BUNDLING=1` 之后）

这允许我们通过新增 `.xcode.env.updates` 在不改脚本主体的情况下覆盖 `SKIP_BUNDLING`。

### 当前缺口

- Debug 固定 `SKIP_BUNDLING=1`
- `AppDelegate.swift` Debug 分支无 `main.jsbundle` fallback

---

## 技术契约

### 数据模型层（Schema）

无任何数据模型改动。

受影响文件：

- 无

### 后端服务层（API）

无任何 API 改动。

受影响文件：

- 无

### 前端交互层（View）

JS 业务逻辑不改；仅改变 JS 载入来源策略（远程 Metro 与本地 bundle 的选择顺序）。

受影响运行路径：

- `/Users/zhengxi/vibecoding/camera2/my-app/index.js`
- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`

---

## 方案 B 的实现契约（供 task-coder 执行）

### 契约 1：构建开关

新增环境开关：

- `DEBUG_EMBED_BUNDLE=1`：开启 Debug 内嵌 bundle
- 未设置时：保持当前行为（Debug 依赖 Metro）

### 契约 2：打包脚本覆盖逻辑

在 `.xcode.env.updates` 中实现：

- 当 `DEBUG_EMBED_BUNDLE=1` 时执行 `unset SKIP_BUNDLING`
- 可选设置 `BUNDLE_COMMAND=export:embed`（若未继承）

### 契约 3：AppDelegate 兜底逻辑

`AppDelegate.swift` 的 `bundleURL()` 契约调整为：

1. Debug 先尝试 `RCTBundleURLProvider`
2. 若返回 `nil`，再尝试 `Bundle.main.url(forResource: "main", withExtension: "jsbundle")`
3. Release 保持 `main.jsbundle` 加载不变

### 契约 4：可观测性

在 fallback 路径增加最小日志（如 `NSLog`），便于区分：

- 使用 Metro URL 启动
- 使用本地 `main.jsbundle` 启动

---

## 待修改文件清单（绝对路径）

### 必改

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/AppDelegate.swift`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env`

### 新建

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.updates`

### 可选改动（仅当需要团队默认开启）

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.local`（本地机开关，不建议入库）
- `/Users/zhengxi/vibecoding/camera2/my-app/README.md`（补充“离线 Debug 启动”说明）

### 不应改动

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcodeproj/project.pbxproj`（现阶段可不改）
- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`（业务层无关）

---

## 验证矩阵

1. **Debug + Metro 开启 + `DEBUG_EMBED_BUNDLE` 未开启**
   - 预期：走 Metro，热更新正常
2. **Debug + Metro 关闭 + `DEBUG_EMBED_BUNDLE` 未开启**
   - 预期：仍会报错（用于验证开关确实生效）
3. **Debug + Metro 关闭 + `DEBUG_EMBED_BUNDLE=1`**
   - 预期：走 `main.jsbundle`，可进入首页
4. **Release 构建**
   - 预期：行为不变，走 `main.jsbundle`

---

## 风险与回滚

### 风险

- Debug 开启内嵌 bundle 时构建时间增加
- 若本地 bundle 过旧，可能与预期 JS 版本不一致

### 回滚

- 移除 `DEBUG_EMBED_BUNDLE=1`（或删除 `.xcode.env.updates` 相关逻辑）即可恢复当前行为
- fallback 代码保留不影响 Metro 正常路径

---

## Handoff（派发给 task-coder）

请 `task-coder` 按本 spec 仅修改清单内文件，完成以下最小闭环：

1. 新增 `.xcode.env.updates` 开关覆盖 `SKIP_BUNDLING`
2. 在 `AppDelegate.swift` 实现 Debug fallback 到 `main.jsbundle`
3. 跑四象限验证矩阵并回填结果
