import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class DisplayController: NSObject {
    enum DisableError: Error {
        case apiUnavailable
        case noBuiltin
        case noExternal
        case system(CGError)
    }

    var onChange: (() -> Void)?
    var onExternalConnected: (() -> Void)?
    var onRestoreStuck: (() -> Void)?

    let hiDPI = HiDPIController()

    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var knownExternalCount = 0
    private var restoreAttempts = 0
    private var restoreTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?

    var autoDisable: Bool {
        get { defaults.bool(forKey: "autoDisable") }
        set { defaults.set(newValue, forKey: "autoDisable") }
    }

    private(set) var isBuiltinOff: Bool {
        get { defaults.bool(forKey: "builtinOff") }
        set {
            defaults.set(newValue, forKey: "builtinOff")
            onChange?()
        }
    }

    var canDisable: Bool {
        PrivateDisplayAPI.isAvailable && !externalDisplays().isEmpty
    }

    func start() {
        if isBuiltinOff, isBuiltinActive() {
            isBuiltinOff = false
        }
        knownExternalCount = externalDisplays().count
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let address = UInt(bitPattern: userInfo)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                    Unmanaged<DisplayController>.fromOpaque(pointer).takeUnretainedValue().scheduleEvaluation()
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Tampa monitora monitores conectados")
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        evaluate()
    }

    func setHiDPI(_ enabled: Bool) {
        hiDPI.isEnabled = enabled
        evaluate()
    }

    func setHiDPISize(_ size: HiDPIController.Size) {
        guard size != hiDPI.size else { return }
        hiDPI.size = size
        hiDPI.tearDown()
        evaluate()
    }

    func disableBuiltin() throws(DisableError) {
        guard PrivateDisplayAPI.isAvailable else { throw .apiUnavailable }
        guard let id = builtinID() else { throw .noBuiltin }
        guard !externalDisplays().isEmpty else { throw .noExternal }
        stopRestoring()
        let result = PrivateDisplayAPI.setEnabled(false, display: id)
        guard result == .success else { throw .system(result) }
        isBuiltinOff = true
    }

    func enableBuiltin() {
        stopRestoring()
        attemptRestore()
    }

    func restoreBeforeQuit() {
        hiDPI.tearDown()
        stopRestoring()
        guard isBuiltinOff, let id = builtinID() else { return }
        if PrivateDisplayAPI.setEnabled(true, display: id) == .success {
            isBuiltinOff = false
        }
    }

    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    @objc private func poll() {
        evaluate()
    }

    private func evaluate() {
        let externals = externalDisplays()
        let wasWithoutExternal = knownExternalCount == 0
        knownExternalCount = externals.count
        if externals.isEmpty {
            hiDPI.update(physical: nil)
            if isBuiltinOff || !isBuiltinActive(), restoreTask == nil {
                enableBuiltin()
            }
        } else {
            if wasWithoutExternal, autoDisable, !isBuiltinOff {
                onExternalConnected?()
            }
            hiDPI.update(physical: externals.first)
            for display in externals where CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay {
                useHighestRefreshRate(on: display)
            }
        }
        onChange?()
    }

    private func useHighestRefreshRate(on display: CGDirectDisplayID) {
        guard let current = CGDisplayCopyDisplayMode(display) else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        guard let best = modes
            .filter({
                $0.width == current.width && $0.height == current.height
                    && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
            })
            .max(by: { $0.refreshRate < $1.refreshRate }),
            best.refreshRate > current.refreshRate + 0.5 else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, display, best, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    private func attemptRestore() {
        restoreTask = nil
        if let id = builtinID(), PrivateDisplayAPI.setEnabled(true, display: id) == .success {
            restoreAttempts = 0
            isBuiltinOff = false
            return
        }
        restoreAttempts += 1
        if restoreAttempts == 3 || restoreAttempts == 10 {
            powerCycleDisplays()
        }
        if restoreAttempts == 15 {
            onRestoreStuck?()
        }
        let delay: Duration = restoreAttempts < 15 ? .seconds(1) : .seconds(3)
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.attemptRestore()
        }
    }

    private func stopRestoring() {
        restoreTask?.cancel()
        restoreTask = nil
        restoreAttempts = 0
    }

    private func powerCycleDisplays() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        guard (try? pmset.run()) != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Tampa" as CFString, kIOPMUserActiveLocal, &assertion)
            IOPMAssertionRelease(assertion)
        }
    }

    private func builtinID() -> CGDirectDisplayID? {
        if let id = (PrivateDisplayAPI.allDisplays() + onlineDisplays()).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            defaults.set(Int(id), forKey: "builtinID")
            return id
        }
        let stored = defaults.integer(forKey: "builtinID")
        return stored > 0 ? CGDirectDisplayID(stored) : nil
    }

    private func isBuiltinActive() -> Bool {
        activeDisplays().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    private func externalDisplays() -> [CGDirectDisplayID] {
        guard externalLinkUp() else { return [] }
        return onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != HiDPIController.vendorID }
    }

    private func externalLinkUp() -> Bool {
        let matching = IOServiceMatching("DCPAVVideoInterfaceProxy") as NSMutableDictionary
        matching[kIOPropertyMatchKey] = ["Location": "External"]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        displayList(CGGetOnlineDisplayList)
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        displayList(CGGetActiveDisplayList)
    }

    private func displayList(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard fetch(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard fetch(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
