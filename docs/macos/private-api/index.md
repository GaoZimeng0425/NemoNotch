---
summary: '私有框架运行时加载区块:dlopen/dlsym/CFBundle/反射 ObjC 三种模式,含 file:line 锚点与跨版本兼容陷阱。'
read_when:
  - '需要调用 MediaRemote、DisplayServices 等私有框架'
  - '遭遇私有符号在 macOS 小版本升级后静默失效'
sources: ['N §4']
last_verified: { nemonotch: 'fe4e9e5' }
---

# private-api — 私有框架加载

macOS 私有框架无公开头文件,必须在运行时动态加载符号。本区块覆盖 NemoNotch 实际使用的三种模式,保留 `file:line` 精确锚点。

## 文章列表

- [dlopen-dlsym-loading.md](./dlopen-dlsym-loading.md) — 单符号 `dlopen`+`dlsym`(DisplayServices)、多符号 `CFBundle`(MediaRemote 6 函数)、反射 ObjC 类(MRNowPlayingController macOS 15.4+);含 Pitfalls × 6 与落地 checklist。
