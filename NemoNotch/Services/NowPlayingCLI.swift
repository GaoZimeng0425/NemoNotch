import Foundation

final class NowPlayingCLI {
    private static let infoKeyMapping: [String: String] = [
        "title": "kMRMediaRemoteNowPlayingInfoTitle",
        "artist": "kMRMediaRemoteNowPlayingInfoArtist",
        "album": "kMRMediaRemoteNowPlayingInfoAlbum",
        "duration": "kMRMediaRemoteNowPlayingInfoDuration",
        "elapsedTime": "kMRMediaRemoteNowPlayingInfoElapsedTime",
        "playbackRate": "kMRMediaRemoteNowPlayingInfoPlaybackRate",
        "artworkData": "kMRMediaRemoteNowPlayingInfoArtworkData",
    ]

    private static let keys: [String] = [
        "title",
        "artist",
        "album",
        "duration",
        "elapsedTime",
        "playbackRate",
        "artworkData",
    ]

    private let queue = DispatchQueue(label: "NemoNotch.NowPlayingCLI", qos: .utility)
    private let executablePath: String?

    init() {
        executablePath = Self.resolveExecutablePath()
    }

    func fetchNowPlayingInfo(completion: @escaping ([String: Any]?) -> Void) {
        guard let executablePath else {
            completion(nil)
            return
        }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["get", "--json"] + Self.keys

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard
                let jsonObject = try? JSONSerialization.jsonObject(with: data),
                let info = Self.convertCLIJSONToMediaInfo(jsonObject)
            else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.async {
                completion(info)
            }
        }
    }

    private static func resolveExecutablePath() -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathFolders = envPath
            .split(separator: ":")
            .map(String.init)

        let explicitPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        let searchFolders = Array(Set(explicitPaths + pathFolders))
        let fileManager = FileManager.default
        for folder in searchFolders {
            let candidate = folder + "/nowplaying-cli"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func convertCLIJSONToMediaInfo(_ jsonObject: Any) -> [String: Any]? {
        guard let json = jsonObject as? [String: Any] else { return nil }
        var mediaInfo: [String: Any] = [:]

        for (cliKey, mediaKey) in infoKeyMapping {
            guard let value = json[cliKey], !(value is NSNull) else { continue }
            if cliKey == "artworkData", let base64 = value as? String, let data = Data(base64Encoded: base64) {
                mediaInfo[mediaKey] = data
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
}
