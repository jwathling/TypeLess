import Foundation
import Network

/// Eine HTTP-Antwort in ihrer rohen Form.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

public enum TransportError: Error, Equatable, Sendable {
    /// Am Socket lauscht niemand — der Sidecar läuft nicht.
    case unreachable
    case timedOut
    case malformedResponse
}

/// HTTP/1.1 über einen Unix-Domain-Socket.
///
/// ``URLSession`` kann keine Unix-Sockets, deshalb dieser schlanke Eigenbau über
/// ``NWConnection``. Er kennt bewusst keine TypeLess-Semantik — nur Methode, Pfad, Bytes.
///
/// Die Anfrage schickt ``Connection: close``, die Antwort wird bis zum Verbindungsende
/// gelesen. Dadurch entfällt das Parsen von ``Content-Length``/``Transfer-Encoding`` — die
/// fehleranfälligste Stelle eines selbstgebauten Clients. Preis: eine Verbindung pro Anfrage,
/// bei vier kleinen Aufrufen irrelevant.
public struct HTTPUnixTransport: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(
        method: String,
        path: String,
        body: Data?,
        contentType: String?,
        timeout: Duration
    ) async throws -> HTTPResponse {
        let raw = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await roundTrip(method: method, path: path,
                                                body: body, contentType: contentType) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return try Self.parse(raw)
    }

    private func roundTrip(method: String, path: String,
                           body: Data?, contentType: String?) async throws -> Data {
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        defer { connection.cancel() }

        // Wichtig: Ohne eigenen Zustands-Handler bleibt eine Verbindung zu einem Unix-Socket
        // ohne Listener (ECONNREFUSED/ENOENT) im Zustand `.waiting` stecken — Network.framework
        // interpretiert das als „Netzwerkpfad kommt vielleicht gleich zurück" (sinnvoll bei
        // WLAN-Wechsel, sinnlos bei einem lokalen Socket) und versucht endlos weiter, ohne dass
        // `send`/`receive` je einen Fehler liefern. Für einen lokalen UDS ist `.waiting` daher
        // faktisch gleichbedeutend mit `.failed`.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    c.resume()
                case .failed:
                    connection.stateUpdateHandler = nil
                    c.resume(throwing: TransportError.unreachable)
                case .waiting:
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    c.resume(throwing: TransportError.unreachable)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: sidecar\r\nConnection: close\r\n"
        if let body { head += "Content-Length: \(body.count)\r\n" }
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        if let body { out.append(body) }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: out, completion: .contentProcessed { error in
                if error != nil { c.resume(throwing: TransportError.unreachable) } else { c.resume() }
            })
        }

        var raw = Data()
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in
                    if error != nil {
                        c.resume(throwing: TransportError.unreachable)
                    } else if isComplete, data?.isEmpty ?? true {
                        c.resume(returning: nil)          // sauberes Verbindungsende
                    } else {
                        c.resume(returning: data ?? Data())
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            raw.append(chunk)
        }
        return raw
    }

    /// Zerlegt die Rohantwort in Status, Header und Body.
    static func parse(_ raw: Data) throws -> HTTPResponse {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TransportError.malformedResponse
        }
        let headText = String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw TransportError.malformedResponse }

        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw TransportError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPResponse(status: status, headers: headers,
                            body: Data(raw[separator.upperBound...]))
    }
}
