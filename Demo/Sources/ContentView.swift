import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ServerModel

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    statusRow
                    if case .running = model.state {
                        labeled("Console URL", model.consoleURL, mono: true)
                        labeled("Token", model.token, mono: true)
                        Text("Open the Console URL in a browser on this Mac (the Simulator shares localhost).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if case .disabled = model.state {
                        Text("Linked the no-op stub — the `SandboxServerEnabled` trait is not enabled for this build.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if case .failed(let reason) = model.state {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Remote control demo") {
                    Button {
                        model.bump()
                    } label: {
                        Label("Tap me — count: \(model.tapCount)", systemImage: "hand.tap")
                    }
                    .disabled(!model.isRunning)
                    TextField("Type into me from the browser", text: $model.demoText)
                        .textFieldStyle(.roundedBorder)
                    Text("From the Screen panel: tap this button, or focus this field and type/paste.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Scroll test (swipe me from the browser)") {
                    ForEach(1...30, id: \.self) { i in
                        Text("Row \(i) — swipe up on the screen mirror to scroll")
                            .font(.footnote)
                    }
                }

                Section("Live network capture") {
                    labeled("Requests fired", "\(model.requestCount)")
                    labeled("Last", model.lastRequest, mono: true)
                    Button {
                        model.fireLocalBatch(100)
                    } label: {
                        Label("Fire 100 requests", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(!model.isRunning)
                    Button {
                        model.fireSampleRequest()
                    } label: {
                        Label("Fire external requests", systemImage: "globe")
                    }
                    .disabled(!model.isRunning)
                }

                Section("Logs") {
                    labeled("Lines emitted", "\(model.logCount)")
                    Button {
                        model.emitLogs(200)
                    } label: {
                        Label("Emit 200 log lines", systemImage: "text.append")
                    }
                    .disabled(!model.isRunning)
                    Text("A big `events` table (~6k rows) and a ~250 KB file (`data/large.log`) are seeded too — for the Databases and Files panels.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SandboxServer")
        }
    }

    private var statusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            Text(model.statusText)
                .foregroundStyle(model.statusColor)
                .fontWeight(.semibold)
        }
    }

    private func labeled(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .textSelection(.enabled)
        }
    }
}

extension ServerModel {
    var isRunning: Bool { if case .running = state { return true } else { return false } }

    var statusText: String {
        switch state {
        case .starting: return "starting…"
        case .running: return "running"
        case .disabled: return "disabled (no-op)"
        case .failed: return "failed"
        }
    }

    var statusColor: Color {
        switch state {
        case .running: return .green
        case .starting: return .secondary
        case .disabled: return .orange
        case .failed: return .red
        }
    }
}
