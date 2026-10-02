import Carbon
import Foundation

@MainActor
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let address = UInt(bitPattern: userData)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                    Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue().action()
                }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5441_4D50), id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
