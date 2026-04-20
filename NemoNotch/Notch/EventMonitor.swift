import AppKit

final class EventMonitor {
    static let shared = EventMonitor()

    var onMouseMove: ((NSPoint) -> Void)?
    var onMouseDown: (() -> Void)?
    var onRightMouseDown: ((NSPoint) -> Void)?

    private var monitors: [Any] = []

    private init() {
        start()
    }

    private func start() {
        let globalMove = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onMouseMove?(NSEvent.mouseLocation)
            }
        }
        let globalDown = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onMouseDown?()
            }
        }
        let globalRightDown = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onRightMouseDown?(NSEvent.mouseLocation)
            }
        }
        let localMove = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                self?.onMouseMove?(NSEvent.mouseLocation)
            }
            return event
        }
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.onMouseDown?()
            }
            return event
        }
        let localRightDown = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.onRightMouseDown?(NSEvent.mouseLocation)
            }
            return event
        }
        monitors = [globalMove as Any, globalDown as Any, globalRightDown as Any, localMove as Any, localDown as Any, localRightDown as Any]
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}
