import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Reads the running app bundle's Info.plist-derived facts (summary + declared privacy/permissions),
/// decodes binary/XML plists to readable JSON, and converts arbitrary plist values into `JSONValue`.
/// Degrades gracefully on a non-app host (e.g. the macOS test runner): fields are optional and
/// `supported` flips to false rather than erroring.
enum BundleInspector {

    // MARK: - Summary

    struct Summary: Encodable, Sendable {
        let supported: Bool
        let bundleId: String?
        let bundlePath: String?
        let displayName: String?
        let shortVersion: String?
        let build: String?
        let minimumOSVersion: String?
        let platform: String?
        let deviceFamilies: [String]
        let sdkName: String?
        let icon: String?
    }

    static func summary() -> Summary {
        let info = Bundle.main.infoDictionary
        let families: [String] = (info?["UIDeviceFamily"] as? [Int] ?? []).map { code in
            switch code { case 1: return "iPhone"; case 2: return "iPad"; case 3: return "tv"; case 4: return "watch"; default: return "family(\(code))" }
        }
        return Summary(
            supported: Bundle.main.bundleIdentifier != nil || info != nil,
            bundleId: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.path,
            displayName: (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String),
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            minimumOSVersion: (info?["MinimumOSVersion"] as? String) ?? (info?["LSMinimumSystemVersion"] as? String),
            platform: info?["DTPlatformName"] as? String,
            deviceFamilies: families,
            sdkName: info?["DTSDKName"] as? String,
            icon: iconBase64()
        )
    }

    // MARK: - Privacy / permissions

    struct UsageDescription: Encodable, Sendable { let key: String; let purpose: String }
    struct ATS: Encodable, Sendable { let allowsArbitraryLoads: Bool; let exceptionDomains: [String] }
    struct Privacy: Encodable, Sendable {
        let usageDescriptions: [UsageDescription]
        let urlSchemes: [String]
        let backgroundModes: [String]
        let ats: ATS?
    }

    static func privacy() -> Privacy {
        let info = Bundle.main.infoDictionary ?? [:]
        let usage = info.keys
            .filter { $0.hasSuffix("UsageDescription") }
            .sorted()
            .compactMap { key -> UsageDescription? in
                guard let purpose = info[key] as? String else { return nil }
                return UsageDescription(key: key, purpose: purpose)
            }
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        let modes = (info["UIBackgroundModes"] as? [String]) ?? []
        var ats: ATS?
        if let atsDict = info["NSAppTransportSecurity"] as? [String: Any] {
            let domains = (atsDict["NSExceptionDomains"] as? [String: Any]).map { Array($0.keys).sorted() } ?? []
            ats = ATS(allowsArbitraryLoads: (atsDict["NSAllowsArbitraryLoads"] as? Bool) ?? false,
                      exceptionDomains: domains)
        }
        return Privacy(usageDescriptions: usage, urlSchemes: schemes, backgroundModes: modes, ats: ats)
    }

    // MARK: - Plist decoding

    struct PlistDecode: Encodable, Sendable { let path: String; let format: String; let json: JSONValue }

    enum PlistError: Error { case notReadable(String) }

    /// Decode a binary/XML/OpenStep plist (incl. binary `.strings`) into readable JSON.
    static func decodePlist(at url: URL) throws -> PlistDecode {
        guard let data = try? Data(contentsOf: url) else {
            throw PlistError.notReadable("could not read file")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw PlistError.notReadable(error.localizedDescription)
        }
        let name: String
        switch format {
        case .binary: name = "binary"
        case .openStep: name = "openstep"
        case .xml: name = "xml"
        @unknown default: name = "unknown"
        }
        return PlistDecode(path: url.path, format: name, json: plistToJSONValue(obj))
    }

    // MARK: - Plist → JSONValue

    /// Converts any property-list value into `JSONValue`. Dates and Data aren't JSON-native, so they
    /// become tagged objects (`{"$date": <unix-seconds>}` / `{"$data": "<base64>", "bytes": N}`).
    static func plistToJSONValue(_ value: Any) -> JSONValue {
        if let dict = value as? [String: Any] {
            return .object(dict.mapValues(plistToJSONValue))
        }
        if let array = value as? [Any] {
            return .array(array.map(plistToJSONValue))
        }
        if let s = value as? String {
            return .string(s)
        }
        if let date = value as? Date {
            return .object(["$date": .int(Int(date.timeIntervalSince1970))])
        }
        if let data = value as? Data {
            return .object(["$data": .string(data.base64EncodedString()), "bytes": .int(data.count)])
        }
        // A boolean NSNumber must be distinguished from a numeric one (in Swift every NSNumber casts
        // to Bool), so check the CoreFoundation boolean type id first.
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool((value as? Bool) ?? false)
        }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            if d.rounded() == d && abs(d) < 9_007_199_254_740_992 { return .int(n.intValue) }
            return .double(d)
        }
        return .string("\(value)")
    }

    // MARK: - Icon (iOS only; the icon lives in the app bundle)

    static func iconBase64() -> String? {
        #if canImport(UIKit)
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last,
              let image = UIImage(named: name),
              let png = image.pngData() else { return nil }
        return png.base64EncodedString()
        #else
        return nil
        #endif
    }
}
