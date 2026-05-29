// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SandboxServer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11), // host/CI build + macOS host-app debugging; iOS is the primary target.
    ],
    products: [
        // The recommended integration: a Release-safe facade gated by the trait below.
        .library(name: "SandboxServer", targets: ["SandboxServer"]),
        .library(name: "SandboxServerNoOp", targets: ["SandboxServerNoOp"]),
        // The public contract — depend on this to author custom plugins.
        .library(name: "SandboxServerAPI", targets: ["SandboxServerAPI"]),
        // The real server, exposed for tooling/tests/demos that link it explicitly (e.g. on a
        // toolchain without trait support). It is NOT gated, so do not ship it in a Release app —
        // production apps use the `SandboxServer` facade + `SandboxServerEnabled` trait instead.
        .library(name: "SandboxServerCore", targets: ["SandboxServerCore"]),
    ],
    traits: [
        // No traits enabled by default — the *safe* (no-op) path is the default.
        .default(enabledTraits: []),
        .trait(
            name: "SandboxServerEnabled",
            description: "Link the real debug server (SandboxServerCore) instead of the inert no-op stub."
        ),
    ],
    targets: [
        // Dependency-free public contract. No Network.framework import.
        .target(name: "SandboxServerAPI"),

        // Always-linked facade. Forwards to Core (DEBUG + trait) or NoOp (everything else).
        .target(
            name: "SandboxServer",
            dependencies: [
                "SandboxServerAPI",
                "SandboxServerNoOp",
                .target(name: "SandboxServerCore", condition: .when(traits: ["SandboxServerEnabled"])),
            ]
        ),

        // Inert mirror of the public API, linked in Release / disabled builds.
        .target(name: "SandboxServerNoOp", dependencies: ["SandboxServerAPI"]),

        // The real debug server: transport, router, hub, registry, and the built-in plugins.
        .target(
            name: "SandboxServerCore",
            dependencies: ["SandboxServerAPI", "SandboxServerSystemSQLite"],
            resources: [.copy("Resources/web")]
        ),

        // OS libsqlite3, bridged with zero third-party dependency (consumed by Core's DB plugin in v2).
        .systemLibrary(name: "SandboxServerSystemSQLite"),

        // A macOS host that runs the server for local development / manual browser testing.
        .executableTarget(
            name: "SandboxServerDevHost",
            dependencies: [
                "SandboxServer", "SandboxServerAPI",
                .target(name: "SandboxServerCore", condition: .when(traits: ["SandboxServerEnabled"])),
            ]
        ),

        // Transport/codec/router/auth unit tests + the end-to-end server smoke test.
        .testTarget(
            name: "SandboxServerCoreTests",
            dependencies: [
                "SandboxServerAPI",
                "SandboxServerNoOp",
                .target(name: "SandboxServerCore", condition: .when(traits: ["SandboxServerEnabled"])),
            ]
        ),
    ]
)
