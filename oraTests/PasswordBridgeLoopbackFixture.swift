import Foundation
import Network

/// Real HTTP origins with ephemeral ports. No file read grants or iframe HTML escaping.
/// `/held` acknowledges the request but sends no headers until explicitly released.
final class PasswordBridgeLoopbackFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PasswordBridgeLoopbackFixture")
    private var connections: [NWConnection] = []
    private var requests: [String] = []
    private var heldConnections: [NWConnection] = []

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
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
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func url(_ path: String = "/login") throws -> URL {
        guard let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
        else { throw FixtureError.missingPort }
        return url
    }

    func hasReceived(_ path: String) -> Bool {
        queue.sync { requests.contains(path) }
    }

    func releaseHeldResponse() {
        queue.sync {
            for connection in heldConnections {
                respond(connection, path: "/held")
            }
            heldConnections.removeAll()
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
            heldConnections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data {
                request.append(data)
            }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.requests.append(path)
                if path == "/held" {
                    self.heldConnections.append(connection)
                } else {
                    self.respond(connection, path: path)
                }
            } else if complete || error != nil || request.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        let found = ["/login", "/other", "/held"].contains(path)
        let body = Data((found ? Self.formHTML : "Not found").utf8)
        let header = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    enum FixtureError: Error { case missingPort }

    static let formHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Password fixture</title></head><body>
    <form id="login-form" action="/login" method="post">
      <input id="user" name="username" type="text" autocomplete="username"
             style="width:240px;height:24px">
      <input id="pw" name="password" type="password" autocomplete="current-password"
             style="width:240px;height:24px">
      <button type="submit">Sign in</button>
    </form>
    <script>
      document.getElementById('login-form').addEventListener('submit', event => event.preventDefault());
    </script>
    </body></html>
    """
}
