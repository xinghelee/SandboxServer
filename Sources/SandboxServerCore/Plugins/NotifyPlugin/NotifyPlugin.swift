import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE (iOS). A notification tester. Inspect the app's notification authorization + per-type
/// settings, request authorization (fire the system prompt), schedule local notifications,
/// list pending/delivered notifications, and simulate a remote push by handing an aps-style
/// payload to the app delegate's `didReceiveRemoteNotification`. All public `UserNotifications`
/// API; the remote simulation is best-effort (it invokes the delegate, it does not go through
/// APNs). Reports `supported: false` and 503s the action routes on a non-UIKit host — and the
/// notification-center calls are gated to iOS so a CLI/test host never trips the macOS
/// "no bundle" crash.
///
/// Routes:
///   GET    ""          settings + authorization status
///   POST   auth        request authorization { alert?, sound?, badge? } → { granted, status }
///   POST   local       schedule a local notification { title?, body?, …, delay? } → { id }
///   GET    pending     pending (scheduled) notification requests
///   GET    delivered   delivered notifications still in Notification Center
///   POST   remote      simulate a remote push { payload } → { delivered }
///   DELETE ""          clear (?scope=pending|delivered|all, default all)   ← destructive
struct NotifyPlugin: SandboxPlugin {
    let id = PluginID.notify

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Notifications", panelKey: "notify",
            routes: ["GET (settings)", "POST auth", "POST local", "GET pending", "GET delivered",
                     "POST remote", "DELETE (clear)"],
            channels: [],
            mcpTools: [
                .init(name: "notify_settings", title: "Notification settings",
                      description: "Authorization status and per-type settings (alert/sound/badge/lock-screen) for the app's notifications.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "notify_request_auth", title: "Request authorization",
                      description: "Request notification authorization — fires the system permission prompt. Options: alert, sound, badge (all default true). Returns whether it was granted.",
                      backingMethod: "POST", backingPathSuffix: "auth", readOnlyHint: false, destructiveHint: false),
                .init(name: "notify_send_local", title: "Send local notification",
                      description: "Schedule a local notification: title, body, subtitle, badge, sound (bool), delay (seconds; 0 = immediate), userInfo (JSON), identifier. Returns the request id.",
                      backingMethod: "POST", backingPathSuffix: "local", readOnlyHint: false, destructiveHint: false),
                .init(name: "notify_list_pending", title: "List pending",
                      description: "List pending (scheduled, not yet delivered) notification requests.",
                      backingMethod: "GET", backingPathSuffix: "pending", readOnlyHint: true, destructiveHint: false),
                .init(name: "notify_list_delivered", title: "List delivered",
                      description: "List notifications already delivered and still shown in Notification Center.",
                      backingMethod: "GET", backingPathSuffix: "delivered", readOnlyHint: true, destructiveHint: false),
                .init(name: "notify_simulate_remote", title: "Simulate remote push",
                      description: "Simulate a remote push by handing an aps-style payload to the app delegate's application(_:didReceiveRemoteNotification:fetchCompletionHandler:). Best-effort: returns delivered=false if the app implements no such handler. Does NOT go through APNs.",
                      backingMethod: "POST", backingPathSuffix: "remote", readOnlyHint: false, destructiveHint: false),
                .init(name: "notify_clear", title: "Clear notifications",
                      description: "Clear notifications. scope=pending cancels scheduled ones, delivered removes those in Notification Center, all (default) does both.",
                      backingMethod: "DELETE", backingPathSuffix: "", readOnlyHint: false, destructiveHint: true),
            ],
            limitations: [
                "Requires UIKit (iOS); on a non-UIKit host every route reports supported: false / 503.",
                "A scheduled local notification only shows as a banner per the app's UNUserNotificationCenterDelegate (foreground apps must opt in); the request is always scheduled regardless.",
                "Remote simulation invokes the app delegate in-process — it does not exercise APNs, and returns delivered: false if the app handles push via a path other than didReceiveRemoteNotification.",
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                return .json(await NotifyService.settings())
                #else
                return .json(NotifySettings.unsupported())
                #endif
            },

            HTTPRoute("POST", "auth", annotations: .write) { req, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                struct Body: Decodable { let alert: Bool?; let sound: Bool?; let badge: Bool? }
                let b = try? await req.decodeJSON(Body.self)
                let result = await NotifyService.requestAuth(alert: b?.alert ?? true, sound: b?.sound ?? true, badge: b?.badge ?? true)
                return .json(result)
                #else
                return NotifyPlugin.unsupported()
                #endif
            },

            HTTPRoute("POST", "local", annotations: .write) { req, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                guard let b = try? await req.decodeJSON(NotifyService.LocalBody.self) else {
                    return .error("bad_request", "Expected a JSON notification body.", status: 400)
                }
                do { return .json(try await NotifyService.sendLocal(b)) }
                catch { return .error("notify_failed", "\(error)", status: 500) }
                #else
                return NotifyPlugin.unsupported()
                #endif
            },

            HTTPRoute("GET", "pending", annotations: .read) { _, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                return .json(Page(items: await NotifyService.pending()))
                #else
                return NotifyPlugin.unsupported()
                #endif
            },

            HTTPRoute("GET", "delivered", annotations: .read) { _, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                return .json(Page(items: await NotifyService.delivered()))
                #else
                return NotifyPlugin.unsupported()
                #endif
            },

            HTTPRoute("POST", "remote", annotations: .write) { req, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                struct Body: Decodable { let payload: JSONValue? }
                let b = try? await req.decodeJSON(Body.self)
                guard case .object(let obj)? = b?.payload else {
                    return .error("bad_request", "Expected JSON { payload: { aps: {…}, … } }.", status: 400)
                }
                let delivered = await NotifyService.simulateRemote(obj)
                return .json(["delivered": delivered])
                #else
                return NotifyPlugin.unsupported()
                #endif
            },

