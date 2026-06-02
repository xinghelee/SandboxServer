import Foundation
import SwiftUI

/// The app's single source of truth, wiring the SQLite store, the on-disk notes, and the network
/// API together behind a small `ObservableObject`. Everything runs on the main actor — the data
/// volumes are tiny — which keeps the SQLite connection and `UIKit`-adjacent state race-free.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var isSyncing = false
    /// A short transient line surfaced at the top of the list (import result, sync result, …).
    @Published var banner: String?

    /// The embedded debug server. Exposed so the Settings tab can show its console URL/status.
    let console = DebugConsole()

    private let db = TaskDatabase()
    private let notes = NoteStore()
    private let api = TaskAPI()

    // MARK: - Lifecycle

    /// Boots the debug server, then loads tasks — importing a sample batch the first time the
    /// store is empty (falling back to local starter tasks when offline).
    func bootstrap() async {
        await console.start()
        if db?.isEmpty ?? true {
            await importSeed()
        }
        reload()
    }

    func reload() {
        tasks = db?.fetchAll() ?? []
    }

    // MARK: - Mutations (every one is a real DB write the Databases panel reflects)

    func add(title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let id = db?.insert(title: title, priority: .normal) else { return }
        console.log("added task #\(id): \(title)", category: "db")
        reload()
    }

    func toggle(_ task: TaskItem) {
        db?.setDone(id: task.id, done: !task.isDone)
        console.log("toggled task #\(task.id) → \(task.isDone ? "open" : "done")", category: "db")
        reload()
    }

    func delete(_ task: TaskItem) {
        db?.delete(id: task.id)
        notes?.delete(id: task.id)
        console.log("deleted task #\(task.id)", level: "warn", category: "db")
        reload()
    }

    /// Persists the edits made in the detail screen: title / priority / done go to the DB row, the
    /// free-text note goes to its own file, and the cached summary is written back to the row.
    func commit(_ task: TaskItem, note: String) {
        var updated = task
        updated.noteSummary = notes?.save(id: task.id, text: note) ?? ""
        db?.update(updated)
        console.log("saved task #\(task.id) (note \(note.isEmpty ? "cleared" : "\(note.count) chars"))", category: "files")
        reload()
    }

    func note(for task: TaskItem) -> String {
        notes?.load(id: task.id) ?? ""
    }

    // MARK: - Network

    /// Pushes every task to the (fake) backend — real outbound HTTP the Network panel captures and
    /// can Replay. Records the time of the last sync in `UserDefaults` (visible in Defaults).
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        console.log("sync started — pushing \(tasks.count) tasks", category: "net")
        var ok = 0
        for task in tasks {
            if let status = await api.push(task), (200..<300).contains(status) { ok += 1 }
        }
        UserDefaults.standard.set(Date(), forKey: SettingsKey.lastSync)
        banner = "Synced \(ok)/\(tasks.count) tasks"
        console.log("sync finished — \(ok)/\(tasks.count) accepted", category: "net")
    }

    /// Force a fresh import from the sample API (used by the Settings "Re-import" button).
    func reimport() async {
        db?.deleteAll()
        notes?.deleteAll()
        await importSeed()
        reload()
    }

    // MARK: - Maintenance

    func exportJSON() -> URL? {
        let url = notes?.exportJSON(tasks)
        if let url { console.log("exported \(tasks.count) tasks → \(url.lastPathComponent)", category: "files") }
        return url
    }

    func clearAll() {
        db?.deleteAll()
        notes?.deleteAll()
        console.log("cleared all tasks + notes", level: "warn", category: "db")
        reload()
    }

    // MARK: - Seeding (one real network fetch; local fallback when offline)

    private func importSeed() async {
        do {
            let todos = try await api.fetchSeedTodos(limit: 20)
            for todo in todos {
                db?.insert(title: todo.title, priority: .normal, isDone: todo.completed)
            }
            banner = "Imported \(todos.count) tasks from the sample API"
            console.log("seeded \(todos.count) tasks from jsonplaceholder", category: "net")
        } catch {
            for (title, priority) in Self.starterTasks {
                db?.insert(title: title, priority: priority)
            }
            banner = "Offline — added \(Self.starterTasks.count) starter tasks"
            console.log("seed import failed (\(error.localizedDescription)); used local starters", level: "warn", category: "net")
        }
    }

    /// A tiny guided-tour set used when the network import fails, so the app is never empty offline.
    private static let starterTasks: [(String, Priority)] = [
        ("Open the SandboxServer console (see the Settings tab)", .high),
        ("Tap a task to edit its note — it's saved as a file", .normal),
        ("Swipe a row to delete it", .normal),
        ("Run Sync to generate real network traffic", .normal),
        ("Check the Databases / Files / Network panels", .low),
    ]
}
