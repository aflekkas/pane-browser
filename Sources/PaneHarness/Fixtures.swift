// spec: §6
import Foundation

/// Starts and stops the local fixture server for scenarios.
///
/// Nothing in the suite touches the network. A test that depends on the
/// internet fails for reasons unrelated to the code, and in an unattended run
/// that failure is indistinguishable from a real regression.
@MainActor
public final class Fixtures {
    private var process: Process?
    public private(set) var baseURL: URL?
    public private(set) var tlsURL: URL?

    public init() {}

    public func start(port: Int = 8751, tlsPort: Int = 8752) async -> Bool {
        let script = URL(fileURLWithPath: "Fixtures/fixture_server.py").standardizedFileURL
        guard FileManager.default.fileExists(atPath: script.path) else { return false }

        func spawn(_ args: [String]) -> Process? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            return p
        }
        process = spawn(["--port", String(port)])
        tlsProcess = spawn(["--port", String(tlsPort), "--tls"])
        guard process != nil else { return false }

        baseURL = URL(string: "http://127.0.0.1:\(port)")
        tlsURL = URL(string: "https://127.0.0.1:\(tlsPort)")

        // Poll rather than sleep a guess: openssl key generation makes the TLS
        // server's startup time variable.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if await reachable(baseURL!) { return true }
        }
        return false
    }

    private var tlsProcess: Process?

    private func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    public func stop() {
        process?.terminate(); process = nil
        tlsProcess?.terminate(); tlsProcess = nil
    }
}
