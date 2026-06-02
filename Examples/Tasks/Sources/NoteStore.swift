import Foundation

/// Per-task free-text notes, stored as individual Markdown files under `Documents/notes/`, plus a
/// JSON export under `Documents/exports/`. These are deliberately real files on disk so the
/// console's **Files** panel has organic content to browse, download, edit, and delete — and so
/// editing a note in the app is reflected the moment you refresh the panel.
struct NoteStore {
    let notesDir: URL
    let exportsDir: URL

    init?() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        notesDir = docs.appendingPathComponent("notes", isDirectory: true)
        exportsDir = docs.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
    }

    private func url(for id: Int64) -> URL {
        notesDir.appendingPathComponent("task-\(id).md")
    }

    func load(id: Int64) -> String {
        (try? String(contentsOf: url(for: id), encoding: .utf8)) ?? ""
    }

    /// Writes the note (or removes the file when the note is emptied) and returns a one-line
    /// summary suitable for caching on the DB row / showing in the list.
    @discardableResult
    func save(id: Int64, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(id: id)
            return ""
        }
        try? text.write(to: url(for: id), atomically: true, encoding: .utf8)
        return summary(of: trimmed)
    }

    func delete(id: Int64) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func deleteAll() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    /// Writes a timestamped JSON snapshot of all tasks to `Documents/exports/` and returns its URL.
    func exportJSON(_ tasks: [TaskItem]) -> URL? {
        let iso = ISO8601DateFormatter()
        let rows = tasks.map { task -> [String: Any] in
            [
                "id": task.id,
                "title": task.title,
                "done": task.isDone,
                "priority": task.priority.label,
                "createdAt": iso.string(from: task.createdAt),
                "note": load(id: task.id),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = exportsDir.appendingPathComponent("tasks-\(stamp).json")
        try? data.write(to: url)
        return url
    }

    /// First non-empty line, clipped, for the list subtitle.
    private func summary(of text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }
}
