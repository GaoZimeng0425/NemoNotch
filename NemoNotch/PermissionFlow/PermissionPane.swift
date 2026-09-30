import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A Privacy & Security pane in System Settings whose authorization list
/// accepts a dropped `.app` bundle.
///
/// Only a subset of privacy panes are "app-list style" — the ones below. Every
/// other pane (Camera, Microphone, Photos, Calendars, …) is driven by a system
/// prompt on first use and has no list to drop onto, so the floating guide
/// must not be shown for them.
///
/// The drag itself does not bypass TCC: the drop is still performed by the
/// user, inside System Settings. This app only supplies a drag source and
/// guides the user to the right page.
enum PermissionPane {
    case accessibility
    case fullDiskAccess
    case inputMonitoring
    case screenRecording
    case appManagement
    case developerTools
    case bluetooth
    case mediaAppleMusic

    /// Deep link that opens this pane in System Settings.
    ///
    /// `com.apple.preference.security` + `Privacy_*` is the anchor form that
    /// works from Ventura through Tahoe (matches what NotificationService
    /// already used for Accessibility).
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .appManagement: anchor = "Privacy_AppBundles"
        case .developerTools: anchor = "Privacy_DevTools"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .mediaAppleMusic: anchor = "Privacy_Media"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Poll function reporting whether the grant has landed.
    ///
    /// `nil` means there is no public preflight API for this service, so the
    /// guide panel can't auto-detect success and stays until System Settings
    /// closes or the user dismisses it.
    var isGranted: (() -> Bool)? {
        switch self {
        case .accessibility:
            // Plain `AXIsProcessTrusted()` rather than
            // `AXIsProcessTrustedWithOptions`: the `kAXTrustedCheckOptionPrompt`
            // global is a C mutable variable and is rejected as unsafe shared
            // state under Swift 6 strict concurrency. This also matches what
            // NotificationService already polls with.
            return { AXIsProcessTrusted() }
        case .screenRecording:
            return { CGPreflightScreenCaptureAccess() }
        case .fullDiskAccess, .inputMonitoring, .appManagement,
             .developerTools, .bluetooth, .mediaAppleMusic:
            return nil
        }
    }

    var localizedTitle: String {
        switch self {
        case .accessibility: String(localized: "permission.accessibility.title")
        case .fullDiskAccess: String(localized: "permission.fulldisk.title")
        case .inputMonitoring: String(localized: "permission.inputmonitoring.title")
        case .screenRecording: String(localized: "permission.screenrecording.title")
        case .appManagement: String(localized: "permission.appmanagement.title")
        case .developerTools: String(localized: "permission.devtools.title")
        case .bluetooth: String(localized: "permission.bluetooth.title")
        case .mediaAppleMusic: String(localized: "permission.media.title")
        }
    }
}
