import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One node of the captured view tree. Frame is in WINDOW coordinates so the browser can stack
/// every node in the same space for the 3D exploded view.
struct HierarchyNode: Encodable, Sendable {
    let id: Int
    let cls: String
    let depth: Int
    let x, y, w, h: Double
    let alpha: Double
    let hidden: Bool
    let label: String?
    let bg: String?
    /// base64 PNG of this view's own rendered content (leaf / content views only), when requested.
    let thumb: String?
    let children: [HierarchyNode]
}

struct HierarchyDTO: Encodable, Sendable {
    let supported: Bool
    let width, height: Double
    let nodeCount: Int
    let truncated: Bool
    let root: HierarchyNode?
}

/// Walks the key window's `UIView` tree into a `HierarchyDTO`. Bounded by `maxDepth` and `maxNodes`
/// so a pathological tree can't produce an unbounded payload. UIKit-gated; a no-op stub elsewhere.
enum ViewHierarchy {
    #if canImport(UIKit)
    static var isSupported: Bool { true }

    @MainActor static func capture(maxDepth: Int, maxNodes: Int, thumbs: Bool, maxThumbs: Int) -> HierarchyDTO {
        guard let win = ScreenControl.keyWindow() else {
            return HierarchyDTO(supported: false, width: 0, height: 0, nodeCount: 0, truncated: false, root: nil)
        }
        var count = 0
        var thumbCount = 0
        var truncated = false

        func build(_ view: UIView, _ depth: Int) -> HierarchyNode {
            let id = count
            count += 1
            let f = view.convert(view.bounds, to: win)
            var kids: [HierarchyNode] = []
            if depth < maxDepth {
                for sub in view.subviews {
                    if count >= maxNodes { truncated = true; break }
                    kids.append(build(sub, depth + 1))
                }
            } else if !view.subviews.isEmpty {
                truncated = true
            }
            // Snapshot the OWN content of leaf / content views only — containers stay wireframe, so
            // we don't repeat the same pixels on every ancestor slab. Bounded by maxThumbs.
            var thumb: String?
            if thumbs, thumbCount < maxThumbs, !view.isHidden, view.alpha > 0.05,
               view.subviews.isEmpty || isContentView(view) {
                if let t = thumbnail(view) { thumb = t; thumbCount += 1 }
            }
            return HierarchyNode(
                id: id, cls: String(describing: type(of: view)), depth: depth,
                x: Double(f.minX), y: Double(f.minY), w: Double(f.width), h: Double(f.height),
                alpha: Double(view.alpha), hidden: view.isHidden,
                label: label(for: view), bg: hex(view.backgroundColor), thumb: thumb, children: kids
            )
        }

        let root = build(win, 0)
        return HierarchyDTO(
            supported: true, width: Double(win.bounds.width), height: Double(win.bounds.height),
            nodeCount: count, truncated: truncated, root: root
        )
    }

    private static func isContentView(_ v: UIView) -> Bool {
        v is UILabel || v is UIImageView || v is UIButton || v is UITextField || v is UITextView
    }

    /// PNG (alpha-preserving) of the view's own rendered content, downscaled and capped in size.
    @MainActor private static func thumbnail(_ v: UIView) -> String? {
        let b = v.bounds
        guard b.width >= 8, b.height >= 8 else { return nil }
        let displayScale = v.window?.traitCollection.displayScale ?? 2
        let fmt = UIGraphicsImageRendererFormat()
        // Capture at ~640px on the long edge (capped at the device scale) so slabs stay crisp
        // when the browser scales them up; small content views render at full device scale.
        fmt.scale = max(0.5, min(640 / max(b.width, b.height), displayScale))
        fmt.opaque = false
        let image = UIGraphicsImageRenderer(bounds: b, format: fmt).image { _ in
            _ = v.drawHierarchy(in: b, afterScreenUpdates: false)
        }
        return image.pngData()?.base64EncodedString()
    }

    @MainActor private static func label(for view: UIView) -> String? {
        let raw: String?
        if let l = view as? UILabel { raw = l.text }
        else if let b = view as? UIButton { raw = b.title(for: .normal) ?? b.titleLabel?.text }
        else if let tf = view as? UITextField { raw = (tf.text?.isEmpty == false) ? tf.text : tf.placeholder }
        else if let tv = view as? UITextView { raw = tv.text }
        else { raw = view.accessibilityLabel }
        guard let s = raw, !s.isEmpty else { return nil }
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    private static func hex(_ color: UIColor?) -> String? {
        guard let color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0.01 else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    #else
    static var isSupported: Bool { false }
    @MainActor static func capture(maxDepth: Int, maxNodes: Int, thumbs: Bool, maxThumbs: Int) -> HierarchyDTO {
        HierarchyDTO(supported: false, width: 0, height: 0, nodeCount: 0, truncated: false, root: nil)
    }
    #endif
}
