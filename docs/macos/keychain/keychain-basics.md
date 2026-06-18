---
summary: 'macOS Keychain 基础:SecItemCopyMatching 加载、SecItemAdd/Update 存储、accessibility 常量选取、service+account keying。'
read_when:
  - '为 macOS 应用持久化 API key / OAuth token / 设备身份密钥'
  - '实现"不存在则生成"的 load-or-create 模式'
  - '需要防止凭证随 iCloud Keychain 同步到其他设备'
sources: ['N §14', 'I-7']
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §7'
---

# Keychain 基础

## TL;DR

| 操作 | API | 关键点 |
|---|---|---|
| 加载 | `SecItemCopyMatching` | `errSecItemNotFound` 是正常信号,不算错误 |
| 存储 | `SecItemUpdate` → 失败再 `SecItemAdd` | update-first 避免重复项 |
| 可访问性 | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | 设备内、解锁后、不 iCloud 同步 |
| Keying | `kSecAttrService` + `kSecAttrAccount` | 多 secret 必须配对;单 secret 可省 service |

---

## 可复用模式

### Pattern 1 · Load-or-Create(通用范式)

存自有 secret(设备身份密钥、自生成 token)的"不存在则生成"范式。**注意**:NemoNotch 早期用此范式把 OpenClaw 设备密钥存进 Keychain,但**现已迁移为文件存储**(`openclaw-device.key`,见下方"血泪教训");下面是范式本身,生产里的写入端实例见 Pattern 2(Ironsmith)。

```swift
let keychainKey = "ai.example.device-key"

// ── 1. Load ──
let query: [String: Any] = [
    kSecClass as String:       kSecClassGenericPassword,
    kSecAttrAccount as String: keychainKey,
    kSecReturnData as String:  true,
]
var result: AnyObject?
if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
   let keyData = result as? Data,
   let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
    return (key, derivedDeviceId)
}

// ── 2. Generate & Save ──
let newKey = Curve25519.Signing.PrivateKey()
let addQuery: [String: Any] = [
    kSecClass as String:            kSecClassGenericPassword,
    kSecAttrAccount as String:      keychainKey,
    kSecValueData as String:        newKey.rawRepresentation,
    // 生产代码应加 kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
]
SecItemAdd(addQuery as CFDictionary, nil)
```

> **⚠️ 血泪教训(NemoNotch 实测):自生成密钥别急着放 Keychain。** NemoNotch 的 OpenClaw 设备密钥**最初用上面这套 Keychain load-or-create**,后来改成纯文件存储(`Application Support/.../openclaw-device.key`,见 `OpenClawService.swift:88-110`)。原因:**ad-hoc 开发签名下每次 rebuild 的 cdhash 都变,Keychain item 的 ACL 不再认得"同一个 app",于是每次启动都弹系统授权框**。对"只给本 app 自己用"的自生成密钥,文件存储(配 `kCFURLIsExcludedFromBackupKey` 之类)反而更省心。要走 Keychain,务必先把签名身份稳定下来(见 [../build-release/](../build-release/))。详细的 cdhash/ACL 机制见 [cdhash-gated-read.md](./cdhash-gated-read.md)。

### Pattern 2 · Update-First 存储(Ironsmith `ProviderCredentialStore`)

先 `SecItemUpdate`,`errSecItemNotFound` 时再 `SecItemAdd`——避免重复项:

```swift
struct ProviderCredentialStore {
    static let apiKeyAccessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    private let service = "com.ironsmith.provider-credentials"

    func saveAPIKey(_ apiKey: String, for reference: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference,             // e.g. "provider.openai"
        ]
        let attrs: [CFString: Any] = [
            kSecValueData:    Data(apiKey.utf8),
            kSecAttrAccessible: Self.apiKeyAccessibility,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData]     = Data(apiKey.utf8)
            insert[kSecAttrAccessible] = Self.apiKeyAccessibility
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
            else { throw KeychainError.saveFailed }
        } else {
            guard status == errSecSuccess else { throw KeychainError.saveFailed }
        }
    }

    func loadAPIKey(for reference: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    reference,
            kSecReturnData:     true,
            kSecMatchLimit:     kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }   // errSecItemNotFound → nil, 正常
        return String(data: data, encoding: .utf8)
    }

    func deleteAPIKey(for reference: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound 视为成功,忽略
        assert(status == errSecSuccess || status == errSecItemNotFound)
    }
}
```

---

## Accessibility 常量选取

