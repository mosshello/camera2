# 技术契约与架构设计书

## iOS 本地网络被拒绝：Metro `/status` 请求失败（NSURLErrorDomain -1009）

| 属性 | 值 |
|---|---|
| spec_id | ios-local-network-denied-metro-status-20260429 |
| 日期 | 2026-04-29 |
| 优先级 | P1（影响开发态联机调试） |
| 现象 | `http://<LAN_IP>:8081/status` 请求失败，`Denied over Wi-Fi interface` |

---

## 问题定义

日志显示：

- `Error Domain=NSURLErrorDomain Code=-1009`
- `_NSURLErrorNWPathKey=unsatisfied (Denied over Wi-Fi interface)`
- `NSErrorFailingURLStringKey=http://192.168.5.49:8081/status`

这表明 App 在访问局域网 Metro 服务时被系统网络策略拒绝，属于 **iOS 本地网络访问链路问题**，不是 JS 业务层异常。

---

## 根因分析

结合当前工程状态（已具备 Debug 离线 bundle fallback）：

1. 设备侧 Local Network 权限可能被关闭/拒绝（iOS 设置层）
2. `Info.plist` 目前仅配置了 `NSAllowsLocalNetworking=true`，缺少显式 `NSLocalNetworkUsageDescription`
3. App 仍会尝试访问 Metro `/status`（开发态健康检查），当 Wi-Fi 路径被拒绝时出现该错误

注：该错误在“离线 fallback 模式”下可不阻断启动，但会影响联机调试能力。

---

## 技术契约设计

### 数据模型层（Schema）

无改动。

受影响文件：

- 无

### 后端服务层（API）

无服务端 API 变更；仅本地开发网络连通性策略调整。

受影响文件：

- 无

### 前端交互层（View）

View 业务代码无改动；仅影响 Debug 场景下是否能连到 Metro。

受影响运行路径：

- `/Users/zhengxi/vibecoding/camera2/my-app/index.js`
- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`

---

## 一次性修复方案（建议）

### 方案目标

同时保障两条链路：

1. **联机调试链路**：允许访问 Metro（LAN）
2. **离线链路**：Metro 被拒绝时仍可通过 `main.jsbundle` 启动

### 实施契约

1. 在 `Info.plist` 新增 `NSLocalNetworkUsageDescription`
2. 在文档中增加“Local Network 权限与同网段检查”操作指引
3. 保持已落地的 `DEBUG_EMBED_BUNDLE` + `AppDelegate fallback` 不变

---

## 目标文件清单（绝对路径）

### 必改

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/Info.plist`
- `/Users/zhengxi/vibecoding/camera2/README.md`

### 参考（无需本次改动）

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp/AppDelegate.swift`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/.xcode.env.updates`

---

## 验证计划

1. iPhone 设置中开启该 App 的 Local Network 权限
2. 手机与开发机同一 Wi-Fi 网段
3. 开启 Metro 后验证 `http://<dev-ip>:8081/status` 可达（返回 `packager-status:running`）
4. 关闭 Metro 验证离线 fallback（`DEBUG_EMBED_BUNDLE=1`）仍可启动

---

## Handoff（派发给 task-coder）

请 `task-coder` 按本 spec 执行：

1. `Info.plist` 增加 `NSLocalNetworkUsageDescription`
2. `README` 增补“Local Network 权限排障步骤”
3. 跑联机/离线两条验证路径并回填结果
