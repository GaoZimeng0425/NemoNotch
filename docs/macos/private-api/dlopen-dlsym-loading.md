---
summary: '用 dlopen/dlsym/CFBundle 加载 macOS 私有框架符号的三种模式:单符号 dlsym、多符号 CFBundle、反射 ObjC 类;保留 NemoNotch file:line 锚点。'
read_when:
  - '需要调用 MediaRemote / DisplayServices 等私有框架的 C 函数'
  - '面对 macOS 版本新 ObjC 类替换旧 C 回调的兼容性问题'
  - '私有符号在新 macOS 版本静默失效排查'
sources: ['N §4']
last_verified: { nemonotch: 'fe4e9e5' }
---

# dlopen / dlsym 私有框架加载

## TL;DR

macOS 私有框架无公开头文件,必须在运行时动态加载。根据所需符号数量和符号类型选择三种模式:

| 场景 | 模式 | NemoNotch 实例 |
|------|------|----------------|
| 只需 **1 个** C 函数 | `dlopen` + `dlsym` | `DisplayServicesGetBrightness` |
| 需要 **多个** C 函数 | `dlopen` + `CFBundleCreate` + `CFBundleGetFunctionPointerForName` | `MRMediaRemote*` 6 个函数 |
| macOS 版本新增 **ObjC 类** 替换旧 C 回调 | `NSClassFromString` + `class_createInstance` + KVC 轮询 | `MRNowPlayingController`(macOS 15.4+) |

所有三种模式共享同一个跨切原则:符号缺失返回 `nil` / `false` + 降级(不崩溃);记录 `dlerror()` / 具体 nil 类名;声明 OS 版本适用范围。

---

## 可复用模式

### 模式 1 · 单符号 `dlopen` + `dlsym`

最轻量的路径。只需一个 C 函数时,直接打开私有框架二进制并通过符号名解析。

```swift
// 进程级单例 handle — 只 dlopen 一次,永不 dlclose
private var displayServicesHandle: UnsafeMutableRawPointer?

private func getBrightness() -> Float? {
    if displayServicesHandle == nil {
        displayServicesHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY | RTLD_NOW
        )
    }
    guard let handle = displayServicesHandle else {
        LogService.warn("Failed to load DisplayServices framework", category: "HUD")
        return nil
    }

    typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
        LogService.warn("DisplayServicesGetBrightness symbol not found", category: "HUD")
        return nil
    }
    let funcPtr = unsafeBitCast(sym, to: GetBrightnessFunc.self)

    var brightness: Float = 0
    let result = funcPtr(CGMainDisplayID(), &brightness)
    guard result == 0 else { return nil }
    return brightness
}
```

### 模式 2 · 多符号 `dlopen` + `CFBundleCreate` + `CFBundleGetFunctionPointerForName`

需要从同一个私有框架绑定多个 C 函数时,`CFBundle` 提供更整洁的循环绑定方式——声明 `@convention(c)` typealias,用同一个 `loadFn` 工具函数批量解析。

```swift
private init() {
    let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL)
    if handle == nil {
        LogService.error("dlopen MediaRemote failed: \(String(cString: dlerror()))", category: "MediaRemote")
    }

    let bundleURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
    let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL)

    func loadFn<T>(_ name: String, as _: T.Type) -> T? {
        guard let bundle, let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
            return nil
        }
        return unsafeBitCast(ptr, to: T.self)
    }

    self.getNowPlayingInfoFn  = loadFn("MRMediaRemoteGetNowPlayingInfo",           as: GetNowPlayingInfoFn.self)
    self.sendCommandFn        = loadFn("MRMediaRemoteSendCommand",                 as: SendCommandFn.self)
    // … 4 more: GetNowPlayingApplicationPID, RegisterForNowPlayingNotifications,
    //           SetCanBeNowPlayingApplication, SetElapsedTime
}
```

**关键点**:`dlopen` 传的是 **框架内部的二进制路径**(`/…/MediaRemote.framework/MediaRemote`),`CFBundleCreate` 传的是**框架目录路径**(`/…/MediaRemote.framework`)。两个路径不能互换。

