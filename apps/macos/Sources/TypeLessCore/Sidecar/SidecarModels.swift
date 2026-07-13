import Foundation

/// Ausgabemodus — Spiegelung von ``Mode`` aus der Engine (M1).
public enum Mode: String, Sendable, CaseIterable {
    case diktat, prompt, email, slack, braindump
}

/// Zustand des Sidecars (Antwort auf ``/health``).
public struct HealthState: Sendable, Equatable {
    public let status: String        // "starting" | "ready" | "failed"
    public let sttLoaded: Bool
    public let llmLoaded: Bool
    public let busy: Bool
    public let sttModel: String
    public let llmModel: String
    /// Klartext-Grund, wenn ``status == "failed"``.
    public let error: String?
}

/// Ergebnis eines Diktats — Spiegelung von ``ProcessResult`` aus der Engine.
public struct ProcessResult: Sendable, Equatable {
    public let finalText: String
    public let rawText: String
    public let dictionaryText: String
    public let mode: String
    public let language: String?
    /// ``false`` heißt: Das LLM ist ausgefallen, der Text ist der wörterbuch-bereinigte
    /// Rohtext. Das ist **kein Fehler** — das Diktat ist da, nur unpoliert.
    public let refined: Bool
    public let fallbackReason: String?
    public let timingsMs: [String: Double]
}

public enum SidecarError: Error, Equatable, Sendable {
    /// Am Socket lauscht niemand — der Sidecar läuft nicht.
    case unreachable
    /// Der Sidecar läuft, ist aber nicht einsatzbereit (STT-Warm-up gescheitert). HTTP 503.
    /// Ausdrücklich etwas **anderes** als ``unreachable``.
    case notReady(String)
    /// Die Verarbeitung selbst ist gescheitert (STT-Ausfall). HTTP 500.
    case processingFailed(String)
    /// Ungültige Anfrage. HTTP 400.
    case badRequest(String)
    case malformedResponse
}

// MARK: - JSON-Formen des Sidecars (snake_case)

struct HealthDTO: Decodable {
    let status: String
    let stt_loaded: Bool
    let llm_loaded: Bool
    let busy: Bool
    let stt_model: String
    let llm_model: String
    let error: String?
}

struct ProcessDTO: Decodable {
    let final_text: String
    let raw_text: String
    let dictionary_text: String
    let mode: String
    let language: String?
    let refined: Bool
    let fallback_reason: String?
    let timings_ms: [String: Double]
}

struct DetailDTO: Decodable {
    let detail: String
}
