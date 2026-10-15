@testable import NemoNotch
import Testing

@Suite("SettingsSearchTests")
struct SettingsSearchTests {
    // 纯过滤函数的固定语料:不依赖 bundle,测试只关心匹配语义。
    private let corpus: [SettingsPage: [String]] = [
        .general: ["通用", "Weather City", "Language"],
        .aiAgents: ["AI 与 Agent", "Claude Code", "opencode", "OpenClaw"],
        .keepAwake: ["防休眠", "sudo command"],
        .about: ["关于", "NemoNotch"],
    ]

    @Test("空白查询返回 nil(不过滤,回到正常分组)")
    func blankQueryReturnsNil() {
        #expect(SettingsSearchIndex.matchingPages("", stringsByPage: corpus) == nil)
        #expect(SettingsSearchIndex.matchingPages("   \n ", stringsByPage: corpus) == nil)
    }

    @Test("按页面标题与设置项标题匹配")
    func matchesPageAndSettingTitles() {
        #expect(SettingsSearchIndex.matchingPages("通用", stringsByPage: corpus) == [.general])
        #expect(SettingsSearchIndex.matchingPages("weather", stringsByPage: corpus) == [.general])
        #expect(SettingsSearchIndex.matchingPages("claude", stringsByPage: corpus) == [.aiAgents])
    }

    @Test("忽略大小写、变音符号与全半角")
    func normalization() {
        #expect(SettingsSearchIndex.matchingPages("WEATHER CITY", stringsByPage: corpus) == [.general])
        #expect(SettingsSearchIndex.matchingPages("ｗｅａｔｈｅｒ", stringsByPage: corpus) == [.general])
        #expect(
            SettingsSearchIndex.matchingPages("cafe", stringsByPage: [
                .general: ["Café"],
            ]) == [.general]
        )
    }

    @Test("无命中返回空数组(区别于 nil)")
    func noMatchReturnsEmpty() {
        #expect(SettingsSearchIndex.matchingPages("不存在词条", stringsByPage: corpus) == [])
    }

    @Test("多页命中保持 allCases 原始顺序")
    func multipleMatchesKeepCanonicalOrder() {
        // "Language"→general、"Agent"→aiAgents、"sudo command"→keepAwake,
        // 三个命中的排列顺序必须与 SettingsPage.allCases 一致(跨表关系断言)。
        let both = SettingsSearchIndex.matchingPages("n", stringsByPage: corpus)
        let expectedOrder = SettingsPage.allCases.filter { both?.contains($0) ?? false }
        #expect(both == expectedOrder)
        #expect(both?.contains(.general) == true)
        #expect(both?.contains(.keepAwake) == true)
    }

    @Test("索引词条按应用内语言解析,系统语言不参与")
    func stringsByPageHonorsAppLanguage() {
        // 判别性断言:settings.nav.general 的 zh-Hans 值是"通用"、en 值是
        // "General" —— 若 bundle 解析坏了(恒回退 .main),按固定语言取的
        // 词条就对不上目录里的已知译文。
        let zh = SettingsSearchIndex.stringsByPage(language: .zhHans)
        #expect(zh[.general]?.contains("通用") == true)
        let en = SettingsSearchIndex.stringsByPage(language: .en)
        #expect(en[.general]?.contains("General") == true)
        // 固定字面量(provider 名)原样保留;system(nil)与显式语言产出
        // 相同的页面集合。
        #expect(zh[.aiAgents]?.contains("opencode") == true)
        let systemStrings = SettingsSearchIndex.stringsByPage(language: nil)
        #expect(Set(zh.keys) == Set(systemStrings.keys))
    }
}
