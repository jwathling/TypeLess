import Foundation
import Network

/// Ein Unix-Socket-Server, der Verbindungen annimmt, aber absichtlich **nie** antwortet.
///
/// Reproduziert den in Finding 1 beschriebenen Praxisfall: Der Python-Sidecar verarbeitet
/// serialisiert (Lock) — „Verbindung angenommen, Antwort kommt später oder nie" ist ein realer
/// Zustand (z. B. wenn eine vorherige Anfrage noch läuft oder der Sidecar hängt). Anders als
/// `FakeSidecarServer` liest dieser Server nicht einmal die Anfrage — er hält die Verbindung nur
/// am Leben, damit der Client die `.ready`-Handshake-Phase verlässt und in `receive()` blockiert.
final class SilentSidecarServer: @unchecked Sendable {
    let socketPath: String
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
        socketPath = "/tmp/tl-test-silent-\(UUID().uuidString.prefix(8)).sock"
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketPath)
        listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            // Bewusst: kein send(), kein receive() — die Verbindung wird nur am Leben gehalten,
            // damit sie nicht sofort wieder abgebaut wird (und der Client dadurch fälschlich
            // `.failed` statt eines echten Hängers sähe).
            guard let self else { return }
            self.lock.lock()
            self.connections.append(conn)
            self.lock.unlock()
        }
        listener.start(queue: .global())
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let conns = connections
        connections.removeAll()
        lock.unlock()
        conns.forEach { $0.cancel() }
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
