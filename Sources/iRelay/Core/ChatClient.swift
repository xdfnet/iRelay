import Foundation

/// OpenAI Chat Completions API 客户端
final class ChatClient {
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    private let apiKeyLock = NSLock()
    private var apiKeyStorage: String
    var apiKey: String {
        get {
            apiKeyLock.lock()
            defer { apiKeyLock.unlock() }
            return apiKeyStorage
        }
        set {
            apiKeyLock.lock()
            apiKeyStorage = newValue
            apiKeyLock.unlock()
        }
    }
    let baseURL: URL
    let chatEndpoint: String

    init(apiKey: String, baseURL: URL, chatEndpoint: String = "/chat/completions") {
        self.apiKeyStorage = apiKey
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
    }

    // MARK: - 非流式请求

    func chat(payload: [String: Any]) async throws -> (data: [String: Any], status: Int) {
        var req = try makeRequest(payload)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.invalidResponse
        }
        return (json, http.statusCode)
    }

    // MARK: - 流式请求

    func chatStream(payload: [String: Any]) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var req = try makeRequest(payload)
                    req.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: req)
                    let http = response as! HTTPURLResponse

                    guard http.statusCode == 200 else {
                        let data = try? await bytes.reduce(into: Data()) { $0.append($1) }
                        let msg = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        continuation.finish(throwing: ChatError.upstreamError(http.statusCode, msg?["error"]))
                        return
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let jsonStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !jsonStr.isEmpty, jsonStr != "[DONE]" else { continue }
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        continuation.yield(json)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeRequest(_ payload: [String: Any]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(chatEndpoint)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }
}

enum ChatError: Error, LocalizedError {
    case invalidResponse
    case upstreamError(Int, Any?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "upstream returned invalid JSON"
        case .upstreamError(let code, let details):
            if let d = details as? [String: Any], let msg = d["message"] as? String {
                return "upstream \(code): \(msg)"
            }
            return "upstream error: \(code)"
        }
    }
}
