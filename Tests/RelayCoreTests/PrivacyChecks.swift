import Foundation
import RelayCore

private final class PrivacyTransport: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var metadata: [String: Any] = [:]
    private static var status = 200
    static func reset(_ description: [String: Any], status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        requests = []; metadata = description; self.status = status
    }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let metadata = Self.metadata; let status = Self.status; Self.lock.unlock()
        let body: [String: Any]
        if request.url!.path == "/api/show" { body = metadata }
        else {
            let decision = Decision(summary: "Verified", evidence: "Synthetic result is visible", action: Action(kind: .finish))
            body = ["done": true, "done_reason": "stop", "message": ["content": String(data: try! JSONEncoder().encode(decision), encoding: .utf8)!]]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum PrivacyChecks {
    static func run() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyTransport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let local: [String: Any] = ["details": ["format": "gguf"], "capabilities": ["completion"]]
        let screen = Observation(application: "Synthetic app", tree: "SYNTHETIC_SCREEN_TEXT", image: Data([1, 2, 3]))

        // 1. Even directly invoking each legacy client makes zero HTTP requests.
        PrivacyTransport.reset(local)
        do { _ = try await JevClient(apiKey: "synthetic", session: session).evaluate(state: ["screen": screen.tree], questions: [:]); preconditionFailure("Jev must be blocked") }
        catch { checkTrue(error.localizedDescription.contains("External AI requests are disabled")) }
        for provider in [Provider.openAI, .gemini] {
            do { _ = try await ModelClient(provider: provider, model: "test", apiKey: "synthetic", session: session).next(task: "test", memory: "", history: [], observation: screen); preconditionFailure("Cloud planner must be blocked") }
            catch { checkTrue(error.localizedDescription.contains("External AI requests are disabled")) }
        }
        checkEqual(PrivacyTransport.snapshot().count, 0)

        // 2. Valid local weights use only the two fixed loopback endpoints, without credentials.
        let decision = try await LocalModelClient(configuration: config).next(task: "test", memory: "", history: [], observation: screen)
        checkEqual(decision.action.kind, .finish)
        let requests = PrivacyTransport.snapshot()
        checkEqual(requests.map { $0.url!.absoluteString }, ["http://127.0.0.1:11434/api/show", "http://127.0.0.1:11434/api/chat"])
        checkTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let body = LocalModelClient.requestBody(task: "test", memory: "", history: [], observation: screen)
        let messages = body["messages"] as! [[String: String]]
        checkTrue(messages.allSatisfy { $0["images"] == nil })
        checkEqual(body["model"] as? String, "qwen3:8b")

        // 3. Cloud aliases are refused before any task-bearing chat request, on every call.
        for key in ["remote_model", "remote_host"] {
            var remote = local; remote[key] = "cloud.example"
            PrivacyTransport.reset(remote)
            do { _ = try await LocalModelClient(configuration: config).next(task: "test", memory: "", history: [], observation: screen); preconditionFailure("Remote model accepted") }
            catch { checkTrue(error.localizedDescription.contains("refuses cloud")) }
            checkEqual(PrivacyTransport.snapshot().map { $0.url!.path }, ["/api/show"])
        }

        // 4. Missing or unverified local weights stop before task data is sent.
        for invalid in [[String: Any](), ["details": ["format": "unknown"], "capabilities": ["completion"]], ["details": ["format": "gguf"], "capabilities": ["embedding"]]] {
            PrivacyTransport.reset(invalid)
            do { _ = try await LocalModelClient(configuration: config).next(task: "test", memory: "", history: [], observation: screen); preconditionFailure("Unverified model accepted") }
            catch { checkTrue(error.localizedDescription.contains("could not be verified")) }
            checkEqual(PrivacyTransport.snapshot().count, 1)
        }

        // 5. Server errors and redirect responses have no retry or external fallback.
        for status in [302, 404, 500] {
            PrivacyTransport.reset(local, status: status)
            do { _ = try await LocalModelClient(configuration: config).next(task: "test", memory: "", history: [], observation: screen); preconditionFailure("Failed server accepted") }
            catch { checkTrue(error.localizedDescription.contains("local model request failed")) }
            checkEqual(PrivacyTransport.snapshot().count, 1)
        }

        // 6. The redirect delegate refuses even a valid-looking external redirect.
        let destination = URLRequest(url: URL(string: "https://api.typesafe.ai/test")!)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:11434/api/show")!)
        var refused = false
        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: destination) { refused = $0 == nil }
        checkTrue(refused); task.cancel()

        // 7. Incomplete or invalid model output cannot become a computer action.
        checkThrows(try LocalModelClient.parse(["done": false, "message": ["content": "{}"]]))
        checkThrows(try LocalModelClient.parse(["done": true, "done_reason": "length", "message": ["content": "{}"]]))
        checkThrows(try LocalModelClient.parse(["done": true, "message": ["content": "invalid"]]))
    }
}
