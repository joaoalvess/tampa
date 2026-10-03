@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import IOKit.graphics
import VirtualDisplayPrivate

@MainActor
final class HiDPIController {
    static let vendorID: UInt32 = 0x7A4D

    enum Size: String, CaseIterable {
        case standard
        case larger
        case largest
        case moreSpace

        var scale: Double {
            switch self {
            case .standard: return 1
            case .larger: return 0.9
            case .largest: return 0.8
            case .moreSpace: return 1.125
            }
        }

        var title: String {
            switch self {
            case .standard: return "Padrão"
            case .larger: return "Maior"
            case .largest: return "Bem maior"
            case .moreSpace: return "Mais espaço"
            }
        }
    }

    var onFailure: (() -> Void)?
    private(set) var nativeWidth = 0
    private(set) var nativeHeight = 0

    private let defaults = UserDefaults.standard
    private var virtualDisplay: CGVirtualDisplay?
    private var physicalID: CGDirectDisplayID = 0
    private var physicalOrigin = CGPoint.zero
    private var pointWidth = 0
    private var pointHeight = 0
    private var generation = 0
    private var isConfiguring = false

    var isEnabled: Bool {
        get { defaults.bool(forKey: "hiDPI") }
        set { defaults.set(newValue, forKey: "hiDPI") }
    }

