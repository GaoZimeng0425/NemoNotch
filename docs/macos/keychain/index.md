---
summary: 'macOS Keychain 区块:基础 CRUD + accessibility 常量裁决,以及 GUI app 静默读取其他 app item 的 cdhash-gated 完整方案。'
read_when:
  - '需要在 macOS app 里持久化凭证(API key / OAuth token / 设备密钥)'
  - '需要读取由其他进程(CLI 工具)创建的 Keychain item 且不弹对话框'
sources: ['N §14', 'I-7']
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §7'
---

# keychain/

macOS Keychain 操作参考。两篇覆盖「自有 item CRUD」到「跨 app 静默读」的全流程。

## 文章

| 文件 | 摘要 |
|------|------|
| [keychain-basics.md](keychain-basics.md) | `SecItemCopyMatching` 加载、update-first 存储、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 裁决、service+account keying 两种风格 |
| [cdhash-gated-read.md](cdhash-gated-read.md) | GUI app 读取其他 app item 的四步方案:file-first → attributes-only 探测 → cdhash-gated data 读 → `SecKeychainSetUserInteractionAllowed(false)` 防刷新弹窗 |
