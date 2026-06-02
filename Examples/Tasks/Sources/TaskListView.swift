import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage(SettingsKey.sort) private var sortRaw = TaskSort.created.rawValue
    @AppStorage(SettingsKey.hideCompleted) private var hideCompleted = false

    @State private var showingAdd = false
    @State private var newTitle = ""

    private var sort: TaskSort { TaskSort(rawValue: sortRaw) ?? .created }

    private var displayed: [TaskItem] {
        var items = hideCompleted ? store.tasks.filter { !$0.isDone } : store.tasks
        switch sort {
        case .created:  break // store already returns newest-first
        case .priority: items.sort { $0.priority.rawValue > $1.priority.rawValue }
        case .title:    items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return items
    }

    var body: some View {
        NavigationStack {
            List {
                if let banner = store.banner {
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                            Text(banner).font(.footnote)
                            Spacer()
                            Button { store.banner = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(displayed) { task in
                        NavigationLink(value: task) { row(task) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.delete(task) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("Every change here is a write to `tasks.sqlite` and the per-task note files — browse them live in the SandboxServer console (Databases / Files panels).")
                }
            }
            .navigationTitle("Tasks")
            .navigationDestination(for: TaskItem.self) { TaskDetailView(task: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await store.sync() } } label: {
                        if store.isSyncing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(store.isSyncing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Task", isPresented: $showingAdd) {
                TextField("Title", text: $newTitle)
                Button("Add") { store.add(title: newTitle); newTitle = "" }
                Button("Cancel", role: .cancel) { newTitle = "" }
            }
            .task(id: store.banner) {
                guard store.banner != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                store.banner = nil
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Button { store.toggle(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                if !task.noteSummary.isEmpty {
                    Text(task.noteSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: task.priority.symbol)
                .foregroundStyle(color(for: task.priority))
        }
    }

    private func color(for priority: Priority) -> Color {
        switch priority {
        case .low: return .secondary
        case .normal: return .blue
        case .high: return .orange
        }
    }
}
