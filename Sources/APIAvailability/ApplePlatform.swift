import Foundation

/// An Apple platform whose SDK can be used to check API availability.
public enum ApplePlatform: String, CaseIterable, Sendable {
    case iOS
    case macOS
    case tvOS
    case watchOS
    case visionOS

    /// Accepts the spellings people and tools commonly use ("ios", "iPhoneOS", "xros", ...).
    public init?(name: String) {
        switch name.lowercased().replacingOccurrences(of: " ", with: "") {
        case "ios", "iphoneos", "iphonesimulator", "ipados":
            self = .iOS
        case "macos", "macosx", "osx":
            self = .macOS
        case "tvos", "appletvos", "appletvsimulator":
            self = .tvOS
        case "watchos", "watchsimulator":
            self = .watchOS
        case "visionos", "xros", "xrsimulator":
            self = .visionOS
        default:
            return nil
        }
    }

    /// The platform name the compiler and `@available` attributes use.
    public var availabilityName: String { rawValue }

    /// The `xcrun --sdk` name. Simulator SDKs are used so no signing or device is needed.
    var sdkName: String {
        switch self {
        case .iOS: return "iphonesimulator"
        case .macOS: return "macosx"
        case .tvOS: return "appletvsimulator"
        case .watchOS: return "watchsimulator"
        case .visionOS: return "xrsimulator"
        }
    }

    /// The target triple for compiling against this platform at a deployment target.
    func targetTriple(version: String) -> String {
        let arch = Self.hostArchitecture
        switch self {
        case .iOS: return "\(arch)-apple-ios\(version)-simulator"
        case .macOS: return "\(arch)-apple-macos\(version)"
        case .tvOS: return "\(arch)-apple-tvos\(version)-simulator"
        case .watchOS: return "\(arch)-apple-watchos\(version)-simulator"
        case .visionOS: return "\(arch)-apple-xros\(version)-simulator"
        }
    }

    /// The prefix of a module's `.swiftinterface` file name for this platform,
    /// e.g. `arm64-apple-ios-simulator`.
    var interfaceFilePrefix: String {
        let arch = Self.hostArchitecture
        switch self {
        case .iOS: return "\(arch)-apple-ios-simulator"
        case .macOS: return "\(arch)-apple-macos"
        case .tvOS: return "\(arch)-apple-tvos-simulator"
        case .watchOS: return "\(arch)-apple-watchos-simulator"
        case .visionOS: return "\(arch)-apple-xros-simulator"
        }
    }

    static var hostArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }
}

/// Normalizes a version such as "15" or "15.4" to "major.minor[.patch]",
/// or returns nil when it is not a version number.
func normalizedVersion(_ version: String) -> String? {
    let trimmed = version.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
        return nil
    }
    return parts.count == 1 ? "\(trimmed).0" : trimmed
}

/// Orders dotted version strings numerically ("9.0" < "10.0").
func versionPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        if l != r {
            return l < r
        }
    }
    return false
}
