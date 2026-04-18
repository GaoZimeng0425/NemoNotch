import Foundation
import ObjectiveC.runtime

final class MediaRemote {
    static let shared = MediaRemote()

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int, [AnyHashable: Any]?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SetCanBeNowPlayingFn = @convention(c) (Bool) -> Void

    private let getNowPlayingInfoFn: GetNowPlayingInfoFn?
    private let sendCommandFn: SendCommandFn?
    private let registerFn: RegisterFn?
    private let setCanBeNowPlayingFn: SetCanBeNowPlayingFn?

    private init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL)
        if handle == nil {
            print("[NemoNotch] dlopen MediaRemote failed: \(String(cString: dlerror()))")
        }

        let bundleURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL)

        func loadFn<T>(_ name: String, as _: T.Type) -> T? {
            guard let bundle, let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
                return nil
            }
            return unsafeBitCast(ptr, to: T.self)
        }

        self.getNowPlayingInfoFn = loadFn("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFn.self)
        self.sendCommandFn = loadFn("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        self.registerFn = loadFn("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        self.setCanBeNowPlayingFn = loadFn("MRMediaRemoteSetCanBeNowPlayingApplication", as: SetCanBeNowPlayingFn.self)
    }

    func registerForNotifications() {
        registerFn?(.main)
    }

    func setCanBeNowPlayingApplication(_ canBe: Bool) {
        setCanBeNowPlayingFn?(canBe)
    }

    func getNowPlayingInfo(completion: @escaping ([String: Any]?) -> Void) {
        guard let fn = getNowPlayingInfoFn else {
            completion(nil)
            return
        }
        fn(.main) { info in
            completion(info)
        }
    }

    @discardableResult
    func sendCommand(_ command: Command) -> Bool {
        guard let fn = sendCommandFn else { return false }
        return fn(command.rawValue, nil)
    }

    // MARK: - macOS 15.4+ fallback via MRNowPlayingController

    private var controller: NSObject?
    private var pollTimer: DispatchSourceTimer?

    func queryViaNewControllerAPI(completion: @escaping ([String: Any]?) -> Void) {
        guard let destClass = NSClassFromString("MRDestination") as? NSObject.Type,
              let configClass = NSClassFromString("MRNowPlayingControllerConfiguration") as? NSObject.Type,
              let controllerClass = NSClassFromString("MRNowPlayingController") as? NSObject.Type else {
            completion(nil)
            return
        }

        if controller == nil {
            let destSel = NSSelectorFromString("userSelectedDestination")
            guard destClass.responds(to: destSel),
                  let dest = destClass.perform(destSel)?.takeUnretainedValue() else {
                completion(nil)
                return
            }

            // class_createInstance creates an uninitialized instance; we then call
            // the designated init via perform(_:with:) (mirrors ObjC `[[Cls alloc] initWithX:y]`).
            guard let configInstance = class_createInstance(configClass, 0) as? NSObject else {
                completion(nil)
                return
            }
            let initConfigSel = NSSelectorFromString("initWithDestination:")
            guard let configObj = configInstance.perform(initConfigSel, with: dest)?.takeUnretainedValue() as? NSObject else {
                completion(nil)
                return
            }
            configObj.setValue(false, forKey: "singleShot")
            configObj.setValue(true, forKey: "requestPlaybackState")
            configObj.setValue(true, forKey: "requestPlaybackQueue")

            guard let controllerInstance = class_createInstance(controllerClass, 0) as? NSObject else {
                completion(nil)
                return
            }
            let initCtlSel = NSSelectorFromString("initWithConfiguration:")
            guard let ctl = controllerInstance.perform(initCtlSel, with: configObj)?.takeUnretainedValue() as? NSObject else {
                completion(nil)
                return
            }
            ctl.perform(NSSelectorFromString("beginLoadingUpdates"))
            self.controller = ctl
        }

        guard let controller = self.controller else {
            completion(nil)
            return
        }

        // Poll the controller's `response` property briefly; the daemon updates
        // it asynchronously after the load begins.
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var pollCount = 0
        let maxPolls = 8 // ~800ms total
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            pollCount += 1
            let response = controller.value(forKey: "response") as? NSObject
            let info = MediaRemote.buildInfoDict(from: response)
            let hasData = info != nil && !(info?.isEmpty ?? true)
            if hasData || pollCount >= maxPolls {
                timer.cancel()
                self?.pollTimer = nil
                completion(info)
            }
        }
        pollTimer = timer
        timer.resume()
    }

    private static func buildInfoDict(from response: NSObject?) -> [String: Any]? {
        guard let response else { return nil }
        var info: [String: Any] = [:]

        if let rate = response.value(forKey: "playbackRate") as? NSNumber {
            if rate.doubleValue > 0 {
                info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = rate
            } else if let stateNum = response.value(forKey: "playbackState") as? NSNumber {
                info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = (stateNum.uintValue == 1) ? NSNumber(value: 1.0) : NSNumber(value: 0.0)
            } else {
                info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = rate
            }
        }

        guard let queue = response.value(forKey: "playbackQueue") as? NSObject else {
            return info.isEmpty ? nil : info
        }
        guard let items = queue.value(forKey: "contentItems") as? [NSObject], !items.isEmpty else {
            return info.isEmpty ? nil : info
        }

        let location = (queue.value(forKey: "location") as? NSNumber)?.intValue ?? 0
        let item: NSObject = (location >= 0 && location < items.count) ? items[location] : items[0]
        guard let meta = item.value(forKey: "metadata") as? NSObject else {
            return info.isEmpty ? nil : info
        }

        let mappings: [(metaKey: String, infoKey: String)] = [
            ("title", "kMRMediaRemoteNowPlayingInfoTitle"),
            ("trackArtistName", "kMRMediaRemoteNowPlayingInfoArtist"),
            ("albumName", "kMRMediaRemoteNowPlayingInfoAlbum"),
            ("albumArtistName", "kMRMediaRemoteNowPlayingInfoAlbumArtist"),
            ("composer", "kMRMediaRemoteNowPlayingInfoComposer"),
            ("genre", "kMRMediaRemoteNowPlayingInfoGenre"),
            ("duration", "kMRMediaRemoteNowPlayingInfoDuration"),
            ("elapsedTime", "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            ("trackNumber", "kMRMediaRemoteNowPlayingInfoTrackNumber"),
            ("discNumber", "kMRMediaRemoteNowPlayingInfoDiscNumber"),
            ("totalTrackCount", "kMRMediaRemoteNowPlayingInfoTotalTrackCount"),
        ]
        for (mk, ik) in mappings {
            if let value = meta.value(forKey: mk) {
                info[ik] = value
            }
        }

        // Try common artwork keys.
        for key in ["artworkData", "artwork"] {
            if let data = meta.value(forKey: key) as? Data {
                info["kMRMediaRemoteNowPlayingInfoArtworkData"] = data
                break
            }
        }

        if let extra = meta.value(forKey: "nowPlayingInfo") as? [String: Any] {
            for (k, v) in extra where info[k] == nil {
                info[k] = v
            }
        }

        return info.isEmpty ? nil : info
    }
}
