import Foundation
import Network

/// Ein echter Unix-Domain-Socket-Server für Tests.
///
/// Damit laufen die Client-Tests gegen eine echte Socket-Verbindung — ohne Python, ohne
/// Modelle, in Millisekunden. Die Antwort ist frei vorgebbar, auch die Fehlerfälle.
final class FakeSidecarServer: @unchecked Sendable {
    let socketPath: String
    private let listener: NWListener
    private let lock = NSLock()
    private var status = 200
    private var json = "{}"
    private var requests: [String] = []

    var receivedRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    init() throws {
        socketPath = "/tmp/tl-test-\(UUID().uuidString.prefix(8)).sock"
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketPath)
        listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data {
                    // Verlustbehaftet statt scheiternd decodieren: Header+Body kommen als ein
                    // einziger `send()`-Aufruf und damit oft als ein zusammenhängender Chunk an.
                    // Bei binärem Body (z. B. rohes PCM) wäre `String(data:encoding:.utf8)` nil
                    // und würde die kompletten — sonst validen — Header-Zeilen verwerfen.
                    let text = String(decoding: data, as: UTF8.self)
                    self.lock.lock(); self.requests.append(text); self.lock.unlock()
                }
                self.lock.lock()
                let (s, j) = (self.status, self.json)
                self.lock.unlock()

                let body = Data(j.utf8)
                let head = """
                HTTP/1.1 \(s) OK\r
                Content-Length: \(body.count)\r
                Content-Type: application/json\r
                Connection: close\r
                \r

                """
                conn.send(content: Data(head.utf8) + body,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    /// Legt die Antwort fest, die der Server ab jetzt liefert.
    func respond(status: Int, json: String) {
        lock.lock(); self.status = status; self.json = json; lock.unlock()
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
