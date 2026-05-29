import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// LIVE on iOS. Mirrors the app's key window to the browser as JPEG frames and lets the operator
/// drive the UI: semantic taps (focus a field / fire a control / activate an a11y element), text
/// entry into the focused field, and paste. Public-API only — so it can't synthesise arbitrary
/// pixel-level gestures (swipe/drag/pinch); those need private touch synthesis and are a later,
/// DEBUG-gated option. Reports `supported = false` and 503s its capture routes on non-UIKit hosts.
final class ScreenPlugin: SandboxPlugin, @unchecked Sendable {
    let id = PluginID.screen

    init() {}

    private struct ScreenInfo: Encodable { let supported: Bool; let width, height, scale: Double }
    private struct SnapshotDTO: Encodable { let jpegBase64: String; let width, height: Double }
    private struct ActionResult: Encodable { let ok: Bool; let detail: String }
    private struct TapCmd: Decodable { let x, y: Double }
    private struct TextCmd: Decodable { let text: String; let clear: Bool? }

    var capabilities: PluginCapabilities {
        PluginCapabilities(
            id: id.rawValue, version: "1.0.0", title: "Screen", panelKey: "screen",
            routes: ["GET (info)", "GET frame", "GET snapshot", "POST tap", "POST text", "POST paste"],
            mcpTools: [
                .init(name: "ui_info", title: "Screen info",
                      description: "Key window size + scale, and whether screen control is supported on this device.",
                      backingMethod: "GET", backingPathSuffix: "", readOnlyHint: true, destructiveHint: false),
                .init(name: "ui_screenshot", title: "Screenshot",
                      description: "Capture the app's current screen as a JPEG image.",
                      backingMethod: "GET", backingPathSuffix: "snapshot", readOnlyHint: true, destructiveHint: false),
                .init(name: "ui_tap", title: "Tap",
                      description: "Tap at window point {x,y}: focuses a text field, fires a UIControl, or activates the accessible element there.",
                      backingMethod: "POST", backingPathSuffix: "tap", readOnlyHint: false, destructiveHint: false),
                .init(name: "ui_type", title: "Type text",
                      description: "Insert text into the focused field (tap a field first). Optional clear=true replaces existing text.",
                      backingMethod: "POST", backingPathSuffix: "text", readOnlyHint: false, destructiveHint: false),
                .init(name: "ui_paste", title: "Paste text",
                      description: "Set the pasteboard and paste into the focused field.",
                      backingMethod: "POST", backingPathSuffix: "paste", readOnlyHint: false, destructiveHint: false),
            ]
        )
    }

    func routes() -> [HTTPRoute] {
        [
            HTTPRoute("GET", "", annotations: .read) { _, _ in
                let info = await ScreenControl.info()
                return .json(ScreenInfo(supported: ScreenControl.isSupported,
                                        width: info?.w ?? 0, height: info?.h ?? 0, scale: info?.scale ?? 0))
            },
            // Raw JPEG for the live browser mirror (polled). 503 when there's no window to capture.
            HTTPRoute("GET", "frame", annotations: RouteAnnotations(readOnly: true, streaming: true)) { req, _ in
                guard let frame = await ScreenControl.snapshot(
                    maxWidth: Int(req.query["maxWidth"] ?? "") ?? 420,
                    quality: Double(req.query["quality"] ?? "") ?? 0.5
                ) else { return Self.unavailable }
                return SBResponse(status: 200, headers: ["Cache-Control": "no-store"],
                                  body: .bytes(frame.data, contentType: "image/jpeg"))
            },
            // Base64 JPEG for MCP (the bridge surfaces it as an image content block).
            HTTPRoute("GET", "snapshot", annotations: .read) { req, _ in
                guard let frame = await ScreenControl.snapshot(
                    maxWidth: Int(req.query["maxWidth"] ?? "") ?? 600,
                    quality: Double(req.query["quality"] ?? "") ?? 0.6
                ) else { return Self.unavailable }
                return .json(SnapshotDTO(jpegBase64: frame.data.base64EncodedString(),
                                         width: frame.width, height: frame.height))
            },
            HTTPRoute("POST", "tap", annotations: .write) { req, _ in
                let cmd = try await req.decodeJSON(TapCmd.self)
                let r = await ScreenControl.tap(x: cmd.x, y: cmd.y)
                return .json(ActionResult(ok: r.ok, detail: r.detail))
            },
            HTTPRoute("POST", "text", annotations: .write) { req, _ in
                let cmd = try await req.decodeJSON(TextCmd.self)
                let r = await ScreenControl.typeText(cmd.text, clear: cmd.clear ?? false)
                return .json(ActionResult(ok: r.ok, detail: r.detail))
            },
            HTTPRoute("POST", "paste", annotations: .write) { req, _ in
                let cmd = try await req.decodeJSON(TextCmd.self)
                let r = await ScreenControl.paste(cmd.text)
                return .json(ActionResult(ok: r.ok, detail: r.detail))
            },
        ]
    }

    private static var unavailable: SBResponse {
        .error("screen_unavailable", "No key window to capture — screen control is iOS-only.", status: 503)
    }
}