### 模式 3 · 反射 ObjC 类(`NSClassFromString` + KVC 轮询)

私有框架在新 macOS 版本引入新 ObjC 类替换旧 C 回调时使用。macOS 15.4 起 `MRNowPlayingController` 取代了旧的 `MRMediaRemoteGetNowPlayingInfo` 回调路径——旧路径在 15.4+ 返回空字典。

```swift
func queryViaNewControllerAPI(completion: @escaping ([String: Any]?) -> Void) {
    guard let destClass  = NSClassFromString("MRDestination") as? NSObject.Type,
          let configClass = NSClassFromString("MRNowPlayingControllerConfiguration") as? NSObject.Type,
          let controllerClass = NSClassFromString("MRNowPlayingController") as? NSObject.Type else {
        completion(nil); return
    }
    // … 构造 userSelectedDestination + initWithDestination: configuration …
    guard let controllerInstance = class_createInstance(controllerClass, 0) as? NSObject else {
        completion(nil); return
    }
    let initCtlSel = NSSelectorFromString("initWithConfiguration:")
    guard let ctl = controllerInstance.perform(initCtlSel, with: configObj)?.takeUnretainedValue() as? NSObject else {
        completion(nil); return
    }
    ctl.perform(NSSelectorFromString("beginLoadingUpdates"))

    // 最多轮询 25 × 100ms = 2.5s 等待 response.playbackQueue.contentItems[*].metadata
    let timer = DispatchSource.makeTimerSource(queue: .main)
    var pollCount = 0; let maxPolls = 25
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
        pollCount += 1
        let response = ctl.value(forKey: "response") as? NSObject
        let info = MediaRemote.buildInfoDict(from: response)
        if (info != nil && !(info?.isEmpty ?? true)) || pollCount >= maxPolls {
            timer.cancel(); self?.pollTimer = nil
            ctl.perform(NSSelectorFromString("endLoadingUpdates"))
            completion(info)
        }
    }
    pollTimer = timer; timer.resume()
}
```

**OS 版本判断**:用 `NSClassFromString` 返回 `nil` 而非 `if #available` 做运行时门控——Apple 在点版本中前后移植过 ObjC 反射类,静态版本检查不可靠。

---

## 锚点(file:line)

| 模式 | 文件:行 | 函数 |
|------|---------|------|
| 模式 1 — DisplayServices 单符号 | `NemoNotch/Services/HUDService.swift:161-184` | `getBrightness()` |
| 模式 2 — MediaRemote 多符号绑定 | `NemoNotch/Services/MediaRemote.swift:38-61` | `init()` |
| 模式 2 — `@convention(c)` typealias 声明 | `NemoNotch/Services/MediaRemote.swift:22-27` | 顶层 typealias |
| 模式 3 — ObjC 反射 + KVC 轮询 | `NemoNotch/Services/MediaRemote.swift:180-238` | `queryViaNewControllerAPI(completion:)` |

绑定的 MediaRemote 符号清单(模式 2):

- `MRMediaRemoteGetNowPlayingInfo` — 异步拉取当前 Now Playing 信息字典(旧路径,15.4+ 空字典)
- `MRMediaRemoteGetNowPlayingApplicationPID` — 前台媒体 app 的 PID(用于 bundle ID 查找)
- `MRMediaRemoteSendCommand` — 发送播放/暂停/跳进/寻址命令(整数 Command ID)
- `MRMediaRemoteRegisterForNowPlayingNotifications` — 订阅系统 Now Playing 变更广播
- `MRMediaRemoteSetCanBeNowPlayingApplication` — 阻止本进程被视作 Now Playing 来源
- `MRMediaRemoteSetElapsedTime` — 设置 elapsed-time hint(Music/Spotify seek 辅助)

---

## Pitfalls

### P1 · `dlsym` 静默返回 `nil`

`dlsym` 在符号缺失或跨 macOS 版本改名时静默返回 `nil`——**不抛异常,不打印错误**。  
必须 nil-check 每个 `dlsym` 结果并记录日志;不要 force-unwrap。  
来源:`HUDService.swift:242` 的 `LogService.warn` 模式。

