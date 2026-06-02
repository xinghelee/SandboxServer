import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage(SettingsKey.username) private var username = ""
    @AppStorage(SettingsKey.sort) private var sortRaw = TaskSort.created.rawValue
    @AppStorage(SettingsKey.hideCompleted) private var hideCompleted = false

    @State private var exportMessage: String?
    @State private var confirmingClear = false

    private var lastSync: Date? {
        UserDefaults.standard.object(forKey: SettingsKey.lastSync) as? Date
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $username)
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(TaskSort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Hide completed", isOn: $hideCompleted)
                } header: {
                    Text("Preferences")
                } footer: {
                    Text("These are plain `UserDefaults` (keys prefixed `tasks.`) — read and edit them live in the console's Defaults panel.")
                }

                ConsoleSection(console: store.console)

                Section {
                    LabeledContent("Tasks", value: "\(store.tasks.count)")
                    if let lastSync {
                        LabeledContent("Last sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        if let url = store.exportJSON() {
                            exportMessage = "Wrote \(url.lastPathComponent) to Documents/exports/"
                        }
                    } label: {
                        Label("Export tasks to JSON", systemImage: "square.and.arrow.up")
                    }
                    if let exportMessage {
                        Text(exportMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await store.reimport() }
                    } label: {
                        Label("Re-import sample tasks", systemImage: "arrow.down.circle")
                    }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear all tasks", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export writes a real file (Files panel); re-import and sync make real network requests (Network panel).")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all tasks and notes?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { store.clearAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// Shows the embedded debug server's state. Split out so it can `@ObservedObject` the console
/// (a nested object on the store) and refresh when the server finishes starting.
private struct ConsoleSection: View {
    @ObservedObject var console: DebugConsole

    var body: some View {
        Section {
            LabeledContent("Status", value: console.status)
            if let url = console.url {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Console URL").font(.caption).foregroundStyle(.secondary)
                    Text(url)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Debug console")
        } footer: {
            Text("Open this URL from this Mac or another device on the same trusted Wi-Fi. No token required by default.")
        }
    }
}
