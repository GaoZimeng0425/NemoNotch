# OpenClaw 集成设计

## 概述

在 NemoNotch 刘海中新增 OpenClaw Tab，实时监控 OpenClaw Gateway 上 Agent 的执行状态。

## 数据层

### 连接方式

- WebSocket 连接 `ws://localhost:18789/gateway-ws`
- Token 从 `~/.openclaw/openclaw.json` 的 `gateway.auth.token` 自动读取
- 文件不存在则判定为未安装

### 状态模型

```swift
enum AgentState: String {
    case idle, working, speaking, toolCalling, error
}

struct AgentInfo {
    let id: String
    var name: String
    var state: AgentState
    var currentTool: String?
    var lastMessage: String?
    var workspace: String?
    var lastEventTime: Date
}
```

### OpenClawService（@Observable）

- 管理 WebSocket 生命周期（连接/断线重连/心跳）
- 维护 `agents: [String: AgentInfo]` 字典
- 跟踪 `gatewayOnline: Bool` 和 `activeAgent: AgentInfo?`
- 监听 4 种 Gateway 事件：`agent`、`presence`、`health`、`heartbeat`
- 状态归一化（working/busy→working, run/exec→executing 等）
- 5 分钟 TTL 自动 idle（无更新的 Agent 自动回到空闲状态）

## UI 层

### OpenClawTab 三态

1. **离线态** — Gateway 未运行或未安装，提示安装/启动命令
2. **空闲态** — Gateway 在线，无活跃 Agent，绿色在线指示灯
3. **活跃态** — Agent 列表，每行显示：状态图标 + 名称 + 当前工具 + 消息摘要 + 时间

### Tab 配置

- case: `openclaw`
- icon: SF Symbol（待选）
- title: "OpenClaw"

### CompactBadge

有 Agent 工作时在刘海紧凑区域显示图标 + 脉冲动画。

## 文件结构

### 新增

- `Models/OpenClawState.swift` — AgentState, AgentInfo
- `Services/OpenClawService.swift` — WebSocket 连接、事件处理、TTL
- `Tabs/OpenClawTab.swift` — Tab 视图

### 改动

- `Models/Tab.swift` — 加 `.openclaw` case
- `Notch/NotchView.swift` — switch 加 `.openclaw` 分支
- `NemoNotchApp.swift` — 创建并注入 OpenClawService

## 参考

- OpenClaw Gateway: `ws://localhost:18789`
- OpenClaw Office (WebSocket 集成参考): https://github.com/WW-AI-Lab/openclaw-office
- Star Office UI (状态映射/TTL 参考): https://github.com/ringhyacinth/Star-Office-UI