    var size: Size {
        get { defaults.string(forKey: "hiDPISize").flatMap(Size.init) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "hiDPISize") }
    }

    func pointSize(for size: Size) -> (width: Int, height: Int) {
        (Int((Double(nativeWidth) * size.scale).rounded()), Int((Double(nativeHeight) * size.scale).rounded()))
    }

    private var virtualID: CGDirectDisplayID? {
        virtualDisplay.map { CGDirectDisplayID($0.displayID) }
    }

    func update(physical: CGDirectDisplayID?) {
        guard isEnabled, let physical else {
            tearDown()
            return
        }
        if virtualDisplay != nil, physical != physicalID {
            tearDown()
        }
        guard let virtualID else {
            create(for: physical)
            return
        }
        if !isConfiguring, CGDisplayMirrorsDisplay(physical) != virtualID {
            mirror()
        }
    }

    func tearDown() {
        guard virtualDisplay != nil else { return }
        generation += 1
        isConfiguring = false
        virtualDisplay = nil
        physicalID = 0
    }

    private func create(for physical: CGDirectDisplayID) {
        guard let native = nativeMode(of: physical) else { return }
        nativeWidth = native.pixelWidth
        nativeHeight = native.pixelHeight
        let (width, height) = pointSize(for: size)
        let refreshRate = native.refreshRate > 0 ? native.refreshRate : 60
        physicalOrigin = CGDisplayBounds(physical).origin

        guard let display = makeVirtualDisplay(for: physical, width: width, height: height, refreshRate: refreshRate)
            ?? makeVirtualDisplay(for: physical, width: width, height: height, refreshRate: 60) else {
            fail()
            return
        }
        virtualDisplay = display
        physicalID = physical
        pointWidth = width
        pointHeight = height
        isConfiguring = true
        copyColorProfile(from: physical, to: CGDirectDisplayID(display.displayID))

        let current = generation
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == current else { return }
                if self.wantedMode() != nil { break }
            }
            guard let self, self.generation == current else { return }
            self.mirror()
        }
    }

    private func makeVirtualDisplay(for physical: CGDirectDisplayID, width: Int, height: Int, refreshRate: Double) -> CGVirtualDisplay? {
        generation += 1
        let current = generation

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "Tampa HiDPI"
        descriptor.queue = DispatchQueue.main
        let physicalSize = CGDisplayScreenSize(physical)
        let baseSize = physicalSize.width > 0 ? physicalSize : CGSize(width: 673, height: 284)
        descriptor.sizeInMillimeters = CGSize(width: baseSize.width * size.scale, height: baseSize.height * size.scale)
        descriptor.maxPixelsWide = UInt32(width * 2)
        descriptor.maxPixelsHigh = UInt32(height * 2)
        descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = UInt32(width / 16 + height + Int(refreshRate) + (defaults.integer(forKey: "hiDPISalt") + 1) * 4096)
        descriptor.serialNum = 1
        descriptor.terminationHandler = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.generation += 1
                self.isConfiguring = false
                self.virtualDisplay = nil
                self.physicalID = 0
            }
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [1.0, 0.875, 0.75, 0.5].map { scale in
            CGVirtualDisplayMode(
                width: UInt32((Double(width * 2) * scale).rounded()),
                height: UInt32((Double(height * 2) * scale).rounded()),
                refreshRate: refreshRate
            )
        }
        guard display.apply(settings) else {
            generation += 1
            return nil
        }
        return display
    }

    private func mirror() {
        guard let virtualID, physicalID != 0 else { return }
        isConfiguring = true
        let current = generation
        let mode = wantedMode()

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            fail()
            return
        }
        if let mode {
            CGConfigureDisplayWithDisplayMode(config, virtualID, mode, nil)
        }
        CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            fail()
            return
        }

        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == current else { return }
                if self.isMirroredInHiDPI(virtualID) { break }
            }
            guard let self, self.generation == current else { return }
            self.isConfiguring = false
            guard self.isMirroredInHiDPI(virtualID) else {
                self.fail()
                return
            }
            self.restorePosition()
        }
    }

    private func isMirroredInHiDPI(_ virtualID: CGDirectDisplayID) -> Bool {
        guard CGDisplayMirrorsDisplay(physicalID) == virtualID,
              let mode = CGDisplayCopyDisplayMode(physicalID) ?? CGDisplayCopyDisplayMode(virtualID) else { return false }
        return mode.width == pointWidth && mode.pixelWidth == pointWidth * 2
    }

    private func restorePosition() {
        guard let virtualID else { return }
        let origin = CGDisplayBounds(virtualID).origin
        guard origin != physicalOrigin else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        if physicalOrigin == .zero {
            for id in onlineDisplays() where CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay {
                let bounds = CGDisplayBounds(id)
                CGConfigureDisplayOrigin(config, id, Int32(bounds.origin.x - origin.x), Int32(bounds.origin.y - origin.y))
            }
        } else {
            CGConfigureDisplayOrigin(config, virtualID, Int32(physicalOrigin.x), Int32(physicalOrigin.y))
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func copyColorProfile(from source: CGDirectDisplayID, to target: CGDirectDisplayID) {
        guard let sourceUUID = CGDisplayCreateUUIDFromDisplayID(source)?.takeRetainedValue(),
              let targetUUID = CGDisplayCreateUUIDFromDisplayID(target)?.takeRetainedValue(),
              let url = currentProfileURL(of: sourceUUID) else { return }
        let profiles = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: url,
            kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser as String
        ] as CFDictionary
        ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), targetUUID, profiles)
    }

    private func currentProfileURL(of uuid: CFUUID) -> URL? {
        guard let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [AnyHashable: Any] ?? [:]
        let defaultID = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String].map { "\($0)" } ?? "1"
        let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [AnyHashable: Any] ?? [:]
        if let url = custom.first(where: { "\($0.key)" == defaultID })?.value as? URL {
            return url
        }
        let factoryEntry = factory.first(where: { "\($0.key)" == defaultID })?.value as? [String: Any]
        return factoryEntry?[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
    }

    private func fail() {
        tearDown()
        defaults.set(defaults.integer(forKey: "hiDPISalt") + 1, forKey: "hiDPISalt")
        isEnabled = false
        onFailure?()
    }

    private func wantedMode() -> CGDisplayMode? {
        guard let virtualID else { return nil }
        return allModes(of: virtualID).first {
            $0.width == pointWidth && $0.height == pointHeight && $0.pixelWidth == pointWidth * 2
        }
    }

    private func nativeMode(of display: CGDirectDisplayID) -> CGDisplayMode? {
        let modes = allModes(of: display)
        let native = modes.filter { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }
        return (native.isEmpty ? modes : native).max {
            ($0.pixelWidth * $0.pixelHeight, $0.refreshRate) < ($1.pixelWidth * $1.pixelHeight, $1.refreshRate)
        }
    }

    private func allModes(of display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