**裁决:推荐 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`。**

| 常量 | 解锁后可读 | 重启后持久 | iCloud 同步 | 适用 |
|---|---|---|---|---|
| `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | ✓ | ✓ | **否** | **推荐:设备身份密钥、API key、OAuth token** |
| `kSecAttrAccessibleWhenUnlocked` | ✓ | ✓ | 是 | 跨设备 token(显式需要) |
| `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | 重启后解锁一次即可 | ✓ | **否** | 后台 daemon 需在屏幕锁定时访问 |
| `kSecAttrAccessibleAlways`(已废弃) | 任何时候 | ✓ | 是 | 禁止使用 |

选 `ThisDeviceOnly` 的理由:
- 凭证通常是设备绑定的(API key 与账号关联,设备身份密钥即是"本设备"的意义)。
- iCloud 同步意味着凭证泄露面从单机扩展到 iCloud 账号关联的所有设备。
- 若需要显式跨设备同步,用 `kSecAttrAccessibleWhenUnlocked` 并在注释中说明理由。

---

## service + account Keying

**多 secret 服务(Ironsmith 风格)**:同一 app 存多个不同 secret → 必须同时设 `kSecAttrService`(区分 feature/provider)+ `kSecAttrAccount`(区分具体 key):

```swift
kSecAttrService: "com.ironsmith.provider-credentials"
kSecAttrAccount: "provider.openai"    // 引用串由 ProviderConfig.apiKeyReference 派生
```

**按 service 匹配、account 不定(NemoNotch `UsageQuotaService` 风格)**:读取**别的 app 写入**的凭证(Claude Code / Codex CLI 写的)时,account 由对方决定、本方不可控,于是**只按 `kSecAttrService` 匹配,取一条结果**:

```swift
// NemoNotch/Services/UsageQuotaService.swift:571-589
let query: [String: Any] = [
    kSecClass as String:       kSecClassGenericPassword,
    kSecAttrService as String: service,        // 只认 service;account 由 CLI 决定
    kSecMatchLimit as String:  kSecMatchLimitOne,
    kSecReturnData as String:  true,
]
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
```

三种都合法,按谁拥有 item 选:**自有多 secret** → service + account 配对(Pattern 2);**自有单 secret** → 二者择一即可;**读他人写入** → 按 service 匹配 + `kSecMatchLimitOne`。自有多 secret 若省略 service,account 需自保全局唯一(反向域名前缀),否则不同功能的 key 互相覆盖。

---

## 锚点(file:line)

| 符号 | 路径:行 | 说明 |
|---|---|---|
| `UsageQuotaService` 读 CLI 凭证 | `NemoNotch/Services/UsageQuotaService.swift:571-589` | **现行**唯一 Keychain `SecItemCopyMatching` 用例:按 `kSecAttrService` 匹配、`kSecMatchLimitOne` |
| `loadOrCreateDeviceIdentity()`(已迁文件) | `NemoNotch/Services/OpenClawService.swift:88-110` | **不再用 Keychain**:改纯文件 `openclaw-device.key`(ad-hoc 签名下 Keychain ACL 跨 rebuild 失效) |
| `ProviderCredentialStore.saveAPIKey` | Ironsmith 项目 `CredentialStore.swift` | Update-first 存储范式,`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `ProviderCredentialStore.loadAPIKey` | Ironsmith 项目 `CredentialStore.swift` | load 返回 `nil`、delete 当成功处理 |

---

## Pitfalls

**`errSecItemNotFound` 不是错误。** `SecItemCopyMatching` 找不到 item 返回 `-25300`——这是"需要生成"的分支信号,不应 `LogService.error(...)` 或 `throw`。同理,`SecItemDelete` 时 `errSecItemNotFound` 表示"已不存在",视为成功处理。

**缺 `kSecAttrAccessible` 时默认更宽松。** `SecItemAdd` 不显式设 `kSecAttrAccessible` 时,系统默认 `kSecAttrAccessibleWhenUnlocked`(允许 iCloud Keychain 同步)。**生产代码写自有 secret 时应补 `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**,防止设备身份密钥随 iCloud 同步泄露到其他设备。

**不用 update-first 导致重复项。** 直接 `SecItemAdd` 而不先尝试 `SecItemUpdate`,当 item 已存在时返回 `errSecDuplicateItem`(`-25299`)。若忽略返回值,下次 `load` 会返回旧值。正确做法:先 `SecItemUpdate`(失败 `errSecItemNotFound` 再 `Add`)或先 `Delete` 再 `Add`(不推荐,存在 TOCTOU 窗口)。

**`kSecReturnData` + `kSecReturnAttributes` 不能单次共用。** 若既要原始 data 又要 metadata(account、service、accessGroup),需两次查询:第一次 `kSecReturnData: true`,第二次 `kSecReturnAttributes: true`。单次查询只能通过 `kSecReturnRef` 间接获取两者,但 `SecKeychainItemRef` API 已废弃。

**另一 app 的 item 数据读取会触发 ACL 对话框。** GUI app 对自己创建的 item 做 `kSecReturnData` 读取是静默的;对其他 app 创建的 item(如 Claude Code CLI、Codex CLI)做数据读取,macOS 会弹"Allow/Deny"确认框——即使加了所有 no-UI flag 也无法阻止。处理方式见 [cdhash-gated-read.md](./cdhash-gated-read.md)。

---

## 落地 checklist

- [ ] `SecItemAdd` 时设置 `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- [ ] 多 secret 服务:同时设 `kSecAttrService`(feature/bundle 级别)+ `kSecAttrAccount`(key 级别)
- [ ] 存储用 update-first:先 `SecItemUpdate`,`errSecItemNotFound` 再 `SecItemAdd`
- [ ] 加载时 `errSecItemNotFound` 返回 `nil`,不 log error,不 throw
- [ ] 删除时 `errSecItemNotFound` 视为成功,不 log error
- [ ] 涉及其他 app 的 Keychain item → 阅读 [cdhash-gated-read.md](./cdhash-gated-read.md) 再动手

---

## 延伸阅读

- [./cdhash-gated-read.md](./cdhash-gated-read.md) — 读取其他 app Keychain item 的无提示框完整方案
- [../permissions/](../permissions/) — TCC 权限状态机,PermissionCard "never-auto-prompt" 模式
- [../private-api/](../private-api/) — dlopen/dlsym 加载废弃 C symbol(`SecKeychainSetUserInteractionAllowed`)
- [../build-release/](../build-release/) — 签名身份与 cdhash 稳定性(Developer ID vs ad-hoc)
- Apple 官方:[Keychain Services](https://developer.apple.com/documentation/security/keychain_services)、[Sharing Access to Keychain Items Among a Collection of Apps](https://developer.apple.com/documentation/security/sharing_access_to_keychain_items_among_a_collection_of_apps)
