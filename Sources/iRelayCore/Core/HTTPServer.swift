import Foundation
import Network

// MARK: - HTTP Types

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public final class ServerConnection {
    public let connection: NWConnection

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func sendJSON(status: Int, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText(status))\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        guard var headerData = header.data(using: .utf8) else {
            connection.cancel()
            return
        }
        headerData.append(data)
        connection.send(content: headerData, completion: .contentProcessed({ [weak self] _ in
            self?.connection.cancel()
        }))
    }

    /// SSE 流式响应: 先发 headers，然后通过 sendSSE 写入事件
    public func startSSE() {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: header.data(using: .utf8)!, completion: .contentProcessed({ _ in }))
    }

    public func sendSSE(event: String, data: String) {
        let payload = "event: \(event)\ndata: \(data)\n\n"
        connection.send(content: payload.data(using: .utf8)!, completion: .contentProcessed({ _ in }))
    }

    /// 发送裸 data: 行（Chat Completions SSE 格式）
    public func sendSSEData(_ data: String) {
        let payload = "data: \(data)\n\n"
        connection.send(content: payload.data(using: .utf8)!, completion: .contentProcessed({ _ in }))
    }

    public func sendSSEJSON(event: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        sendSSE(event: event, data: jsonStr)
    }

    public func sendSSEJSONAndClose(event: String, json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let jsonStr = String(data: data, encoding: .utf8),
              let payload = "event: \(event)\ndata: \(jsonStr)\n\n".data(using: .utf8)
        else {
            connection.cancel()
            return
        }
        connection.send(content: payload, contentContext: .defaultStream, isComplete: true, completion: .contentProcessed({ [weak self] _ in
            self?.connection.cancel()
        }))
    }

    public func close() {
        connection.cancel()
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return ""
        }
    }
}

// MARK: - HTTPServer

public final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.xdf.irelay.http", qos: .default)
    private var handlers: [(String, String, (HTTPRequest, ServerConnection) -> Void)] = []
    private let maxRequestBytes = 20 * 1024 * 1024

    public init() {}

    public func on(_ method: String, _ path: String, handler: @escaping (HTTPRequest, ServerConnection) -> Void) {
        handlers.append((method.uppercased(), path, handler))
    }

    public func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            let serverConn = ServerConnection(conn)
            self.receive(serverConn)
        }
        listener?.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(_ conn: ServerConnection) {
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: ServerConnection, buffer: Data) {
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                if isComplete || error != nil { conn.connection.cancel() }
                return
            }
            var next = buffer
            next.append(data)

            if next.count > self.maxRequestBytes {
                conn.sendJSON(status: 413, body: ["error": "request too large"])
                return
            }

            if self.hasCompleteRequest(next) {
                self.handle(next, conn: conn)
                return
            }

            self.receive(conn, buffer: next)
        }
    }

    private func handle(_ data: Data, conn: ServerConnection) {
        guard let request = parseHTTP(data) else {
            conn.sendJSON(status: 400, body: ["error": "invalid request"])
            return
        }

        for (method, path, handler) in handlers {
            if method == request.method.uppercased() && matchPath(path, request.path) {
                handler(request, conn)
                return
            }
        }
        conn.sendJSON(status: 404, body: ["error": "not found"])
    }

    /// 极简 HTTP/1.1 请求解析
    private func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerEndRange.lowerBound]
        guard let raw = String(data: headerData, encoding: .utf8) else { return nil }
        let parts = raw.components(separatedBy: "\r\n")
        guard !parts.isEmpty else { return nil }

        // 请求行: METHOD PATH HTTP/1.1
        let requestLine = parts[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1].components(separatedBy: "?").first ?? requestLine[1]

        // Headers
        var headers: [String: String] = [:]
        for line in parts.dropFirst() {
            let colonIdx = line.firstIndex(of: ":")
            if let colon = colonIdx {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = val
            }
        }

        // Body
        let body: Data
        if let contentLength = headers["content-length"], let length = Int(contentLength), length > 0 {
            let bodyStart = headerEndRange.upperBound
            let bodyEnd = min(data.endIndex, bodyStart + length)
            body = data[bodyStart..<bodyEnd]
        } else {
            body = Data()
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data[..<headerEndRange.lowerBound]
        guard let raw = String(data: headerData, encoding: .utf8) else { return false }

        var contentLength = 0
        for line in raw.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                break
            }
        }

        return data.count >= headerEndRange.upperBound + contentLength
    }

    private func matchPath(_ pattern: String, _ path: String) -> Bool {
        pattern == path
    }
}
