import Foundation

/// A single to-do item. The source of truth lives in the SQLite store (`tasks.sqlite`), which is
/// exactly what the SandboxServer **Databases** panel browses live. The free-text note lives in a
/// separate file on disk (see ``NoteStore``) so the **Files** panel has real content too — only a
/// one-line summary is cached on the row so the list needn't read every file.
struct TaskItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var title: String
    var isDone: Bool
    var priority: Priority
    var createdAt: Date
    var noteSummary: String
}

enum Priority: Int, CaseIterable, Identifiable, Sendable {
    case low = 0, normal = 1, high = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    /// SF Symbol shown next to the task.
    var symbol: String {
        switch self {
        case .low: return "arrow.down.circle"
        case .normal: return "minus.circle"
        case .high: return "exclamationmark.circle"
        }
    }
}

/// How the list is ordered. Persisted in `UserDefaults` from the Settings tab (so the choice shows
/// up — and can be edited — in the console's **Defaults** panel).
enum TaskSort: String, CaseIterable, Identifiable, Sendable {
    case created, priority, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .created: return "Date added"
        case .priority: return "Priority"
        case .title: return "Title"
        }
    }
}

/// `UserDefaults` keys, kept in one place so the views and the store agree on the spelling.
/// Prefixed `tasks.` so they're easy to spot among the system's own keys in the Defaults panel.
enum SettingsKey {
    static let username = "tasks.username"
    static let sort = "tasks.sortOrder"
    static let hideCompleted = "tasks.hideCompleted"
    static let lastSync = "tasks.lastSync"
}
