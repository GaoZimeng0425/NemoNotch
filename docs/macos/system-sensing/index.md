---
summary: '系统采样索引 — CPU / 内存 / 进程 / 网络 / 磁盘 / 亮度 / 电量'
sources: ['NemoNotch §8']
last_verified: { nemonotch: 'fe4e9e5' }
---

# System Sensing — 系统采样

macOS 系统指标采样分布在多个框架（Mach、IOKit、BSD、DisplayServices 私有 API），各有不同的内存管理和线程规则。本区块按资源类型拆分，每篇提炼可复用 Swift 骨架、`file:line` 锚点和主要 pitfall。

## 文章列表

| 文件 | 覆盖内容 |
|---|---|
| [cpu-memory-disk.md](cpu-memory-disk.md) | CPU per-core ticks（`host_processor_info`）、内存 VM 统计（`host_statistics64`）、进程枚举（`libproc`）、网络计数器（`getifaddrs`）、磁盘容量（`URLResourceValues`） |
| [brightness-battery.md](brightness-battery.md) | 屏幕亮度自适应轮询（`DisplayServicesGetBrightness` 私有 API，dlopen 模式见 `../private-api/`）、电量快照（IOPS Create/Get 规则）、电量推送（IOPS RunLoop source + 主线程 hop） |
