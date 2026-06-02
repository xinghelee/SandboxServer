import Foundation

/// A shape that matches one item from `jsonplaceholder.typicode.com/todos`.
struct RemoteTodo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
}

/// The app's (pretend) backend. Uses the well-known public sample API so the demo has *real*
/// network traffic — captured automatically by `SandboxURLProtocol` and visible in the console's
/// **Network** panel, where you can inspect bodies and Replay requests.
///
/// All methods are plain `async` and `Sendable`-safe; the `@MainActor` ``TaskStore`` simply
/// `await`s them. `jsonplaceholder` fakes writes (it echoes back without persisting), which is
/// perfect for a demo: a `POST` returns `201` with the object so the panel shows a complete
/// round-trip without us standing up a server.
struct TaskAPI: Sendable {
    private let base = URL(string: "https://jsonplaceholder.typicode.com")!

    /// Fetches a batch of sample todos to seed an empty store. Throws on no network / bad status
    /// so the caller can fall back to local starter tasks.
    func fetchSeedTodos(limit: Int) async throws -> [RemoteTodo] {
        var components = URLComponents(url: base.appendingPathComponent("todos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "_limit", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([RemoteTodo].self, from: data)
    }

    /// Best-effort push of one task to the backend. Returns the HTTP status code (or nil on
    /// failure). The JSON body is exactly the kind of payload you'd want to inspect/Replay.
    func push(_ task: TaskItem) async -> Int? {
        guard let url = URL(string: base.appendingPathComponent("todos").absoluteString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["title": task.title, "completed": task.isDone, "userId": 1]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}
