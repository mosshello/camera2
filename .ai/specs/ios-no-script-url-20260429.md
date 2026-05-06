# 技术契约与架构设计书

## iOS 启动报错：No script URL provided

| 属性 | 值 |
|---|---|
| spec_id | ios-no-script-url-20260429 |
| 日期 | 2026-04-29 |
| 优先级 | P0（阻断 App 启动） |
| 当前状态 | 待修复（架构设计已完成） |

---

## 问题现象

手机打开 App 后出现红屏：

- `No script URL provided`
- `unsanitizedScriptURLString = (null)`

这表示 React Native Bridge 在启动时没有拿到 JS 入口 URL，属于 **启动链路配置问题**，非业务页面逻辑问题。

---

## 根因分析（跨层）

### 1) iOS 原生启动层

`AppDelegate` 中 `ReactNativeDelegate.bundleURL()` 的 Debug 分支依赖：

- `RCTBundleURLProvider.sharedSettings().jsBundleURL(...)`

该路径要求开发服务器（Metro）可达且 URL 可解析。若用户在手机上直接点开已安装 Debug App（而非通过 `expo run:ios` / dev launcher 流程），常见场景是 Metro 未运行或网络不可达，导致返回 `nil`。

### 2) iOS 打包脚本层

`project.pbxproj` 的 `Bundle React Native code and images` 脚本中，Debug 明确执行：

- `SKIP_BUNDLING=1`

即 Debug 包默认不内嵌 `main.jsbundle`。这与“离线直接打开”场景天然冲突。

### 3) JS 运行层

JS 业务代码不是根因；问题发生在 JS 执行前（Bridge 初始化阶段），因此前端页面层面无法自行恢复。

---

## 技术契约设计

### 数据模型层（Schema）

本问题不涉及数据库结构、持久化 Schema 或 TS 数据模型。  
**改动意图**：无。

受波及文件清单：

- 无

### 后端服务层（API）

本问题不涉及服务端接口、路由、鉴权。  
**改动意图**：无。

受波及文件清单：

- 无

### 前端交互层（View）

View 代码非根因，但运行依赖 iOS 启动链路提供可用 JS bundle。  
**改动意图**：保证“调试包 + 真机启动”时 JS 源可达，或提供内嵌 bundle 兜底。

受波及文件清单（运行受影响）：

- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`
- `/Users/zhengxi/vibecoding/camera2/my-app/index.js`

---

## 修复方案（架构级）

### 方案 A（推荐，开发态规范化）

目标：维持 Debug 不内嵌 bundle，但确保每次真机启动都由 dev workflow 托管。

契约：

1. 统一要求使用 `npx expo run:ios --device` 或 `npx expo start --dev-client` + Dev Client 启动
2. 启动前必须存在可访问的 Metro（同网段、端口可达）
3. 不从手机桌面“离线直开”Debug 包

优点：符合 Expo/RN 开发模型，热更新体验最佳。  
风险：对本地网络环境依赖高。

### 方案 B（增强兜底，支持离线打开）

目标：Debug 或特定构建模式允许内嵌 `main.jsbundle`，降低对 Metro 的实时依赖。

契约：

1. 调整 `Bundle React Native code and images` 脚本，使 Debug 不再固定 `SKIP_BUNDLING=1`（改为条件开关）
2. 在 `AppDelegate.swift` 中为 Debug 增加 fallback（优先 Metro，失败时回退 `Bundle.main` 中的 `main.jsbundle`）
3. 增加构建配置约定（例如 `DEBUG_EMBED_BUNDLE=1`）避免影响日常热更新开发

优点：手机离线启动更稳定。  
风险：Debug 构建时间上升，且需维护双路径（远程 bundle / 本地 bundle）。

---

## 待修改文件清单（绝对路径）

### 必改（若执行方案 A 的最小落地）

- `/Users/zhengxi/vibecoding/camera2/my-app/README.md`（新增真机调试启动规范）

### 必改（若执行方案 B 的代码化兜底）

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/AppDelegate.swift`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcodeproj/project.pbxproj`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env`（如需引入开关）
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.local`（本地覆盖开关，可选）

### 可选补充

- `/Users/zhengxi/vibecoding/camera2/my-app/package.json`（增加标准化启动命令脚本）

---

## 验证计划

1. Debug + Metro 开启：真机启动应正常加载 JS（无 `No script URL provided`）
2. Debug + Metro 关闭：
   - 方案 A：应在文档中明确为不支持场景
   - 方案 B：应回退到内嵌 `main.jsbundle` 并可进入首页
3. Release 构建：确认仍从 `main.jsbundle` 启动，不回归

---

## 移交说明（Handoff to task-coder）

请 `task-coder` 在上述两种方案中选定一个执行：

- 若追求开发效率与一致性，执行方案 A（文档与流程约束）
- 若追求手机离线可启动能力，执行方案 B（AppDelegate + Xcode 脚本改造）
