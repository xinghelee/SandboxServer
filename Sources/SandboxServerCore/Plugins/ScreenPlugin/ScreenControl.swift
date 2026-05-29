import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Captures the app's key window and drives it with public, App-Store-safe UIKit APIs:
/// screenshot (`UIGraphicsImageRenderer`), semantic tap (`hitTest` → control / text-field focus /
/// `accessibilityActivate`), text entry into the first responder (`UIKeyInput`), and paste
/// (`UIPasteboard` + `paste(_:)`). Pixel-level gestures (swipe/drag/pinch) need private touch
/// synthesis and are intentionally NOT here yet. All UIKit work is MainActor-isolated.
///
/// On non-UIKit platforms (the macOS test/dev host) every method is an inert stub so the package
/// still builds and the plugin reports `supported = false`.
enum ScreenControl {

    struct Frame: Sendable { let data: Data; let width: Double; let height: Double }
    struct Action: Sendable { let ok: Bool; let detail: String }

    #if canImport(UIKit)
    static var isSupported: Bool { true }

    @MainActor static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    @MainActor static func info() -> (w: Double, h: Double, scale: Double)? {
        guard let win = keyWindow() else { return nil }
        let scale = win.traitCollection.displayScale > 0 ? win.traitCollection.displayScale : 2
        return (Double(win.bounds.width), Double(win.bounds.height), Double(scale))
    }

    @MainActor static func snapshot(maxWidth: Int, quality: Double) -> Frame? {
        guard let win = keyWindow() else { return nil }
        let bounds = win.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let displayScale = win.traitCollection.displayScale > 0 ? win.traitCollection.displayScale : 2
        let fmt = UIGraphicsImageRendererFormat()
        // Downscale so a phone-sized window fits a browser frame cheaply.
        fmt.scale = maxWidth > 0 ? min(CGFloat(maxWidth) / bounds.width, displayScale) : displayScale
        if fmt.scale < 0.1 { fmt.scale = 0.1 }
        fmt.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: fmt).image { _ in
            win.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        let q = CGFloat(min(max(quality, 0.1), 1.0))
        guard let jpeg = image.jpegData(compressionQuality: q) else { return nil }
        return Frame(data: jpeg, width: Double(bounds.width), height: Double(bounds.height))
    }

    @MainActor static func tap(x: Double, y: Double) -> Action {
        guard let win = keyWindow() else { return Action(ok: false, detail: "no key window") }
        guard let hit = win.hitTest(CGPoint(x: x, y: y), with: nil) else {
            return Action(ok: false, detail: "nothing at (\(Int(x)),\(Int(y)))")
        }
        // Prefer text-field focus, then a UIControl action, walking up the hit chain.
        var view: UIView? = hit
        while let cur = view {
            if cur is UITextField || cur is UITextView {
                cur.becomeFirstResponder()
                return Action(ok: true, detail: "focused \(type(of: cur))")
            }
            if let control = cur as? UIControl, control.isEnabled {
                control.sendActions(for: .touchUpInside)
                return Action(ok: true, detail: "UIControl \(type(of: control)) .touchUpInside")
            }
            view = cur.superview
        }
        // SwiftUI buttons / accessible elements aren't UIViews — find the deepest accessibility
        // element whose frame contains the point and fire its activation action. (For a fullscreen
        // window, window points == screen points, which is what accessibilityFrame uses.)
        if activateAccessibleElement(at: CGPoint(x: x, y: y), root: win) {
            return Action(ok: true, detail: "accessibility-activated element at (\(Int(x)),\(Int(y)))")
        }
        return Action(ok: false, detail: "hit \(type(of: hit)) — no actionable control/element")
    }

    /// Depth-first search for the front-most accessibility element under `point` that can be
    /// activated. Recurses subviews and accessibility-container elements; activates the deepest hit.
    @MainActor private static func activateAccessibleElement(at point: CGPoint, root: NSObject) -> Bool {
        var children: [NSObject] = []
        if let view = root as? UIView { children.append(contentsOf: view.subviews.map { $0 as NSObject }) }
        if let elements = root.accessibilityElements as? [NSObject] {
            children.append(contentsOf: elements)
        } else {
            let count = root.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for i in 0..<count {
                    if let element = root.accessibilityElement(at: i) as? NSObject { children.append(element) }
                }
            }
        }
        for child in children.reversed() {
            if activateAccessibleElement(at: point, root: child) { return true }
        }
        if root.isAccessibilityElement, root.accessibilityFrame.contains(point), root.accessibilityActivate() {
            return true
        }
        return false
    }

    @MainActor static func typeText(_ text: String, clear: Bool) -> Action {
        guard let responder = currentFirstResponder() else {
            return Action(ok: false, detail: "no focused field — tap a text field first")
        }
        if clear {
            if let field = responder as? UITextField { field.text = "" }
            else if let view = responder as? UITextView { view.text = "" }
        }
        guard let input = responder as? UIKeyInput else {
            return Action(ok: false, detail: "\(type(of: responder)) is not text-editable")
        }
        input.insertText(text)
        return Action(ok: true, detail: "typed \(text.count) chars into \(type(of: responder))")
    }

    @MainActor static func paste(_ text: String) -> Action {
        UIPasteboard.general.string = text
        guard let responder = currentFirstResponder() else {
            return Action(ok: false, detail: "pasteboard set, but no focused field to paste into")
        }
        if responder.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil) {
            responder.paste(nil)
            return Action(ok: true, detail: "pasted into \(type(of: responder))")
        }
        if let input = responder as? UIKeyInput {
            input.insertText(text)
            return Action(ok: true, detail: "inserted into \(type(of: responder))")
        }
        return Action(ok: false, detail: "pasteboard set, but \(type(of: responder)) can't paste")
    }

    @MainActor private static func currentFirstResponder() -> UIResponder? {
        FirstResponderBox.shared.responder = nil
        // sendAction(to: nil) walks the responder chain; the action lands on the first responder.
        UIApplication.shared.sendAction(#selector(UIResponder.sandbox_captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return FirstResponderBox.shared.responder
    }
    #else
    static var isSupported: Bool { false }
    @MainActor static func info() -> (w: Double, h: Double, scale: Double)? { nil }
    @MainActor static func snapshot(maxWidth: Int, quality: Double) -> Frame? { nil }
    @MainActor static func tap(x: Double, y: Double) -> Action { Action(ok: false, detail: "screen control is iOS-only") }
    @MainActor static func typeText(_ text: String, clear: Bool) -> Action { Action(ok: false, detail: "screen control is iOS-only") }
    @MainActor static func paste(_ text: String) -> Action { Action(ok: false, detail: "screen control is iOS-only") }
    #endif
}

#if canImport(UIKit)
/// MainActor-isolated holder for the responder-chain capture trick.
@MainActor private final class FirstResponderBox {
    static let shared = FirstResponderBox()
    var responder: UIResponder?
}

private extension UIResponder {
    @MainActor @objc func sandbox_captureFirstResponder(_ sender: Any) {
        FirstResponderBox.shared.responder = self
    }
}
#endif
