import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    private let task: TaskItem
    @State private var title: String
    @State private var priority: Priority
    @State private var isDone: Bool
    @State private var note = ""
    @State private var noteLoaded = false

    init(task: TaskItem) {
        self.task = task
        _title = State(initialValue: task.title)
        _priority = State(initialValue: task.priority)
        _isDone = State(initialValue: task.isDone)
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("Title", text: $title, axis: .vertical)
                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Toggle("Done", isOn: $isDone)
            }

            Section {
                TextEditor(text: $note)
                    .frame(minHeight: 140)
            } header: {
                Text("Note")
            } footer: {
                Text("Saved as `Documents/notes/task-\(task.id).md` — open it in the console's Files panel.")
            }

            Section {
                LabeledContent("Created", value: task.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Row id", value: "\(task.id)")
            }
        }
        .navigationTitle("Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save(); dismiss() }
            }
        }
        .task {
            note = store.note(for: task)
            noteLoaded = true
        }
        .onDisappear(perform: save)
    }

    private func save() {
        // Don't write the note back until the file has actually been read in (avoids clobbering it
        // with the empty initial value if the view disappears before `.task` runs).
        guard noteLoaded else { return }
        var updated = task
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = trimmed.isEmpty ? task.title : trimmed
        updated.priority = priority
        updated.isDone = isDone
        store.commit(updated, note: note)
    }
}
