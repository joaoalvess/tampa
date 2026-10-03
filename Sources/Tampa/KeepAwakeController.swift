import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeController {
    var onChange: (() -> Void)?

    private var assertions: [IOPMAssertionID] = []

    var isActive: Bool {
        !assertions.isEmpty
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    func deactivate() {
        guard isActive else { return }
        for id in assertions {
            IOPMAssertionRelease(id)
        }
        assertions = []
        onChange?()
    }

    private func activate() {
        let types = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventSystemSleep
        ]
        for type in types {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Tampa: manter o Mac acordado" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        onChange?()
    }
}
