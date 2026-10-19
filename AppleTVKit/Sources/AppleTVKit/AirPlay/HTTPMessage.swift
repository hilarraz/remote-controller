import Foundation

/// An HTTP or RTSP message (AirPlay uses both on the same connection).
struct HTTPMessage {
    /// "POST /pair-verify HTTP/1.1" or "RTSP/1.0 200 OK".
    var startLine: String
    var headers: [(String, String)]
    var body: Data

    init(startLine: String, headers: [(String, String)] = [], body: Data = Data()) {
        self.startLine = startLine
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// Status code of a response.
    var statusCode: Int? {
        let parts = startLine.split(separator: " ")
        guard parts.count >= 2, parts[0].contains("/") else { return nil }
        return Int(parts[1])
    }

    /// "RTSP/1.0" for "POST /command RTSP/1.0", or the first token of a response.
    var protocolVersion: String {
        let parts = startLine.split(separator: " ")
        if parts.first?.contains("/") == true { return String(parts[0]) }
        return parts.last.map(String.init) ?? "RTSP/1.0"
    }

    func serialized() -> Data {
        var lines = [startLine]
        var allHeaders = headers
        if !body.isEmpty, header("Content-Length") == nil {
            allHeaders.append(("Content-Length", String(body.count)))
        }
        lines += allHeaders.map { "\($0.0): \($0.1)" }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// Removes and returns the first complete message in `buffer`, if any.
    static func parse(from buffer: inout Data) -> HTTPMessage? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let startLine = lines.removeFirst()
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
        let length = headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.1) } ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<bodyStart + length])
        buffer = Data(buffer[(bodyStart + length)...])
        return HTTPMessage(startLine: startLine, headers: headers, body: body)
    }
}

/// Sends HTTP/RTSP requests on a `HAPConnection` and matches responses in order.
final class HTTPClient: @unchecked Sendable {
    let connection: HAPConnection
    private var buffer = Data()
    private var pending: [CheckedContinuation<HTTPMessage, Error>] = []

    init(connection: HAPConnection) {
        self.connection = connection
        connection.dataHandler = { [weak self] data in self?.received(data) }
        connection.closeHandler = { [weak self] _ in self?.failAll() }
    }

    func send(_ request: HTTPMessage) async throws -> HTTPMessage {
        try await withCheckedThrowingContinuation { continuation in
            connection.queue.async {
                self.pending.append(continuation)
                self.connection.send(request.serialized())
            }
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let message = HTTPMessage.parse(from: &buffer) {
            guard !pending.isEmpty else {
                logger.debug("Unexpected HTTP message: \(message.startLine)")
                continue
            }
            pending.removeFirst().resume(returning: message)
        }
    }

    private func failAll() {
        let error = CompanionError.connectionFailed("connexion AirPlay fermée")
        pending.forEach { $0.resume(throwing: error) }
        pending.removeAll()
    }
}
