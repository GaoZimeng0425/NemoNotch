@preconcurrency import CryptoKit
@preconcurrency import Foundation

/// 资产指纹策略:已解压的 dylib 是否需要随 bundle 内资产更新而重解压。
/// 旧安装第一次带上本逻辑时 `recordedFingerprint` 为 nil → 强制重解压一次,
/// 把打了 `@autoreleasepool` 补丁的 dylib 铺下去(否则老用户升级 app 后
/// `~/Library/Application Support/NemoNotch/` 里的旧 dylib 永远不会被替换)。
enum DylibExtractionPolicy {
    static func needsExtraction(
        destExists: Bool,
        recordedFingerprint: String?,
        assetFingerprint: String
    ) -> Bool {
        guard destExists else { return true }
        return recordedFingerprint != assetFingerprint
    }
}

/// 泄漏看门狗策略:perl 守护 footprint 达阈值即回收。主修复是 dylib 的
/// `@autoreleasepool` 补丁(scripts/build-mediaremote-mini.sh);这里是兜底——
/// artwork 场景(放歌时 MB 级/发)无法在探针里可靠驱动,守卫不依赖归因。
enum DaemonMemoryPolicy {
    static let recycleThresholdBytes = 256 * 1024 * 1024

    static func shouldRecycle(
        footprintBytes: Int,
        thresholdBytes: Int = recycleThresholdBytes
    ) -> Bool {
        footprintBytes >= thresholdBytes
    }
}

final class NowPlayingCLI: @unchecked Sendable {
    private static let infoKeyMapping: [String: String] = [
        "title": "kMRMediaRemoteNowPlayingInfoTitle",
        "artist": "kMRMediaRemoteNowPlayingInfoArtist",
        "album": "kMRMediaRemoteNowPlayingInfoAlbum",
        "duration": "kMRMediaRemoteNowPlayingInfoDuration",
        "elapsedTime": "kMRMediaRemoteNowPlayingInfoElapsedTime",
        "playbackRate": "kMRMediaRemoteNowPlayingInfoPlaybackRate",
        "timestamp": "kMRMediaRemoteNowPlayingInfoTimestamp",
        "artworkData": "kMRMediaRemoteNowPlayingInfoArtworkData",
        "parentApplicationBundleIdentifier": "kMRMediaRemoteNowPlayingInfoParentAppBundleID",
        "bundleIdentifier": "kMRMediaRemoteNowPlayingInfoAppBundleID",
    ]

    private let queue = DispatchQueue(label: "NemoNotch.NowPlayingCLI", qos: .utility)
    private let processTimeoutSeconds: TimeInterval = 4.0
    private static let extractionTimeoutSeconds: TimeInterval = 4.0

    // Daemon state (accessed only on `queue`)
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonStdout: FileHandle?
    private var daemonStderr: FileHandle?
    private var responseBuffer = Data()
    private var pendingCompletion: (([String: Any]?) -> Void)?
    private var timeoutItem: DispatchWorkItem?

    /// Fallback helpers (one-shot)
    private let fallbackHelpers: [HelperType]

    private enum HelperType {
        case bundled(script: String, dylib: String)
        case external(String)
        case unavailable
    }

    init() {
        var helpers: [HelperType] = []
        if let script = Bundle.main.path(forResource: "mediaremote-mini", ofType: "pl"),
           let gzPath = Bundle.main.path(forResource: "MediaRemoteMini", ofType: "bin.gz"),
           let dylib = Self.extractDylib(gzPath: gzPath) {
            helpers.append(.bundled(script: script, dylib: dylib))
        }
        if let script = Bundle.main.path(forResource: "mediaremote-mini", ofType: "pl"),
           let dylib = Self.findSystemDylib() {
            helpers.append(.bundled(script: script, dylib: dylib))
        }
        if let path = Self.findExternal() {
            helpers.append(.external(path))
        }
        if helpers.isEmpty {
            helpers = [.unavailable]
        }
        fallbackHelpers = helpers
    }

    deinit {
        stopDaemon()
    }

    // MARK: - Public API

    func fetchNowPlayingInfo(completion: @Sendable @escaping ([String: Any]?) -> Void) {
        let enqueued = PerfProbe.begin()
        queue.async {
            PerfProbe.end("NowPlayingCLI.fetch.queueWait", enqueued)
            let started = PerfProbe.begin()
            let probed: @Sendable ([String: Any]?) -> Void = { info in
                PerfProbe.end("NowPlayingCLI.fetch.perlBridgeIPC", started)
                completion(info)
            }
            if self.ensureDaemon() {
                self.fetchViaDaemon(completion: probed)
            } else {
                PerfProbe.hit("NowPlayingCLI.fetch.fellBackToSubprocess")
                self.fetchUsingFallbacks(from: 0, completion: probed)
            }
        }
    }

