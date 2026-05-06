# 技术契约与架构设计书

## 方案 B 一次性修复包（One-Shot Fix）

| 属性 | 值 |
|---|---|
| spec_id | ios-no-script-url-planb-one-shot-fix-20260429 |
| 日期 | 2026-04-29 |
| 基于 | ios-no-script-url-planb-implementation-20260429 |
| 目标 | 一次提交完成“真机 Debug 离线可启动” |

---

## 一次性修复范围

本次 one-shot 要求一个提交完成以下四件事：

1. Debug 可通过开关内嵌 `main.jsbundle`
2. AppDelegate Debug 路径具备 `main.jsbundle` fallback
3. 保持 Metro 开发路径默认不变
4. 提供可回滚、可验证的运行指引

---

## 三层契约（按 system-architect 模板）

### 数据模型层（Schema）

无改动。  
受波及文件：无。

### 后端服务层（API）

无改动。  
受波及文件：无。

### 前端交互层（View）

不改业务页面逻辑，仅调整 JS bundle 解析与加载策略。  
受波及运行路径：

- `/Users/zhengxi/vibecoding/camera2/my-app/index.js`
- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`

---

## 目标文件清单（绝对路径）

### 必改

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/AppDelegate.swift`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env`
- `/Users/zhengxi/vibecoding/camera2/my-app/README.md`

### 新建

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.updates`

### 可选

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.local`（本机默认开关）

### 明确不改

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcodeproj/project.pbxproj`

---

## 一次性实施步骤（供 task-coder）

1. 在 `.xcode.env` 增加默认关闭开关：`DEBUG_EMBED_BUNDLE=0`
2. 新建 `.xcode.env.updates`：
   - 当 `DEBUG_EMBED_BUNDLE=1` 时，执行 `unset SKIP_BUNDLING`
   - 输出清晰日志（是否启用 embed）
3. 修改 `AppDelegate.swift`：
   - Debug: 先尝试 Metro URL
   - Debug: 若 URL 为 `nil`，尝试 `main.jsbundle`
   - Release: 保持现状
4. 在 `README.md` 增加两套启动命令：
   - 在线开发（Metro）
   - 离线调试（`DEBUG_EMBED_BUNDLE=1`）
5. 执行验证矩阵并记录结果

---

## 验收标准（必须全部满足）

1. Debug + Metro 开启 + `DEBUG_EMBED_BUNDLE=0`：正常热更新
2. Debug + Metro 关闭 + `DEBUG_EMBED_BUNDLE=0`：复现原错误（用于确认分支正确）
3. Debug + Metro 关闭 + `DEBUG_EMBED_BUNDLE=1`：App 可启动进入首页
4. Release 构建与启动行为不变
5. 改动不引入 `xcodebuild` 新报错

---

## 回滚策略

最小回滚只需：

1. 设回 `DEBUG_EMBED_BUNDLE=0`
2. 保留 AppDelegate fallback（不影响在线开发）

完全回滚：

1. 删除 `.xcode.env.updates`
2. 还原 `AppDelegate.swift` fallback 逻辑

---

## Handoff

该 one-shot spec 已可直接派发 `task-coder` 执行。执行完成后应将：

- `ios-no-script-url-20260429` 条目状态改为 `[FIXED]`
- `ios-no-script-url-planb-implementation-20260429` 条目状态改为 `[FIXED]`
