---
summary: 'Logging 区块导航:应用层 CocoaLumberjack、底层 OSLog。'
last_verified: { nemonotch: 'fe4e9e5' }
---

# Logging 区块

**主线:CocoaLumberjack。** NemoNotch 用 `LogService`(DDOSLogger + DDFileLogger)在任意线程/actor 中一行打日志;日志同时落入 `~/.NemoNotch/logs/`(日轮转,7 份保留)和 Console.app。

**底层:OSLog。** CocoaLumberjack 的 `DDOSLogger` 把每条日志桥接到系统 Unified Logging(`os_log`),这是 Console.app 能过滤、`log stream` 能抓到的原因。纯 OSLog 在无需文件落地的场景(daemon、CLI)也够用。

| 文档 | 何时读 |
|------|-------|
| [cocoalumberjack-logservice.md](./cocoalumberjack-logservice.md) | 添加新服务、在 actor 边界打日志、调 log 级别 |
| [oslog-foundation.md](./oslog-foundation.md) | 用 Console.app/`log stream` 调试、理解底层 privacy 机制、评估是否需要文件 logger |

> **不用 swift-log。** 本知识库以 CocoaLumberjack(应用层)/ OSLog(底层)为准,见 [oslog-foundation.md §Pitfalls](./oslog-foundation.md)。