            HTTPRoute("DELETE", "", annotations: .destructive) { req, _ in
                #if canImport(UIKit) && canImport(UserNotifications)
                let scope = req.query["scope"] ?? "all"
                await NotifyService.clear(scope: scope)
                return .json(["cleared": scope])
                #else
                return NotifyPlugin.unsupported()
                #endif
            },
        ]
    }

    private static func unsupported() -> SBResponse {
        .error("unsupported", "Notifications require UIKit (iOS).", status: 503)
    }

    /// Convert a decoded JSON value into a Foundation object graph for `userInfo` / push payloads.
    static func anyValue(from json: JSONValue) -> Any {
        switch json {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { anyValue(from: $0) }
        case .object(let o): return o.mapValues { anyValue(from: $0) }
        }
    }
}

/// The settings payload — shared across platforms so the wire shape is stable even off-iOS.
struct NotifySettings: Encodable, Sendable {
    let supported: Bool
    let authorizationStatus: String
    let alert: String
    let sound: String
    let badge: String
    let lockScreen: String
    let notificationCenter: String

    static func unsupported() -> NotifySettings {
        NotifySettings(supported: false, authorizationStatus: "unsupported", alert: "notSupported",
                       sound: "notSupported", badge: "notSupported", lockScreen: "notSupported",
                       notificationCenter: "notSupported")
    }
}

struct AuthResult: Encodable, Sendable { let granted: Bool; let status: String }
struct PendingNotification: Encodable, Sendable {
    let id: String; let title: String; let body: String; let triggerSeconds: Double?; let repeats: Bool
}
struct DeliveredNotification: Encodable, Sendable {
    let id: String; let title: String; let body: String; let date: Double
}

#if canImport(UIKit) && canImport(UserNotifications)
/// All the real `UserNotifications` work, isolated so the route table stays readable and the whole
/// type is excluded from non-iOS builds (where `UNUserNotificationCenter.current()` would crash a
/// non-app host).
enum NotifyService {
    private static var center: UNUserNotificationCenter { .current() }

    static func settings() async -> NotifySettings {
        let s = await center.notificationSettings()
        return NotifySettings(
            supported: true,
            authorizationStatus: authLabel(s.authorizationStatus),
            alert: settingLabel(s.alertSetting),
            sound: settingLabel(s.soundSetting),
            badge: settingLabel(s.badgeSetting),
            lockScreen: settingLabel(s.lockScreenSetting),
            notificationCenter: settingLabel(s.notificationCenterSetting)
        )
    }

    static func requestAuth(alert: Bool, sound: Bool, badge: Bool) async -> AuthResult {
        var opts: UNAuthorizationOptions = []
        if alert { opts.insert(.alert) }
        if sound { opts.insert(.sound) }
        if badge { opts.insert(.badge) }
        let granted = (try? await center.requestAuthorization(options: opts)) ?? false
        let status = await center.notificationSettings().authorizationStatus
        return AuthResult(granted: granted, status: authLabel(status))
    }

    struct LocalBody: Decodable {
        let title: String?
        let subtitle: String?
        let body: String?
        let badge: Int?
        let sound: Bool?
        let delay: Double?
        let identifier: String?
        let userInfo: JSONValue?
    }

    struct SentLocal: Encodable, Sendable { let id: String; let scheduledInSeconds: Double }

    static func sendLocal(_ b: LocalBody) async throws -> SentLocal {
        let content = UNMutableNotificationContent()
        content.title = b.title ?? "SandboxServer"
        if let subtitle = b.subtitle { content.subtitle = subtitle }
        content.body = b.body ?? ""
        if let badge = b.badge { content.badge = NSNumber(value: badge) }
        if b.sound ?? true { content.sound = .default }
        if case .object(let info)? = b.userInfo {
            content.userInfo = info.mapValues { NotifyPlugin.anyValue(from: $0) }
        }
        // A nil trigger fires immediately; a positive delay schedules it.
        let delay = max(0, b.delay ?? 0)
        let trigger: UNNotificationTrigger? = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil
        let id = b.identifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try await center.add(request)
        return SentLocal(id: id, scheduledInSeconds: delay)
    }

    static func pending() async -> [PendingNotification] {
        await center.pendingNotificationRequests().map { req in
            let interval = (req.trigger as? UNTimeIntervalNotificationTrigger)
            return PendingNotification(
                id: req.identifier,
                title: req.content.title,
                body: req.content.body,
                triggerSeconds: interval?.timeInterval,
                repeats: interval?.repeats ?? false
            )
        }
    }

    static func delivered() async -> [DeliveredNotification] {
        await center.deliveredNotifications().map { n in
            DeliveredNotification(
                id: n.request.identifier,
                title: n.request.content.title,
                body: n.request.content.body,
                date: n.date.timeIntervalSince1970
            )
        }
    }

    @MainActor
    static func simulateRemote(_ payload: [String: JSONValue]) async -> Bool {
        let userInfo = payload.mapValues { NotifyPlugin.anyValue(from: $0) }
        guard let delegate = UIApplication.shared.delegate,
              delegate.responds(to: #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))) else {
            return false
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.application?(UIApplication.shared, didReceiveRemoteNotification: userInfo) { _ in
                cont.resume()
            } ?? cont.resume()
        }
        return true
    }

    static func clear(scope: String) async {
        if scope == "pending" || scope == "all" { center.removeAllPendingNotificationRequests() }
        if scope == "delivered" || scope == "all" { center.removeAllDeliveredNotifications() }
    }

    private static func authLabel(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func settingLabel(_ s: UNNotificationSetting) -> String {
        switch s {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }
}
#endif
