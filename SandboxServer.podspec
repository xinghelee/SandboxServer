Pod::Spec.new do |s|
  s.name             = 'SandboxServer'
  s.version          = '0.1.0'
  s.summary          = 'In-app debug server: browse the iOS sandbox, databases, and network traffic from a browser — with MCP tools for AI.'
  s.description      = <<-DESC
    SandboxServer embeds an HTTP + WebSocket server inside a host iOS app (DEBUG only). A browser
    on the same LAN gets a web console for the sandbox file system, databases, and live network
    capture; the same on-device API is also consumed by a standalone MCP bridge so AI tools can
    drive it. The server is off by default, requires an explicit start() and a per-session token,
    binds loopback by default, and is physically absent from Release/App Store builds.
  DESC
  s.homepage         = 'https://github.com/xinghelee/SandboxServer'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'SandboxServer' => 'hi@xinghelee.com' }
  s.source           = { :git => 'https://github.com/xinghelee/SandboxServer.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_versions   = ['5.9', '6.0']

  # IMPORTANT — integrate DEBUG-only so the server and its assets never ship in Release:
  #
  #   pod 'SandboxServer', :configurations => ['Debug']
  #
  # CocoaPods compiles a pod as ONE module, so all targets are folded together here and the
  # inter-module `import` statements are guarded behind `#if SWIFT_PACKAGE` in source. The flag
  # below makes the facade select the real core (the SPM `SandboxServerEnabled` trait equivalent).
  s.source_files = [
    'Sources/SandboxServerAPI/**/*.swift',
    'Sources/SandboxServerNoOp/**/*.swift',
    'Sources/SandboxServerCore/**/*.swift',
    'Sources/SandboxServer/**/*.swift',
  ]
  # The directory form (no glob) copies `web/` itself into the bundle, preserving hierarchy —
  # ResourceBundle.webRoot expects `SandboxServerWebConsole.bundle/web/index.html`.
  s.resource_bundles = {
    'SandboxServerWebConsole' => ['Sources/SandboxServerCore/Resources/web']
  }

  s.frameworks = 'Foundation', 'Network', 'CryptoKit'
  s.libraries  = 'sqlite3'

  s.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '-D SandboxServerEnabled'
  }
end
