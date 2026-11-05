import Foundation
@testable import NemoNotch
import Testing

/// Guards for the mediaremote daemon leak fix (2026-11-05 实案):
/// perl 守护在 daemon 模式下每发累积内存(闲时 ~7.6KB/发,放歌带 artwork
/// 时 MB 级/发,app 实测 20.5h 涨到 8.8GB)。修复分两层:
///
/// 1. dylib 资产打 `@autoreleasepool` 补丁(泄漏主修复,由
///    `scripts/mediaremote-leak-check.sh` 守卫,真跑 perl daemon 断言每发增量);
/// 2. 本文件守卫的两个纯策略——旧安装强制重解压(指纹)与看门狗回收阈值。
///
/// 断言面在策略边界:指纹缺失/过期/一致、阈值上下沿。
struct DaemonLeakGuardTests {
    @Test("重解压策略:目标缺失/指纹过期/指纹缺失都要重解压,一致才跳过")
    func dylibExtractionPolicy() {
        // 目标不存在:首次安装
        #expect(DylibExtractionPolicy.needsExtraction(
            destExists: false,
            recordedFingerprint: nil,
            assetFingerprint: "abc"
        ))
        #expect(DylibExtractionPolicy.needsExtraction(
            destExists: false,
            recordedFingerprint: "abc",
            assetFingerprint: "abc"
        ))
        // 目标存在 + 指纹一致:正常跳过
        #expect(!DylibExtractionPolicy.needsExtraction(
            destExists: true,
            recordedFingerprint: "abc",
            assetFingerprint: "abc"
        ))
        // 目标存在 + 指纹过期:资产升级,必须重解压
        #expect(DylibExtractionPolicy.needsExtraction(
            destExists: true,
            recordedFingerprint: "old",
            assetFingerprint: "abc"
        ))
        // 旧安装第一次带上本逻辑:没有指纹文件,强制重解压一次铺补丁
        #expect(DylibExtractionPolicy.needsExtraction(
            destExists: true,
            recordedFingerprint: nil,
            assetFingerprint: "abc"
        ))
    }

    @Test("看门狗策略:阈值下沿不回收,达阈/超阈回收,默认阈值 256MB")
    func daemonMemoryPolicy() {
        let threshold = 256 * 1024 * 1024
        #expect(DaemonMemoryPolicy.recycleThresholdBytes == threshold)
        #expect(!DaemonMemoryPolicy.shouldRecycle(footprintBytes: threshold - 1))
        #expect(DaemonMemoryPolicy.shouldRecycle(footprintBytes: threshold))
        #expect(DaemonMemoryPolicy.shouldRecycle(footprintBytes: threshold + 1))
        // 自定义阈值同样按上沿判定
        #expect(!DaemonMemoryPolicy.shouldRecycle(footprintBytes: 99, thresholdBytes: 100))
        #expect(DaemonMemoryPolicy.shouldRecycle(footprintBytes: 100, thresholdBytes: 100))
    }
}