    // MARK: - Daemon Lifecycle

    @discardableResult
    private func ensureDaemon() -> Bool {
        if let p = daemonProcess, p.isRunning {
            return true
        }
        return startDaemon()
    }

    private func startDaemon() -> Bool {
        guard let helper = fallbackHelpers.first,
              case let .bundled(script, dylib) = helper else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, dylib, "adapter_get_env", "--daemon"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            LogService.error("daemon start failed: \(error.localizedDescription)", category: "NowPlayingCLI")
            return false
        }

        daemonProcess = process
        daemonStdin = stdinPipe.fileHandleForWriting
        daemonStdout = stdoutPipe.fileHandleForReading
        daemonStderr = stderrPipe.fileHandleForReading

        // stderr 必须有人读:管道缓冲(约 64KB)写满后 daemon 会阻塞在 write,
        // stdin/stdout 协议随之停摆,表现为周期性 4s 超时 + 重启循环。
        daemonStderr?.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            LogService.debug(
                "daemon stderr: \(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")",
                category: "NowPlayingCLI"
            )
        }

        daemonStdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            queue.async {
                self.handleDaemonData(data)
            }
        }

        LogService.info("daemon started (pid=\(process.processIdentifier))", category: "NowPlayingCLI")
        return true
    }

    private func stopDaemon() {
        daemonStdout?.readabilityHandler = nil
        daemonStderr?.readabilityHandler = nil
        if let p = daemonProcess, p.isRunning {
            p.terminate()
        }
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
        daemonStderr = nil
        responseBuffer = Data()
        pendingCompletion = nil
        timeoutItem?.cancel()
        timeoutItem = nil
    }

    private func restartDaemon() {
        stopDaemon()
        _ = startDaemon()
    }

    // MARK: - 泄漏看门狗

    /// `RUSAGE_INFO_V3` flavor;`RUSAGE_INFO_*` 是 C 宏 Swift 不可见,按
    /// sys/resource.h 硬编码。刻意不用 `rusage_info_current`(指向 SDK 最新
    /// 版结构,与内核写回长度不一致会 SIGABRT,PerfProbe 实案见 AGENTS.md);
    /// 显式 v3 结构 + v3 flavor 与外部监控工具同款,实测安全。
    private static let rusageInfoV3Flavor: Int32 = 3

    private static func daemonFootprintBytes(pid: pid_t) -> Int? {
        var info = rusage_info_v3()
        // SDK 的 Swift 桥接把出参声明成 UnsafeMutablePointer<rusage_info_t?>
        // (指向"可选裸指针");把 v3 结构体存储重绑成该类型后传首地址——内核
        // 按 flavor=3 写回整个 v3 结构,缓冲区尺寸即 sizeof(rusage_info_v3)。
        let result = withUnsafeMutableBytes(of: &info) { raw -> Int32 in
            let typed = raw.bindMemory(to: rusage_info_t?.self)
            // PerfProbe 实案雷的是 rusage_info_current(SDK 最新版枚举,结构
            // 长度与内核写回不一致 SIGABRT);本行显式 RUSAGE_INFO_V3 + v3
            // 结构体,2026-11-05 独立探针本机实跑 rc=0,评审记录留证据。
            return proc_pid_rusage(pid, rusageInfoV3Flavor, typed.baseAddress!) // fence: allow
        }
        guard result == 0 else { return nil }
        return Int(info.ri_phys_footprint)
    }

    /// 每收到一轮完整响应查一次(≈2s 一发,一个 syscall,可忽略);超阈值
    /// 走现成 restartDaemon。在 `queue` 上调用,与超时重启同款上下文。
    private func recycleDaemonIfBloated() {
        guard let process = daemonProcess, process.isRunning,
              let footprint = Self.daemonFootprintBytes(pid: process.processIdentifier),
              DaemonMemoryPolicy.shouldRecycle(footprintBytes: footprint) else { return }
        LogService.info(
            "daemon footprint \(footprint / 1_048_576)MB over threshold, recycling (leak guard)",
            category: "NowPlayingCLI"
        )
        restartDaemon()
    }

    // MARK: - Daemon Fetch

    private func fetchViaDaemon(completion: @Sendable @escaping ([String: Any]?) -> Void) {
        guard pendingCompletion == nil else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        pendingCompletion = completion
        responseBuffer = Data()

        guard let data = "\n".data(using: .utf8), let stdin = daemonStdin, let p = daemonProcess, p.isRunning else {
            finishPending(nil)
            return
        }
        stdin.write(data)

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            queue.async {
                self.handleDaemonTimeout()
            }
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + processTimeoutSeconds, execute: item)
    }

    private func handleDaemonData(_ data: Data) {
        guard pendingCompletion != nil else { return }
        responseBuffer.append(data)

        guard let newline = responseBuffer.range(of: Data([0x0A])) else { return }

        let responseData = responseBuffer[..<newline.lowerBound]
        responseBuffer.removeSubrange(...newline.lowerBound)

        timeoutItem?.cancel()
        timeoutItem = nil

        if let jsonObject = try? JSONSerialization.jsonObject(with: responseData),
           let info = Self.convertToMediaInfo(jsonObject) {
            finishPending(info)
        } else {
            finishPending(nil)
        }

        recycleDaemonIfBloated()
    }

    private func handleDaemonTimeout() {
        LogService.error("daemon timed out after \(processTimeoutSeconds)s", category: "NowPlayingCLI")
        daemonStdout?.readabilityHandler = nil
        // 必须在 restartDaemon() 之前放行 pending 的 completion:stopDaemon() 会
        // 把 pendingCompletion 置 nil,之后再 finishPending 读到的就是 nil,该次
        // 请求的回调被永久丢弃 —— MediaService 的 isUpdatingNowPlaying 只在回调
        // 里复位,一次超时就会把整个媒体管道锁死到重启 app。
        finishPending(nil)
        restartDaemon()
    }

    private func finishPending(_ result: [String: Any]?) {
        let completion = pendingCompletion
        pendingCompletion = nil
        let box = InfoBox(info: result)
        DispatchQueue.main.async { completion?(box.info) }
    }

    // MARK: - Fallback (one-shot processes)

    private func fetchUsingFallbacks(from index: Int, completion: @Sendable @escaping ([String: Any]?) -> Void) {
        guard index < fallbackHelpers.count else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let helper = fallbackHelpers[index]
        let next: () -> Void = { [weak self] in
            self?.fetchUsingFallbacks(from: index + 1, completion: completion)
        }

        switch helper {
        case let .bundled(script, dylib):
            guard let data = runProcess(
                executable: "/usr/bin/perl",
                arguments: [script, dylib, "adapter_get_env"],
                sourceTag: "cli/perl"
            ) else { next()
                return
            }

            if let jsonObject = try? JSONSerialization.jsonObject(with: data),
               let info = Self.convertToMediaInfo(jsonObject) {
                DispatchQueue.main.async { completion(info) }
            } else {
                next()
            }

        case let .external(path):
            guard let data = runProcess(
                executable: path,
                arguments: [
                    "get",
                    "--json",
                    "title",
                    "artist",
                    "album",
                    "duration",
                    "elapsedTime",
                    "playbackRate",
                    "artworkData",
                ],
                sourceTag: "cli/external"
            ) else { next()
                return
            }

            if let jsonObject = try? JSONSerialization.jsonObject(with: data),
               let info = Self.convertToMediaInfo(jsonObject) {
                DispatchQueue.main.async { completion(info) }
            } else {
                next()
            }

        case .unavailable:
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func runProcess(executable: String, arguments: [String], sourceTag: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)

        do {
            try process.run()
        } catch {
            LogService.error("\(sourceTag) failed to run: \(error.localizedDescription)", category: "NowPlayingCLI")
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let timeout = processTimeoutSeconds
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            LogService.error("\(sourceTag) timed out after \(timeout)s", category: "NowPlayingCLI")
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            return nil
        }

        if process.terminationStatus != 0 {
            if let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
               !stderrText.isEmpty {
                LogService.error(
                    "\(sourceTag) exit=\(process.terminationStatus), stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))",
                    category: "NowPlayingCLI"
                )
            } else {
                LogService.error("\(sourceTag) exit=\(process.terminationStatus)", category: "NowPlayingCLI")
            }
            return nil
        }

        return stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    }

    // MARK: - Dylib extraction

    private static let supportDir: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NemoNotch", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func extractDylib(gzPath: String) -> String? {
        let dest = (supportDir as NSString).appendingPathComponent("MediaRemoteMini.dylib")
        let fingerprintPath = dest + ".sha256"
        let assetFingerprint = sha256HexOfFile(atPath: gzPath)

        // 资产指纹变了(或旧安装第一次带上本逻辑)→ 删旧重解压;
        // 指纹一致 → 直接复用已解压产物,不重复 gunzip。
        if !DylibExtractionPolicy.needsExtraction(
            destExists: FileManager.default.fileExists(atPath: dest),
            recordedFingerprint: try? String(contentsOfFile: fingerprintPath, encoding: .utf8),
            assetFingerprint: assetFingerprint
        ) {
            return dest
        }

        let tempDest = dest + ".tmp"
        _ = try? FileManager.default.removeItem(atPath: tempDest)
        FileManager.default.createFile(atPath: tempDest, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", gzPath]

        let stderr = Pipe()
        guard let outputHandle = FileHandle(forWritingAtPath: tempDest) else {
            LogService.error("bundled extract failed to create temp output", category: "NowPlayingCLI")
            return nil
        }
        process.standardOutput = outputHandle
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)

        do {
            try process.run()
        } catch {
            LogService.error(
                "bundled extract failed to run gunzip: \(error.localizedDescription)",
                category: "NowPlayingCLI"
            )
            try? outputHandle.close()
            try? FileManager.default.removeItem(atPath: tempDest)
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + extractionTimeoutSeconds)
        try? outputHandle.close()
        if waitResult == .timedOut {
            LogService.error("bundled extract timed out after \(extractionTimeoutSeconds)s", category: "NowPlayingCLI")
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            try? FileManager.default.removeItem(atPath: tempDest)
            return nil
        }

        guard process.terminationStatus == 0 else {
            if let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
               !stderrText.isEmpty {
                LogService.error(
                    "bundled extract exit=\(process.terminationStatus), stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))",
                    category: "NowPlayingCLI"
                )
            } else {
                LogService.error("bundled extract exit=\(process.terminationStatus)", category: "NowPlayingCLI")
            }
            try? FileManager.default.removeItem(atPath: tempDest)
            return nil
        }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: tempDest)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                LogService.error("bundled extract produced empty output", category: "NowPlayingCLI")
                try? FileManager.default.removeItem(atPath: tempDest)
                return nil
            }

            if FileManager.default.fileExists(atPath: dest) {
                try FileManager.default.removeItem(atPath: dest)
            }
            try FileManager.default.moveItem(atPath: tempDest, toPath: dest)
            // 成功后记资产指纹;写失败不致命(下次启动多解压一次而已)。
            try? assetFingerprint.write(toFile: fingerprintPath, atomically: true, encoding: .utf8)
            return dest
        } catch {
            try? FileManager.default.removeItem(atPath: tempDest)
            return nil
        }
    }

    private static func sha256HexOfFile(atPath path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fallback search

    private static func findSystemDylib() -> String? {
        for path in [
            "/opt/homebrew/lib/nowplaying-cli/MediaRemoteMini.dylib",
            "/usr/local/lib/nowplaying-cli/MediaRemoteMini.dylib",
        ] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func findExternal() -> String? {
        var dirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let home = NSHomeDirectory()
        dirs.append(contentsOf: [
            (home as NSString).appendingPathComponent("bin"),
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".cargo/bin"),
        ])
        dirs.append(contentsOf: discoverBrewCellarBinDirs())

        for dir in dirs {
            let candidate = dir + "/nowplaying-cli"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func discoverBrewCellarBinDirs() -> [String] {
        let cellarRoots = ["/opt/homebrew/Cellar/nowplaying-cli", "/usr/local/Cellar/nowplaying-cli"]
        var result: [String] = []
        for root in cellarRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for version in entries {
                let binDir = (root as NSString).appendingPathComponent(version + "/bin")
                result.append(binDir)
            }
        }
        return result
    }

    private struct InfoBox: @unchecked Sendable {
        let info: [String: Any]?
    }

    // MARK: - Conversion

    private static func convertToMediaInfo(_ jsonObject: Any) -> [String: Any]? {
        guard let json = jsonObject as? [String: Any] else { return nil }
        var mediaInfo: [String: Any] = [:]

        for (cliKey, mediaKey) in infoKeyMapping {
            guard let value = json[cliKey], !(value is NSNull) else { continue }
            if cliKey == "artworkData", let base64 = value as? String, let data = Data(base64Encoded: base64) {
                mediaInfo[mediaKey] = data
                continue
            }
            if cliKey == "timestamp" {
                if let date = parseTimestamp(value) {
                    mediaInfo[mediaKey] = date
                }
                continue
            }
            mediaInfo[mediaKey] = value
        }

        let title = mediaInfo["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = mediaInfo["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        if title.isEmpty, artist.isEmpty {
            return nil
        }

        return mediaInfo
    }

    private static func parseTimestamp(_ value: Any) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }

        if let date = ISO8601DateFormatter.full.date(from: text) {
            return date
        }
        if let date = ISO8601DateFormatter.simple.date(from: text) {
            return date
        }
        return nil
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let simple: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
