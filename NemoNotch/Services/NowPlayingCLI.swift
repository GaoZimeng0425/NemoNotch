@preconcurrency import Foundation

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
    ]

    private let queue = DispatchQueue(label: "NemoNotch.NowPlayingCLI", qos: .utility)
    private let processTimeoutSeconds: TimeInterval = 4.0
    private static let extractionTimeoutSeconds: TimeInterval = 4.0

    // Daemon state (accessed only on `queue`)
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonStdout: FileHandle?
    private var responseBuffer = Data()
    private var pendingCompletion: (([String: Any]?) -> Void)?
    private var timeoutItem: DispatchWorkItem?

    // Fallback helpers (one-shot)
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
        if helpers.isEmpty { helpers = [.unavailable] }
        fallbackHelpers = helpers
    }

    deinit {
        stopDaemon()
    }

    // MARK: - Public API

    func fetchNowPlayingInfo(completion: @Sendable @escaping ([String: Any]?) -> Void) {
        queue.async {
            if self.ensureDaemon() {
                self.fetchViaDaemon(completion: completion)
            } else {
                self.fetchUsingFallbacks(from: 0, completion: completion)
            }
        }
    }

    // MARK: - Daemon Lifecycle

    @discardableResult
    private func ensureDaemon() -> Bool {
        if let p = daemonProcess, p.isRunning { return true }
        return startDaemon()
    }

    private func startDaemon() -> Bool {
        guard let helper = fallbackHelpers.first,
              case .bundled(let script, let dylib) = helper else {
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

        daemonStdout?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.handleDaemonData(data)
            }
        }

        LogService.info("daemon started (pid=\(process.processIdentifier))", category: "NowPlayingCLI")
        return true
    }

    private func stopDaemon() {
        daemonStdout?.readabilityHandler = nil
        if let p = daemonProcess, p.isRunning {
            p.terminate()
        }
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
        responseBuffer = Data()
        pendingCompletion = nil
        timeoutItem?.cancel()
        timeoutItem = nil
    }

    private func restartDaemon() {
        stopDaemon()
        _ = startDaemon()
    }

    // MARK: - Daemon Fetch

    private func fetchViaDaemon(completion: @Sendable @escaping ([String: Any]?) -> Void) {
        guard pendingCompletion == nil else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        pendingCompletion = completion
        responseBuffer = Data()

        guard let data = "\n".data(using: .utf8) else {
            finishPending(nil)
            return
        }

        guard let stdin = daemonStdin, let p = daemonProcess, p.isRunning else {
            finishPending(nil)
            return
        }
        stdin.write(data)

        let item = DispatchWorkItem { [weak self] in
            self?.queue.async {
                self?.handleDaemonTimeout()
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
    }

    private func handleDaemonTimeout() {
        LogService.error("daemon timed out after \(processTimeoutSeconds)s", category: "NowPlayingCLI")
        daemonStdout?.readabilityHandler = nil
        restartDaemon()
        finishPending(nil)
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
        case .bundled(let script, let dylib):
            guard let data = runProcess(
                executable: "/usr/bin/perl",
                arguments: [script, dylib, "adapter_get_env"],
                sourceTag: "cli/perl"
            ) else { next(); return }

            if let jsonObject = try? JSONSerialization.jsonObject(with: data),
               let info = Self.convertToMediaInfo(jsonObject) {
                DispatchQueue.main.async { completion(info) }
            } else {
                next()
            }

        case .external(let path):
            guard let data = runProcess(
                executable: path,
                arguments: ["get", "--json", "title", "artist", "album",
                            "duration", "elapsedTime", "playbackRate", "artworkData"],
                sourceTag: "cli/external"
            ) else { next(); return }

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

        var stdoutData = Data()
        let readQueue = DispatchQueue(label: "NemoNotch.pipe-read", qos: .utility)

        readQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

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
                LogService.error("\(sourceTag) exit=\(process.terminationStatus), stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))", category: "NowPlayingCLI")
            } else {
                LogService.error("\(sourceTag) exit=\(process.terminationStatus)", category: "NowPlayingCLI")
            }
            return nil
        }

        return stdoutData
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

        if FileManager.default.fileExists(atPath: dest) {
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
            LogService.error("bundled extract failed to run gunzip: \(error.localizedDescription)", category: "NowPlayingCLI")
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
                LogService.error("bundled extract exit=\(process.terminationStatus), stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))", category: "NowPlayingCLI")
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
            return dest
        } catch {
            try? FileManager.default.removeItem(atPath: tempDest)
            return nil
        }
    }

    // MARK: - Fallback search

    private static func findSystemDylib() -> String? {
        for path in ["/opt/homebrew/lib/nowplaying-cli/MediaRemoteMini.dylib",
                     "/usr/local/lib/nowplaying-cli/MediaRemoteMini.dylib"] {
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
        if title.isEmpty && artist.isEmpty {
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
    static let full: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let simple: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
