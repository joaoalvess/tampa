import CoreGraphics
import Foundation

@MainActor
enum PrivateDisplayAPI {
    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias GetDisplayListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private static let configureEnabled = resolve(["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], as: ConfigureEnabledFn.self)
    private static let getDisplayList = resolve(["SLSGetDisplayList", "CGSGetDisplayList"], as: GetDisplayListFn.self)

    static var isAvailable: Bool { configureEnabled != nil }

    static func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) -> CGError {
        guard let configureEnabled else { return .notImplemented }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return begin }
        let result = configureEnabled(config, display, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return result
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }

    static func allDisplays() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return [] }
        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success else { return [] }
        let capacity = max(count + 8, 32)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard getDisplayList(capacity, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(min(count, capacity))))
    }

    private static func resolve<T>(_ names: [String], as type: T.Type) -> T? {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        for name in names {
            if let symbol = dlsym(defaultHandle, name) {
                return unsafeBitCast(symbol, to: type)
            }
        }
        return nil
    }
}
