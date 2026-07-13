import Foundation

/// Spricht mit dem Sidecar. Vier Methoden, exakt die vier Endpunkte aus M2.
public protocol SidecarClient: Sendable {
    func health() async throws -> HealthState
    func preload() async throws
    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult
    func unload() async throws
}

/// Die echte Implementierung: HTTP über den Unix-Domain-Socket.
public struct HTTPSidecarClient: SidecarClient {
    private let transport: HTTPUnixTransport

    /// Die Engine erwartet 16-kHz-Mono-Float32. Die Rate steht nicht in den Rohdaten und muss
    /// deshalb mitgeschickt werden (siehe M2).
    private static let sampleRate = 16_000

    public init(socketPath: String) {
        transport = HTTPUnixTransport(socketPath: socketPath)
    }

    public func health() async throws -> HealthState {
        let response = try await request("GET", "/health", body: nil, contentType: nil,
                                         timeout: .seconds(5))
        let dto: HealthDTO = try decode(response)
        return HealthState(status: dto.status, sttLoaded: dto.stt_loaded, llmLoaded: dto.llm_loaded,
                           busy: dto.busy, sttModel: dto.stt_model, llmModel: dto.llm_model,
                           error: dto.error)
    }

    public func preload() async throws {
        _ = try await request("POST", "/preload", body: nil, contentType: nil, timeout: .seconds(5))
    }

    public func unload() async throws {
        _ = try await request("POST", "/unload", body: nil, contentType: nil, timeout: .seconds(30))
    }

    public func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        var path = "/process?mode=\(mode.rawValue)&sample_rate=\(Self.sampleRate)"
        if let language { path += "&language=\(language)" }

        // Großzügig: Ein langes Diktat plus LLM-Ladezeit kann eine Weile dauern.
        let response = try await request("POST", path, body: pcm,
                                         contentType: "application/octet-stream",
                                         timeout: .seconds(180))
        let dto: ProcessDTO = try decode(response)
        return ProcessResult(finalText: dto.final_text, rawText: dto.raw_text,
                             dictionaryText: dto.dictionary_text, mode: dto.mode,
                             language: dto.language, refined: dto.refined,
                             fallbackReason: dto.fallback_reason, timingsMs: dto.timings_ms)
    }

    // MARK: - Intern

    /// Führt die Anfrage aus und übersetzt HTTP-Fehlerstatus in ``SidecarError``.
    private func request(_ method: String, _ path: String, body: Data?, contentType: String?,
                         timeout: Duration) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(method: method, path: path, body: body,
                                                contentType: contentType, timeout: timeout)
        } catch TransportError.unreachable, TransportError.timedOut {
            throw SidecarError.unreachable
        } catch {
            throw SidecarError.malformedResponse
        }

        switch response.status {
        case 200, 202:
            return response
        case 400:
            throw SidecarError.badRequest(detail(response))
        case 503:
            // "Läuft, aber kaputt" — ausdrücklich nicht unreachable.
            throw SidecarError.notReady(detail(response))
        default:
            throw SidecarError.processingFailed(detail(response))
        }
    }

    private func detail(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode(DetailDTO.self, from: response.body))?.detail
            ?? String(decoding: response.body, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw SidecarError.malformedResponse
        }
    }
}
