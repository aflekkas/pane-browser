import Foundation
import Network

/// Range-capable real HTTP server. Records authentication/session and Range
/// headers, sends paced chunks so cancellation exercises WebKit resume data.
final class DownloadFlowFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DownloadFlowFixture")
    private var connections: [NWConnection] = []
    private var received: [String] = []
    /// Reproducible nonuniform bytes: shifted/duplicated ranges must fail even
    /// when their total length happens to be correct.
    static let payload: Data = {
        var state: UInt32 = 0xC0FFEE
        return Data((0 ..< (2 * 1024 * 1024)).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }()

    var requests: [String] {
        queue.sync { received }
    }

    init(tls: NWProtocolTLS.Options? = nil) async throws {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func url(_ path: String = "/index", secure: Bool = false) throws -> URL {
        let port = try listener.port.unwrap()
        return try URL(string: "\(secure ? "https" : "http")://127.0.0.1:\(port.rawValue)\(path)").unwrap()
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, ended, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                received.append(request)
                respond(connection, request: request)
            } else if ended || error != nil {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        if path.hasPrefix("/redirect?") {
            let target = String(path.dropFirst("/redirect?".count))
            send(connection, status: "302 Found", headers: "Location: \(target)\r\n", body: Data())
        } else if path.hasPrefix("/auth"), Self.header("authorization", in: request) != "Basic Zml4dHVyZTpwYXNz" {
            send(
                connection,
                status: "401 Unauthorized",
                headers: "WWW-Authenticate: Basic realm=\"fixture\"\r\n",
                body: Data()
            )
        } else if path == "/large" || path == "/auth-large" {
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let offset = range
                .flatMap { Int($0.components(separatedBy: "=").last?.split(separator: "-").first ?? "0") } ?? 0
            let ranged = range != nil
            let headers = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\n"
                + "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=payload.bin\r\n"
                + "Accept-Ranges: bytes\r\nETag: \"fixture-v1\"\r\n"
                + (ranged ? "Content-Range: bytes \(offset)-\(Self.payload.count - 1)/\(Self.payload.count)\r\n" : "")
                + "Content-Length: \(Self.payload.count - offset)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.sendChunk(connection, offset: offset)
                }
            })
        } else if path == "/attachment" || path == "/displayable" {
            let header = path == "/attachment" ? "Content-Disposition: attachment; filename=page.html\r\n" : ""
            send(connection, headers: "Content-Type: text/html\r\n" + header, body: Data("<p>downloaded</p>".utf8))
        } else {
            send(connection, headers: "Content-Type: text/html\r\n", body: Data(Self.html.utf8))
        }
    }

    private static func header(_ name: String, in request: String) -> String? {
        request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name + ":") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
    }

    private func sendChunk(_ connection: NWConnection, offset: Int) {
        guard offset < Self.payload.count else { connection.cancel()
            return
        }
        let end = min(Self.payload.count, offset + 32768)
        connection.send(
            content: Self.payload.subdata(in: offset ..< end),
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { return }
                queue.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.sendChunk(connection, offset: end) }
            }
        )
    }

    private func send(_ connection: NWConnection, status: String = "200 OK", headers: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let html = """
    <!doctype html><title>Download fixture</title>
    <a id="html" download="display.html" href="/displayable">HTML</a>
    <a id="attachment" href="/attachment">Attachment</a>
    <a id="large" href="/large">Large</a>
    <a id="blob" download="blob.txt">Blob</a>
    <script>document.getElementById('blob').href=URL.createObjectURL(new Blob(['blob payload'],{type:'text/plain'}));</script>
    """
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw URLError(.badURL) }
        return self
    }
}
