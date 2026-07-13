import Foundation
import Testing
@testable import TypeLessCore

private let gesundJSON = """
{"status":"ready","stt_loaded":true,"llm_loaded":false,"busy":false,
 "stt_model":"whisper","llm_model":"qwen","error":null}
"""

@Test func healthWirdUebersetzt() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: gesundJSON)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let health = try await client.health()

    #expect(health.status == "ready")
    #expect(health.sttLoaded == true)
    #expect(health.llmLoaded == false)
    #expect(health.error == nil)
}

@Test func healthMeldetFehlerzustandMitGrund() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"status":"failed","stt_loaded":false,"llm_loaded":false,"busy":false,
     "stt_model":"whisper","llm_model":"qwen","error":"STT-Warm-up fehlgeschlagen: 401"}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let health = try await client.health()

    #expect(health.status == "failed")
    #expect(health.error == "STT-Warm-up fehlgeschlagen: 401")
}

@Test func unpolierterTextIstKeinFehler() async throws {
    // Der Kern des M2-Vertrags: LLM ausgefallen -> 200 mit refined=false. Das Diktat ist da.
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"final_text":"roher text","raw_text":"roher text","dictionary_text":"roher text",
     "mode":"diktat","language":"de","refined":false,
     "fallback_reason":"LLM konnte nicht geladen werden","timings_ms":{"transcribe":1234.5}}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    let result = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)

    #expect(result.refined == false)
    #expect(result.finalText == "roher text")
    #expect(result.fallbackReason == "LLM konnte nicht geladen werden")
    #expect(result.timingsMs["transcribe"] == 1234.5)
}

@Test func notReadyIstNichtUnreachable() async throws {
    // 503 = "läuft, aber kaputt". Etwas ganz anderes als "antwortet gar nicht".
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 503, json: #"{"detail":"Sidecar nicht einsatzbereit: STT kaputt"}"#)

    let client = HTTPSidecarClient(socketPath: server.socketPath)

    await #expect(throws: SidecarError.notReady("Sidecar nicht einsatzbereit: STT kaputt")) {
        _ = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)
    }
}

@Test func sttAusfallWirdZuProcessingFailed() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 500, json: #"{"detail":"Verarbeitung fehlgeschlagen: STT kaputt"}"#)

    let client = HTTPSidecarClient(socketPath: server.socketPath)

    await #expect(throws: SidecarError.processingFailed("Verarbeitung fehlgeschlagen: STT kaputt")) {
        _ = try await client.process(pcm: Data([1, 2, 3, 4]), mode: .diktat, language: nil)
    }
}

@Test func fehlenderSidecarIstUnreachable() async throws {
    let client = HTTPSidecarClient(socketPath: "/tmp/gibt-es-nicht-\(UUID().uuidString).sock")

    await #expect(throws: SidecarError.unreachable) {
        _ = try await client.health()
    }
}

@Test func processSchicktModusUndPCM() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 200, json: """
    {"final_text":"t","raw_text":"t","dictionary_text":"t","mode":"email","language":null,
     "refined":true,"fallback_reason":null,"timings_ms":{}}
    """)

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    _ = try await client.process(pcm: Data([0, 0, 0, 0]), mode: .email, language: "de")

    let request = try #require(server.receivedRequests.first)
    #expect(request.contains("mode=email"))
    #expect(request.contains("language=de"))
    #expect(request.contains("sample_rate=16000"))
    #expect(request.contains("application/octet-stream"))
}

@Test func preloadUndUnloadWerfenNichtBeiErfolg() async throws {
    let server = try FakeSidecarServer()
    defer { server.stop() }
    server.respond(status: 202, json: "{}")

    let client = HTTPSidecarClient(socketPath: server.socketPath)
    try await client.preload()

    server.respond(status: 200, json: gesundJSON)
    try await client.unload()
}
