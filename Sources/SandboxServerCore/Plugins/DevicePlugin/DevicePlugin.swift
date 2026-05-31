import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE. A one-shot snapshot of the device + runtime environment — the "what machine is this,
/// what OS, what locale, how much room is left" panel you reach for first when filing a bug.
/// All read-only public API. UIKit-only fields (screen geometry, safe-area insets, battery) are
/// omitted on a non-UIKit host; everything else (OS, locale, memory, disk, processor) still reports.
///
/// Route:  GET ""  → DeviceInfo
struct DevicePlugin: SandboxPlugin {
    let id = PluginID.device

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Device", panelKey: "device",
            routes: ["GET (snapshot)"],
            channels: [],
            mcpTools: [
                .init(name: "device_info", title: "Device info",
                      description: "One-shot snapshot of the device and runtime: model, OS version, locale & languages, time zone, screen size + scale + safe-area, battery, memory, free disk, processor count, thermal state, and low-power mode.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
            ],
            limitations: [
                "Screen geometry, safe-area insets, and battery require UIKit (iOS); they are null on a non-UIKit host.",
                "Battery level/state report only when battery monitoring is available (often -1 / unknown on the Simulator).",
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                .json(await DeviceInfo.capture())
            },
        ]
    }
}

struct DeviceInfo: Encodable, Sendable {
    struct App: Encodable, Sendable {
        let bundleId: String?
        let name: String?
        let version: String?
        let build: String?
    }
    struct OS: Encodable, Sendable {
        let name: String
        let version: String
        let platform: String
    }
    struct Hardware: Encodable, Sendable {
        let model: String?
        let machine: String
        let name: String?
        let idiom: String?
    }
    struct Locale_: Encodable, Sendable {
        let identifier: String
        let languages: [String]
        let region: String?
        let timeZone: String
        let utcOffsetSeconds: Int
        let uses24Hour: Bool
    }
    struct Screen: Encodable, Sendable {
        let width: Double
        let height: Double
        let scale: Double
        let nativeScale: Double
        let safeArea: [String: Double]?
    }
    struct Battery: Encodable, Sendable {
        let level: Double
        let state: String
        let lowPowerMode: Bool
    }
    struct Memory: Encodable, Sendable {
        let physicalMB: Double
    }
    struct Disk: Encodable, Sendable {
        let totalMB: Double?
        let availableMB: Double?
    }
    struct Process_: Encodable, Sendable {
        let processorCount: Int
        let activeProcessorCount: Int
        let thermalState: String
        let uptimeSeconds: Double
        let arguments: [String]
    }

    let app: App
    let os: OS
    let hardware: Hardware
    let locale: Locale_
    let screen: Screen?
    let battery: Battery?
    let memory: Memory
    let disk: Disk
    let process: Process_

    static func capture() async -> DeviceInfo {
        let info = Bundle.main.infoDictionary
        let pi = ProcessInfo.processInfo

        let app = App(
            bundleId: Bundle.main.bundleIdentifier,
            name: (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String,
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )

        let tz = TimeZone.current
        let locale = Locale.current
        let loc = Locale_(
            identifier: locale.identifier,
            languages: Locale.preferredLanguages,
            region: regionCode(locale),
            timeZone: tz.identifier,
            utcOffsetSeconds: tz.secondsFromGMT(),
            uses24Hour: !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false)
        )

        let memory = Memory(physicalMB: Double(pi.physicalMemory) / 1_048_576)
        let disk = diskInfo()
        let process = Process_(
            processorCount: pi.processorCount,
            activeProcessorCount: pi.activeProcessorCount,
            thermalState: thermalLabel(pi.thermalState),
            uptimeSeconds: pi.systemUptime,
            arguments: pi.arguments
        )

        let osVersion: String = {
            let v = pi.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }()

        let osPlatform: String = {
            #if os(iOS)
            return "iOS"
            #elseif os(macOS)
            return "macOS"
            #elseif os(tvOS)
            return "tvOS"
            #elseif os(watchOS)
            return "watchOS"
            #else
            return "unknown"
            #endif
        }()

        #if canImport(UIKit)
        let ui = await MainActor.run { () -> (OS, Hardware, Screen?, Battery?) in
            let device = UIDevice.current
            let os = OS(name: device.systemName, version: device.systemVersion, platform: osPlatform)
            let hw = Hardware(model: device.model, machine: machineIdentifier(), name: device.name, idiom: idiomLabel(device.userInterfaceIdiom))
            let screen = captureScreen()
            device.isBatteryMonitoringEnabled = true
            let battery = Battery(
                level: Double(device.batteryLevel),
                state: batteryLabel(device.batteryState),
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            return (os, hw, screen, battery)
        }
        return DeviceInfo(app: app, os: ui.0, hardware: ui.1, locale: loc,
                          screen: ui.2, battery: ui.3, memory: memory, disk: disk, process: process)
        #else
        let os = OS(name: osPlatform, version: osVersion, platform: osPlatform)
        let hw = Hardware(model: nil, machine: machineIdentifier(), name: Host.current().localizedName, idiom: nil)
        return DeviceInfo(app: app, os: os, hardware: hw, locale: loc,
                          screen: nil, battery: nil, memory: memory, disk: disk, process: process)
        #endif
    }

    private static func regionCode(_ locale: Locale) -> String? {
        if #available(iOS 16, macOS 13, *) { return locale.region?.identifier }
        return locale.regionCode
    }

    private static func diskInfo() -> Disk {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = values?.volumeTotalCapacity.map { Double($0) / 1_048_576 }
        let avail = values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_048_576 }
        return Disk(totalMB: total, availableMB: avail)
    }

    private static func machineIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine
    }

    private static func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

#if canImport(UIKit)
@MainActor private func captureScreen() -> DeviceInfo.Screen {
    let screen = UIScreen.main
    let bounds = screen.bounds
    var safeArea: [String: Double]?
    if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first {
        let i = window.safeAreaInsets
        safeArea = ["top": i.top, "bottom": i.bottom, "left": i.left, "right": i.right]
    }
    return DeviceInfo.Screen(
        width: bounds.width, height: bounds.height,
        scale: screen.scale, nativeScale: screen.nativeScale, safeArea: safeArea
    )
}

@MainActor private func idiomLabel(_ idiom: UIUserInterfaceIdiom) -> String {
    switch idiom {
    case .phone: return "phone"
    case .pad: return "pad"
    case .tv: return "tv"
    case .carPlay: return "carPlay"
    case .mac: return "mac"
    case .vision: return "vision"
    default: return "unspecified"
    }
}

@MainActor private func batteryLabel(_ state: UIDevice.BatteryState) -> String {
    switch state {
    case .charging: return "charging"
    case .full: return "full"
    case .unplugged: return "unplugged"
    default: return "unknown"
    }
}
#endif
