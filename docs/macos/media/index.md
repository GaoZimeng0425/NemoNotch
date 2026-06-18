---
summary: '媒体子系统索引：NowPlayingCLI daemon、MediaRemote 私有 API、ScriptingBridge 权威态、play/pause reconcile'
last_verified: { nemonotch: 'fe4e9e5' }
---

# Media 子系统

macOS 媒体栈由三层信息源构成，通过 optimistic UI + authoritative guard 模式融合：NowPlayingCLI perl daemon（元数据）、MediaRemote 私有 framework（控制命令）、ScriptingBridge（Music/Spotify 权威播放态与 seek）。

| 文档 | 覆盖内容 |
|---|---|
| [mediaremote-and-nowplaying.md](mediaremote-and-nowplaying.md) | MediaRemote 私有 API、NowPlayingCLI daemon + dylib 提取、play/pause reconcile 流程（optimistic UI + guard 模式） |
| [scriptingbridge-reconcile.md](scriptingbridge-reconcile.md) | ScriptingBridge 已知播放器权威态读取、AppleScript `setPlayerPosition` seek（Music/Spotify）、SB vs MediaRemote 决策规则、AE keyword / 协议生成 |

相关区块：[../private-api/](../private-api/)（MediaRemote dlopen）· [../permissions/](../permissions/)（Automation TCC）
