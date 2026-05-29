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
        #if targetEnvironment(simulator)
        return .allowed
        #elseif os(macOS)
        return .allowed
        #elseif os(iOS) || os(tvOS)
        if isTestFlight() {
            return .refused(reason: "refusing to start in a TestFlight build")
        }
        if !hasEmbeddedProvisioning() {
            return .refused(reason: "refusing to start in an App Store build")
        }
        return .allowed
        #else
        return .allowed
        #endif
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
