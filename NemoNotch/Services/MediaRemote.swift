@preconcurrency import Foundation

@MainActor
final class MediaRemote {
    static let shared = MediaRemote()

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
        case skipBackward15 = 12
        case skipForward15 = 13
        case skipBackward = 17
        case skipForward = 18
        case seekToPlaybackPosition = 19
    }

    private typealias SendCommandFn = @convention(c) (Int, [AnyHashable: Any]?) -> Bool
    private typealias SetElapsedTimeFn = @convention(c) (Double) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SetCanBeNowPlayingFn = @convention(c) (Bool) -> Void

    private let sendCommandFn: SendCommandFn?
    private let registerFn: RegisterFn?
    private let setCanBeNowPlayingFn: SetCanBeNowPlayingFn?
    private let setElapsedTimeFn: SetElapsedTimeFn?

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

        sendCommandFn = loadFn("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        registerFn = loadFn("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        setCanBeNowPlayingFn = loadFn("MRMediaRemoteSetCanBeNowPlayingApplication", as: SetCanBeNowPlayingFn.self)
        setElapsedTimeFn = loadFn("MRMediaRemoteSetElapsedTime", as: SetElapsedTimeFn.self)
    }

    func registerForNotifications() {
        registerFn?(.main)
    }

    func setCanBeNowPlayingApplication(_ canBe: Bool) {
        setCanBeNowPlayingFn?(canBe)
    }

    @discardableResult
    func sendCommand(_ command: Command, options: [AnyHashable: Any]? = nil) -> Bool {
        guard let fn = sendCommandFn else { return false }
        return fn(command.rawValue, options)
    }

    /// Seek by a relative interval (positive forward, negative backward) using
    /// MediaRemote's skip commands. Works system-wide for any player that
    /// supports MPRemoteCommandCenter skip handlers (Music, Podcasts, Safari/
    /// Chrome media, etc.) — no AppleScript permission needed.
    @discardableResult
    func skip(interval: Double) -> Bool {
        guard interval != 0 else { return false }
        let forward = interval > 0
        let magnitude = abs(interval)
        let options: [AnyHashable: Any] = [
            "kMRMediaRemoteOptionSkipInterval": NSNumber(value: magnitude),
        ]
        // Try the generic skip command first (honors the interval).
        if sendCommand(forward ? .skipForward : .skipBackward, options: options) {
            return true
        }
        // Fallback: dedicated 15s skip commands (interval is ignored by API).
        return sendCommand(forward ? .skipForward15 : .skipBackward15)
    }

    /// Seek to absolute elapsed time (seconds). Returns true if the API symbol
    /// was available.
    @discardableResult
    func setElapsedTime(_ seconds: Double) -> Bool {
        guard let fn = setElapsedTimeFn else { return false }
        fn(seconds)
        return true
    }
}
