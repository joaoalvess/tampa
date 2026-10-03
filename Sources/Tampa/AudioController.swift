import CoreAudio
import Foundation

@MainActor
final class AudioController {
    private static let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private let defaults = UserDefaults.standard

    var avoidsDisplayOutput: Bool {
        get { defaults.bool(forKey: "avoidDisplayAudio") }
        set {
            defaults.set(newValue, forKey: "avoidDisplayAudio")
            enforce()
        }
    }

    func start() {
        defaults.register(defaults: ["avoidDisplayAudio": true])
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.enforce() }
            }
        }
        enforce()
    }

    private func enforce() {
        guard avoidsDisplayOutput, let builtIn = builtInOutput() else { return }
        for selector in Self.selectors {
            guard let device = device(for: selector), isDisplay(device) else { continue }
            var address = Self.address(selector)
            var replacement = builtIn
            AudioObjectSetPropertyData(Self.system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &replacement)
        }
    }

    private func device(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = Self.address(selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private func builtInOutput() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }
    }

    private func isDisplay(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(of: device)
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }

    private func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    private func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
