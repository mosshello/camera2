# 技术契约与架构设计书

## Xcode 可运行性审计（my-app）

| 属性 | 值 |
|---|---|
| spec_id | xcode-runnability-audit-20260429 |
| 日期 | 2026-04-29 |
| 类型 | 构建可运行性审计（Architecture Check） |
| 结论 | 当前不可直接在 Xcode 成功编译运行 |

---

## 背景与审计范围

本次仅做系统级可运行性审计，不编写业务实现代码。审计对象为 Expo + React Native iOS 工程：

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/myapp.xcworkspace`
- `/Users/zhengxi/vibecoding/camera2/my-app/ios/Podfile`
- `/Users/zhengxi/vibecoding/camera2/my-app/native/LocalPods/DualCamera/*.m`
- `/Users/zhengxi/vibecoding/camera2/my-app/*.js`

已执行验证命令（架构检查用）：

- `xcodebuild -list -workspace .../myapp.xcworkspace`（成功，工程结构完整）
- `xcodebuild -workspace .../myapp.xcworkspace -scheme myapp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build`（失败，exit code 65）

关键错误：

- `PerformanceObserver.cpp: error: no member named 'contains' in std::unordered_set`

---

## 根因分析（跨层）

1. `Podfile` 在 `post_install` 中统一设置 `CLANG_CXX_LANGUAGE_STANDARD = c++17`
2. React Native 0.81 的 `React-performancetimeline` 目标中，`PerformanceObserver.cpp` 使用 `unordered_set.contains(...)`，该 API 依赖 C++20
3. 因为标准被全局降级到 C++17，导致 Pods 编译失败，Xcode 无法完成 Debug 构建

这与已有 fmt 兼容补丁存在冲突：此前为规避 Xcode 26.4 + fmt consteval 问题，把标准降为 c++17；但 RN 新代码路径需要 c++20。

---

## 技术契约设计

### 1) 数据模型层（Schema）

本问题不涉及后端数据模型与存储 Schema。  
**契约结论**：无数据模型改动。

受波及文件清单（审计结果）：

- 无

### 2) 后端服务层（API）

本问题不涉及服务端路由、接口协议、鉴权流程。  
**契约结论**：无 API 契约改动。

受波及文件清单（审计结果）：

- 无

### 3) 前端交互层（View）

问题触发点位于 iOS 原生构建链路，直接阻断 RN 前端在 iOS 侧运行；JS 视图代码本身没有语义错误，但无法被承载到可运行容器。  
**契约结论**：View 层需依赖 iOS 构建契约修复后方可恢复运行。

受波及文件清单（功能可运行性影响）：

- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`
- `/Users/zhengxi/vibecoding/camera2/my-app/index.js`

---

## 目标文件清单（供 task-coder 执行）

### 必改文件

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/Podfile`

### 可能新增文件（取决于修复路径）

- `/Users/zhengxi/vibecoding/camera2/my-app/ios/Podfile.properties.json`（若采用按目标开关化配置）
- `/Users/zhengxi/vibecoding/camera2/.ai/specs/xcode-rn81-fmt-compat-fix-20260429.md`（实施型修复 spec，可选）

### 不应修改

- `/Users/zhengxi/vibecoding/camera2/my-app/native/LocalPods/DualCamera/*`（该问题非业务模块逻辑错误）
- `/Users/zhengxi/vibecoding/camera2/my-app/App.js`（无需业务层补丁）

---

## 推荐修复策略（架构级，不含实现）

优先采用“分目标 C++ 标准策略”而非“一刀切全局标准”：

1. 保持 RN 相关 targets 使用 C++20（满足 `unordered_set.contains`）
2. 仅对触发 fmt consteval 问题的目标应用兼容补丁（可通过宏/局部 flags/源码 patch）
3. 重新执行 `pod install` + `xcodebuild` 验证全链路

---

## 交付与移交

该审计已完成，结论与文件清单可直接移交 `task-coder` 执行修复实现。
