import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Reads `embedded.mobileprovision` from the app bundle. The file is a CMS/PKCS#7 (DER) signed
/// blob; rather than pull in an ASN.1/Security decoder, we extract the embedded XML plist by
/// slicing between its `<?xml`/`<plist` start and the final `</plist>` and hand that to
/// `PropertyListSerialization` — the well-known dependency-free approach. Absent on the Simulator
/// and App Store builds, so absence is a normal `present: false`, never an error.
enum ProvisioningInspector {
    struct Info: Encodable, Sendable {
        let present: Bool
        var name: String?
        var teamIdentifier: String?
        var teamName: String?
        var appIdName: String?
        var appId: String?
        var creationDate: Int?
        var expirationDate: Int?
        var expired: Bool?
        var provisionedDeviceCount: Int?
        var isDistribution: Bool?
        var entitlements: JSONValue?
        var parseError: String?

        static func absent() -> Info {
            Info(present: false, name: nil, teamIdentifier: nil, teamName: nil, appIdName: nil,
                 appId: nil, creationDate: nil, expirationDate: nil, expired: nil,
                 provisionedDeviceCount: nil, isDistribution: nil, entitlements: nil, parseError: nil)
        }
    }

    static func inspect(bundleURL: URL?, now: Date = Date()) -> Info {
        guard let bundleURL else { return .absent() }
        let url = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return .absent() }
        return inspect(provisioningData: data, now: now)
    }

    /// Testable core: parse a raw mobileprovision blob (CMS bytes) into the summary.
    static func inspect(provisioningData data: Data, now: Date = Date()) -> Info {
        guard let plistData = extractPlist(from: data),
              let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            return Info(present: true, name: nil, teamIdentifier: nil, teamName: nil, appIdName: nil,
                        appId: nil, creationDate: nil, expirationDate: nil, expired: nil,
                        provisionedDeviceCount: nil, isDistribution: nil, entitlements: nil,
                        parseError: "could not extract the embedded plist")
        }

        let expiration = dict["ExpirationDate"] as? Date
        let provisioned = dict["ProvisionedDevices"] as? [String]
        let provisionsAll = (dict["ProvisionsAllDevices"] as? Bool) ?? false
        let entitlementsDict = dict["Entitlements"] as? [String: Any]

        return Info(
            present: true,
            name: dict["Name"] as? String,
            teamIdentifier: (dict["TeamIdentifier"] as? [String])?.first,
            teamName: dict["TeamName"] as? String,
            appIdName: dict["AppIDName"] as? String,
            appId: entitlementsDict?["application-identifier"] as? String,
            creationDate: (dict["CreationDate"] as? Date).map { Int($0.timeIntervalSince1970) },
            expirationDate: expiration.map { Int($0.timeIntervalSince1970) },
            expired: expiration.map { $0 < now },
            provisionedDeviceCount: provisioned?.count,
            isDistribution: provisionsAll || provisioned == nil,
            entitlements: entitlementsDict.map { BundleInspector.plistToJSONValue($0) },
            parseError: nil
        )
    }

    /// Slice out the embedded XML plist: from the first `<?xml` (or `<plist`) marker to the LAST
    /// `</plist>` (searched backwards so a stray match inside the cert blob can't truncate it).
    static func extractPlist(from data: Data) -> Data? {
        let xmlMarker = Data("<?xml".utf8)
        let plistMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        let start = data.range(of: xmlMarker) ?? data.range(of: plistMarker)
        guard let start, let end = data.range(of: endMarker, options: .backwards),
              start.lowerBound < end.upperBound else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
