@preconcurrency import Foundation

/// Thin loader for the private `MediaRemote.framework`. Only the **non-gated**
/// functions remain here — registering for Now Playing change notifications and
/// opting out of being a Now Playing app. Control commands (`MRMediaRemoteSendCommand`
/// / `MRMediaRemoteSetElapsedTime`) were removed: since macOS 15.4 those are gated
/// to Apple-signed processes and no-op in-process, so control now goes through
/// `MediaRemoteCommander` (the mediaremote-adapter perl bridge). See cookbook §7.6.
@MainActor
final class MediaRemote {
    static let shared = MediaRemote()

    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SetCanBeNowPlayingFn = @convention(c) (Bool) -> Void

    private let registerFn: RegisterFn?
    private let setCanBeNowPlayingFn: SetCanBeNowPlayingFn?

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

        registerFn = loadFn("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        setCanBeNowPlayingFn = loadFn("MRMediaRemoteSetCanBeNowPlayingApplication", as: SetCanBeNowPlayingFn.self)
    }

    func registerForNotifications() {
        registerFn?(.main)
    }

    func setCanBeNowPlayingApplication(_ canBe: Bool) {
        setCanBeNowPlayingFn?(canBe)
    }
}
