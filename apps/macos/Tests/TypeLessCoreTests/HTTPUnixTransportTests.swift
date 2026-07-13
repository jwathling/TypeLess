import Foundation
import Testing
@testable import TypeLessCore

@Test func liefertStatusUndBody() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: #"{"status":"ready"}"#)

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    let response = try await transport.send(method: "GET", path: "/health",
                                            body: nil, contentType: nil, timeout: .seconds(5))

    #expect(response.status == 200)
    #expect(String(decoding: response.body, as: UTF8.self) == #"{"status":"ready"}"#)
}

@Test func reichtFehlerStatusDurchStattZuWerfen() async throws {
    // 503 ist eine gültige Antwort ("läuft, aber kaputt"), kein Transportfehler.
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 503, json: #"{"detail":"kaputt"}"#)

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    let response = try await transport.send(method: "POST", path: "/process",
                                            body: Data([1, 2, 3, 4]),
                                            contentType: "application/octet-stream",
                                            timeout: .seconds(5))

    #expect(response.status == 503)
}

@Test func sendetMethodePfadUndBody() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 202, json: "{}")

    let transport = HTTPUnixTransport(socketPath: server.socketPath)
    _ = try await transport.send(method: "POST", path: "/process?mode=diktat",
                                 body: Data([0xAA, 0xBB]), contentType: "application/octet-stream",
                                 timeout: .seconds(5))

    let request = try #require(server.receivedRequests.first)
    #expect(request.hasPrefix("POST /process?mode=diktat HTTP/1.1"))
    #expect(request.contains("Content-Length: 2"))
    #expect(request.contains("Content-Type: application/octet-stream"))
}

@Test func meldetUnreachableWennKeinSocketDaIst() async throws {
    let transport = HTTPUnixTransport(socketPath: "/tmp/gibt-es-nicht-\(UUID().uuidString).sock")

    await #expect(throws: TransportError.unreachable) {
        _ = try await transport.send(method: "GET", path: "/health",
                                     body: nil, contentType: nil, timeout: .seconds(2))
    }
}

// Finding 1 (Review, Task 2): Nimmt der Server die Verbindung an, antwortet aber nie, muss der
// Timeout trotzdem greifen. Harte Obergrenze über `.timeLimit`, damit ein Regression nicht die
// ganze Suite unbegrenzt hängen lässt, sondern der Test selbst nach spätestens einer Minute als
// fehlgeschlagen markiert wird.
@Test(.timeLimit(.minutes(1)))
func liefertTimeoutWennVerbindungStehtAberServerNieAntwortet() async throws {
    let server = try SilentSidecarServer()
    defer { server.stop() }

    let transport = HTTPUnixTransport(socketPath: server.socketPath)

    await #expect(throws: TransportError.timedOut) {
        _ = try await transport.send(method: "GET", path: "/health",
                                     body: nil, contentType: nil, timeout: .milliseconds(300))
    }
}
