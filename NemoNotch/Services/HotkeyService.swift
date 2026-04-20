import Carbon
import Foundation

@Observable
final class HotkeyService {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actionMap: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        actionMap[id] = action

        let hotKeyID = EventHotKeyID(signature: FourCharCode(id), id: id)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, nil)
        if status == noErr {
            // Retrieve the ref — not directly available from RegisterEventHotKey,
            // so we track by ID and dispatch from the Carbon event handler.
        }

        installEventHandlerIfNeeded()
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionMap.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    deinit {
        unregisterAll()
    }

    private func installEventHandlerIfNeeded() {
        guard handler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    service.actionMap[hotKeyID.id]?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handler
        )
    }
}