### P2 · `dlopen` handle 必须缓存,永不 `dlclose`

`dlopen` 之后永远不要调用 `dlclose`。dylib 在进程生命周期内保持映射;重复 `dlopen` 同一路径会返回相同 handle 并递增引用计数——但 `dlclose` 会递减计数,计数归零后 dylib 被卸载,已绑定的函数指针变成悬空指针。把 handle 存为进程级单例(如 `displayServicesHandle`)并复用。  
来源:`HUDService.swift:233-235` 的 handle 缓存模式。

### P3 · `dlopen` 路径:二进制路径 vs 框架目录路径不能混用

模式 2 中两个参数的路径语义不同:
- `dlopen` 必须传**框架内部的 Mach-O 二进制**:`/…/MediaRemote.framework/MediaRemote`(无后缀)
- `CFBundleCreate` 必须传**`.framework` 目录**:`/…/MediaRemote.framework`

将 `.framework` 目录传给 `dlopen` 在某些 macOS 版本静默失败。  
来源:`MediaRemote.swift:38-40` 的双路径写法与 §4.2 Gotcha。

### P4 · `@convention(c)` typealias 签名必须与 C 声明完全一致

`unsafeBitCast` 不验证签名——签名错误在 `unsafeBitCast` 时不报错,在**第一次调用**时以 `EXC_BAD_ACCESS` 崩溃,栈帧难以溯源。  
声明 typealias 时对照私有框架头文件或逆向工程结果逐字匹配参数类型、指针所有权、block vs closure 语义。  
来源:§4.2 Gotcha 第二条。

### P5 · 模式 3 轮询上限不可省略

`MRNowPlayingController` 在无媒体播放时**永远不回调**。  
必须设置硬性上限(NemoNotch 取 `25 × 100ms = 2.5s`)并在到达上限时以"无 Now Playing"降级返回;否则定时器永不取消,内存泄漏且 UI 卡住。  
来源:`MediaRemote.swift:230` 的 `maxPolls` 常量与 §4.3 Gotcha。

### P6 · 跨 macOS 小版本私有符号可能消失

Apple 在任何 minor release 都可能重命名、迁移或删除私有符号,无任何公告。  
每次 macOS 升级后首要验证:
1. `dlsym` 返回值非 nil
2. `NSClassFromString` 返回值非 nil
3. 功能路径实际可用

记录版本适用范围(`macOS 15.4+` for 模式 3;模式 1/2 稳定自 10.12 但对 16.x 不保证)。  
来源:§4 "Cross-cutting" 段落。

---

## 落地 checklist

- [ ] 确认所需符号数量:1 个 → 模式 1;多个同框架 → 模式 2;新 ObjC 类 → 模式 3
- [ ] handle 声明为进程级单例(懒加载,只 `dlopen` 一次)
- [ ] `dlopen` 使用 **框架内部二进制路径**;`CFBundleCreate` 使用 **框架目录路径**
- [ ] 每个 `dlsym` / `CFBundleGetFunctionPointerForName` 结果 nil-check + 日志
- [ ] `@convention(c)` typealias 签名与 C 原型逐字对齐
- [ ] 模式 3:设定轮询上限并在到达时降级;弱引用持有 controller 防止循环
- [ ] 标注 OS 版本适用范围的注释(`// macOS 15.4+ only`)
- [ ] 符号缺失时调用方能收到 `nil` / 降级值,不崩溃,不挂起

---

## 延伸阅读

- **媒体子系统**(MediaRemote 完整使用方式、NowPlayingCLI、ScriptingBridge reconcile)→ [`../media/`](../media/)
- **系统传感**(DisplayServices 亮度、CPU/内存/磁盘采样)→ [`../system-sensing/`](../system-sensing/)
- **权限**(AppleEvents 授权要求、Info.plist GENERATE_INFOPLIST_FILE 陷阱)→ [`../permissions/`](../permissions/)
- **NemoNotch 精确锚点**:→ [`../macos-cookbook.md`](../../macos-cookbook.md) §4
