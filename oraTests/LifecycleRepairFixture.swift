import AppKit
import Foundation
import Network
@testable import Ora
import Testing
import WebKit

/// Ephemeral loopback origin; no public network or user store is involved.
final class LifecycleRepairFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LifecycleRepairFixture")
    private var connections: [NWConnection] = []

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
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

    func url(_ path: String = "/a") throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)\(path)"))
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] next, _, done, error in
            guard let self else { return }
            var data = data
            if let next {
                data.append(next)
            }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/a"
                let body = Data(Self.html(path).utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if done || error != nil || data.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, data: data)
            }
        }
    }

    private static func html(_ path: String) -> String {
        var extra = ""
        if path.hasPrefix("/depth/"), let depth = Int(path.dropFirst(7)), depth > 0 {
            extra = "<iframe src='/depth/\(depth - 1)'></iframe>"
        }
        if path == "/depth/0" {
            extra = "<script>navigator.mediaSession.playbackState='playing';</script>"
        }
        return """
        <!doctype html><html><head><title>Lifecycle fixture</title></head><body>
        <form id='form'><input id='input' value='saved'><textarea id='area'>saved</textarea></form>
        <div id='bare' contenteditable>saved</div><div id='plain' contenteditable='plaintext-only'>saved</div>
        <div id='host'></div>\(extra)<div style='height:6000px'>Scroll fixture</div>
        </body></html>
        """
    }
}

@MainActor
final class LifecycleRepairHarness {
    private let window: NSWindow
    private(set) var page: BrowserPage

    init(page: BrowserPage? = nil, profile: BrowserEngineProfile? = nil) {
        self.page = page ?? BrowserEngine().makePage(
            profile: profile ?? BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()),
            delegate: nil
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        attach(self.page)
        window.orderBack(nil)
    }

    func attach(_ page: BrowserPage) {
        self.page.contentView.removeFromSuperview()
        self.page = page
        page.contentView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(page.contentView)
    }

    func close() {
        page.teardown()
        window.close()
    }

    func load(_ url: URL) async throws {
        page.load(URLRequest(url: url))
        try await loaded(url)
    }

    func loaded(_ url: URL) async throws {
        try await Self.waitUntil { self.page.currentURL == url && !self.page.isLoading }
        // Ensure JS is ready in the committed document, not just the provisional URL.
        let ready = try await evaluate("document.readyState") as? String
        #expect(ready == "complete")
    }

    func evaluate(_ script: String, world: WKContentWorld = .page) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            page.webView.evaluateJavaScript(script, in: nil, in: world) { continuation.resume(with: $0) }
        }
    }

    func activity() async -> TabLifecycleActivity {
        await withCheckedContinuation { continuation in
            TabLifecycleActivityProbe.probe(page: page, timeout: 3) { continuation.resume(returning: $0) }
        }
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FixtureError.timeout
    }

    enum FixtureError: Error { case timeout }
}
