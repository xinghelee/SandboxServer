import Foundation

private final class BundleToken {}

/// Resolves the bundled web-console directory across both distribution channels:
/// SPM (`Bundle.module`, populated by `.copy("Resources/web")`) and CocoaPods
/// (`SandboxServerWebConsole.bundle` produced by `resource_bundles`).
enum ResourceBundle {
    /// URL of the `web/` directory containing `index.html` + `assets/`, or `nil` if unbundled.
    static var webRoot: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "web", withExtension: nil)
        #else
        let owning = Bundle(for: BundleToken.self)
        if let bundleURL = owning.url(forResource: "SandboxServerWebConsole", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL),
           let web = bundle.url(forResource: "web", withExtension: nil) {
            return web
        }
        return owning.url(forResource: "web", withExtension: nil)
        #endif
    }
}
