import Foundation
@testable import NemoNotch
import Testing

/// How a failed open of usernoted's database reads in Settings. The TCC
/// refusal must become `.noAccess` (Full Disk Access card), whatever Cocoa
/// code it surfaces as.
struct NotificationCenterReaderTests {
    @Test func tccRefusalAsWriteNoPermissionIsNoAccess() {
        // What the deployed app actually got on macOS 27 without Full Disk Access:
        // "你没有将文件“db”保存到文件夹“db2”中的权限。" (NSFileWriteNoPermissionError).
        let error = CocoaError(.fileWriteNoPermission)
        #expect(NotificationCenterReader.classifyOpenFailure(error) == .noAccess)
    }

    @Test func readNoPermissionIsNoAccess() {
        #expect(NotificationCenterReader.classifyOpenFailure(CocoaError(.fileReadNoPermission)) == .noAccess)
    }

    @Test func posixPermissionErrorsAreNoAccess() {
        #expect(NotificationCenterReader.classifyOpenFailure(POSIXError(.EPERM)) == .noAccess)
        #expect(NotificationCenterReader.classifyOpenFailure(POSIXError(.EACCES)) == .noAccess)
    }

    @Test func missingFileIsUnavailable() {
        #expect(NotificationCenterReader.classifyOpenFailure(CocoaError(.fileReadNoSuchFile))
            == .unavailable("database not found"))
    }
}
