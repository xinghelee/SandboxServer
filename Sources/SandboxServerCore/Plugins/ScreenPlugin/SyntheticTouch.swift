import Foundation
#if canImport(UIKit)
import UIKit

/// Private-API in-process touch synthesis: builds IOKit digitizer HID events and injects them
/// through `UIApplication._enqueueHIDEvent:`, so we can drive ANY UI (UIKit + SwiftUI, scroll views,
/// gesture recognizers) with REAL taps / swipes / drags — what public API can't do. DEBUG-only and
/// acceptable because the SDK never ships to the App Store (see [[positioning-debug-tool-no-appstore]]).
///
/// Recipe verified against Lyft's Hammer (the modern, Simulator-capable in-process reference):
///  - finger coordinates are WINDOW POINTS (not normalized),
///  - transducer type = hand (3), per-touch identifier stable across down→move→up,
///  - parent hand event tagged via `BKSHIDEventSetDigitizerInfo(parent, window._contextId, …)`,
///  - `IsDisplayIntegrated = 1` + a nonzero senderID on the parent.
/// Every private symbol/selector is resolved at runtime; if any is absent (e.g. a future OS removed
/// it) `isAvailable` is false and gestures degrade gracefully instead of crashing.
enum SyntheticTouch {

    enum Phase { case down, move, up }

    // MARK: - Constants (IOHIDEventTypes; values per Hammer/KIF)
    private static let transducerHand: UInt32 = 3
    private static let maskRange: UInt32 = 0x0001
    private static let maskTouch: UInt32 = 0x0002
    private static let maskPosition: UInt32 = 0x0004
    private static let fieldIsDisplayIntegrated: UInt32 = 0x000B0019
    private static let fingerIndex: UInt32 = 2          // "right index" slot; nonzero
    private static let senderID: UInt64 = 0x0000000123456789

    // MARK: - Private symbol resolution

    private typealias CreateDigitizerFn = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<AnyObject>?
    private typealias CreateFingerFn = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<AnyObject>?
    private typealias AppendFn = @convention(c) (AnyObject, AnyObject, UInt32) -> Void
    private typealias SetIntFn = @convention(c) (AnyObject, UInt32, Int32) -> Void
    private typealias SetSenderFn = @convention(c) (AnyObject, UInt64) -> Void
    private typealias BKSSetDigitizerInfoFn = @convention(c) (AnyObject, UInt32, Bool, Bool, CFString?, Double, Float) -> Void

    private struct Symbols {
        let createDigitizer: CreateDigitizerFn
        let createFinger: CreateFingerFn
        let append: AppendFn
        let setInt: SetIntFn
        let setSender: SetSenderFn
        let setDigitizerInfo: BKSSetDigitizerInfoFn
    }

    private static let symbols: Symbols? = {
        let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW)
        func resolve<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }
        guard
            let cd = resolve(ioKit, "IOHIDEventCreateDigitizerEvent", as: CreateDigitizerFn.self),
            let cf = resolve(ioKit, "IOHIDEventCreateDigitizerFingerEvent", as: CreateFingerFn.self),
            let ap = resolve(ioKit, "IOHIDEventAppendEvent", as: AppendFn.self),
            let si = resolve(ioKit, "IOHIDEventSetIntegerValue", as: SetIntFn.self),
            let ss = resolve(ioKit, "IOHIDEventSetSenderID", as: SetSenderFn.self),
            let bk = resolve(bbs, "BKSHIDEventSetDigitizerInfo", as: BKSSetDigitizerInfoFn.self)
        else { return nil }
        return Symbols(createDigitizer: cd, createFinger: cf, append: ap, setInt: si, setSender: ss, setDigitizerInfo: bk)
    }()

    @MainActor private static var nextTouchID: UInt32 = 1

    /// True only when every required private symbol AND injection/context selector is present.
    @MainActor static var isAvailable: Bool {
        symbols != nil
            && UIApplication.shared.responds(to: NSSelectorFromString("_enqueueHIDEvent:"))
            && (ScreenControl.keyWindow()?.responds(to: NSSelectorFromString("_contextId")) ?? false)
    }

    // MARK: - Low-level: post one finger event in a phase

    @MainActor private static func post(point: CGPoint, phase: Phase, touchID: UInt32) {
        guard let s = symbols, let window = ScreenControl.keyWindow() else { return }
        let app = unsafeBitCast(UIApplication.shared, to: HIDApplication.self)
        let contextID = unsafeBitCast(window, to: HIDWindow.self).contextId()
        let touching = phase != .up
        let childMask: UInt32 = (phase == .move) ? maskPosition : (maskRange | maskTouch)
        let ts = mach_absolute_time()

        guard let parentU = s.createDigitizer(
            kCFAllocatorDefault, ts, transducerHand, 0, 0, touching ? maskTouch : 0, 0,
            0, 0, 0, 0, 0, false, touching, 0
        ) else { return }
        let parent = parentU.takeRetainedValue()
        s.setInt(parent, fieldIsDisplayIntegrated, 1)
        s.setSender(parent, senderID)

        guard let fingerU = s.createFinger(
            kCFAllocatorDefault, ts, touchID, fingerIndex, childMask,
            Double(point.x), Double(point.y), 0, 0, 0, touching, touching, 0
        ) else { return }
        s.append(parent, fingerU.takeRetainedValue(), 0)
        s.setDigitizerInfo(parent, contextID, false, false, nil, 0, 0)
        app.enqueueHIDEvent(parent)
    }

    // MARK: - High-level gestures (main-actor; yields between events, never blocks)

    @MainActor static func tap(at point: CGPoint) async {
        let id = nextTouchID; nextTouchID &+= 1
        post(point: point, phase: .down, touchID: id)
        try? await Task.sleep(nanoseconds: 40_000_000)
        post(point: point, phase: .up, touchID: id)
    }

    @MainActor static func swipe(from: CGPoint, to: CGPoint, duration: Double) async {
        let clamped = max(0.05, min(duration, 3.0))
        let steps = max(6, Int(clamped / (1.0 / 60.0)))
        let id = nextTouchID; nextTouchID &+= 1
        let stepNanos = UInt64(clamped / Double(steps) * 1_000_000_000)
        post(point: from, phase: .down, touchID: id)
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
            post(point: p, phase: .move, touchID: id)
            try? await Task.sleep(nanoseconds: stepNanos)
        }
        post(point: to, phase: .up, touchID: id)
    }
}

/// Private UIKit selectors, reached via `unsafeBitCast` (the Hammer pattern) to keep them typed.
@objc private protocol HIDApplication {
    @objc(_enqueueHIDEvent:) func enqueueHIDEvent(_ event: AnyObject)
}
@objc private protocol HIDWindow {
    @objc(_contextId) func contextId() -> UInt32
}
#endif
