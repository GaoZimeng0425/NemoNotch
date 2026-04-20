import Foundation

final class NowPlayingCLI {
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
    private let helpers: [HelperType]
    private let processTimeoutSeconds: TimeInterval = 4.0
    private static let extractionTimeoutSeconds: TimeInterval = 4.0

    private enum HelperType {
        case bundled(script: String, gzPath: String)
        case systemDylib(script: String, dylib: String)
        case external(String)
        case unavailable

        var debugDescription: String {
            switch self {
            case .bundled(let script, let gzPath):
                return "bundled(script=\((script as NSString).lastPathComponent), gz=\((gzPath as NSString).lastPathComponent))"
            case .systemDylib(_, let dylib):
                return "systemDylib(path=\(dylib))"
            case .external(let path):
                return "external(path=\(path))"
            case .unavailable:
                return "unavailable"
            }
        }
    }

    init() {
        var resolved: [HelperType] = []

        if let script = Bundle.main.path(forResource: "mediaremote-mini", ofType: "pl"),
           let gzPath = Bundle.main.path(forResource: "MediaRemoteMini", ofType: "bin.gz") {
            resolved.append(.bundled(script: script, gzPath: gzPath))
        }

        if let script = Bundle.main.path(forResource: "mediaremote-mini", ofType: "pl"),
           let dylib = Self.findSystemDylib() {
            resolved.append(.systemDylib(script: script, dylib: dylib))
        }

        if let path = Self.findExternal() {
            resolved.append(.external(path))
        }

        if resolved.isEmpty { resolved = [.unavailable] }
        helpers = resolved
    }

    func fetchNowPlayingInfo(completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            self.fetchUsingHelpers(from: 0, completion: completion)
        }
    }

    private func fetchUsingHelpers(from index: Int, completion: @escaping ([String: Any]?) -> Void) {
        guard index < helpers.count else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let helper = helpers[index]
        let next: () -> Void = { [weak self] in
            self?.fetchUsingHelpers(from: index + 1, completion: completion)
        }

        switch helper {
        case .bundled(let script, let gzPath):
            guard let dylib = Self.extractDylib(gzPath: gzPath) else {
                next()
                return
            }
            runPerl(script: script, dylib: dylib) { info in
                if let info {
                    completion(info)
                } else {
                    next()
                }
            }

        case .systemDylib(let script, let dylib):
            runPerl(script: script, dylib: dylib) { info in
                if let info {
                    completion(info)
                } else {
                    next()
                }
            }

        case .external(let path):
            runExternal(path: path) { info in
                if let info {
                    completion(info)
                } else {
                    next()
                }
            }

        case .unavailable:
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func runPerl(script: String, dylib: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let data = runProcess(
            executable: "/usr/bin/perl",
            arguments: [script, dylib, "adapter_get_env"],
            sourceTag: "cli/perl"
        ) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let info = Self.convertToMediaInfo(jsonObject) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.main.async { completion(info) }
    }

    private func runExternal(path: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let data = runProcess(
            executable: path,
            arguments: ["get", "--json", "title", "artist", "album",
                        "duration", "elapsedTime", "playbackRate", "artworkData"],
            sourceTag: "cli/external"
        ) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let info = Self.convertToMediaInfo(jsonObject) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.main.async { completion(info) }
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

    private func runProcess(executable: String, arguments: [String], sourceTag: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

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

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            if let stderrText = String(data: stderrData, encoding: .utf8), !stderrText.isEmpty {
                LogService.error("\(sourceTag) exit=\(process.terminationStatus), stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))", category: "NowPlayingCLI")
            } else {
                LogService.error("\(sourceTag) exit=\(process.terminationStatus)", category: "NowPlayingCLI")
            }
            return nil
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

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

        // nowplaying-cli helper emits ISO-8601 strings.
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
