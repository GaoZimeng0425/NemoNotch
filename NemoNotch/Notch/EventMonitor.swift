import AppKit

final class EventMonitor {
    static let shared = EventMonitor()

    var onMouseMove: ((NSPoint) -> Void)?
    var onMouseDown: (() -> Void)?

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
        monitors = [globalMove as Any, globalDown as Any, localMove as Any, localDown as Any]
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}
