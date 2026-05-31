import Foundation

/// Runtime production-environment refusal — the layer that is independent of `#if DEBUG`.
///
/// The compile-time gating (trait + `#if DEBUG && SandboxServerEnabled` + the no-op product)
/// is the primary guarantee; this is the backstop that detects a *production environment*
/// rather than trusting a build flag. On Simulator / macOS it always allows (dev contexts).
enum ReleaseGuard {
    enum Verdict: Sendable {
        case allowed
        case refused(reason: String)
    }

    static func verify() -> Verdict {
        // Only a *real* iOS/tvOS device runs the production checks; Simulator / macOS / any other
        // platform are dev contexts and always allowed.
        #if !targetEnvironment(simulator) && (os(iOS) || os(tvOS))
        let isRealAppleDevice = true
        #else
        let isRealAppleDevice = false
        #endif
        return evaluate(isRealAppleDevice: isRealAppleDevice,
                        isTestFlight: isTestFlight(),
                        hasProvisioning: hasEmbeddedProvisioning())
    }

    /// The pure decision, split out so the production-refusal matrix is unit-testable without
    /// touching `Bundle.main`.
    ///
    /// Embedded provisioning is the authoritative signal: development & ad-hoc builds ship
    /// `embedded.mobileprovision`; App Store / TestFlight distribution strips it. The `sandboxReceipt`
    /// name is NOT TestFlight-exclusive — a development build run from Xcode on a device carries one
    /// too — so it can only distinguish TestFlight from App Store *after* provisioning has ruled out
    /// a dev build. Checking the receipt first would false-positive every real-device debug session.
    static func evaluate(isRealAppleDevice: Bool, isTestFlight: Bool, hasProvisioning: Bool) -> Verdict {
        guard isRealAppleDevice else { return .allowed } // Simulator / macOS / other → dev context
        if hasProvisioning { return .allowed }           // development / ad-hoc → dev context
        if isTestFlight { return .refused(reason: "refusing to start in a TestFlight build") }
        return .refused(reason: "refusing to start in an App Store build")
    }

    /// App Store distribution strips `embedded.mobileprovision`; development/ad-hoc builds keep it.
    private static func hasEmbeddedProvisioning() -> Bool {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    }

    /// TestFlight installs carry a `sandboxReceipt` rather than a production `receipt`.
    private static func isTestFlight() -> Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
}
