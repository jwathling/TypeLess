import Foundation
import Observation

/// Der Zustand des Diktats — **getrennt** vom Zustand der Engine (``EngineState``).
///
/// Beides in einen Typ zu pressen wäre ein Fehler: Das ``/health``-Polling schreibt alle 5 s in
/// den Engine-Zustand und würde die Aufnahmeanzeige überschreiben.
public enum SessionState: Sendable, Equatable {
    case idle
    case recording
    case processing
    /// Der letzte Fehlschlag, im Klartext — sichtbar bis zum nächsten Diktat.
    case failed(String)
}

/// Führt Hotkey, Aufnahme, Engine und Zwischenablage zusammen.
///
/// Ablauf: Fn gedrückt → Aufnahme startet, `/preload` läuft nebenher an. Fn losgelassen →
/// Aufnahme stoppt, wird geprüft und (wenn brauchbar) an die Engine geschickt; das Ergebnis
/// landet in der Zwischenablage.
///
/// **Verbindlich (Entscheidung des Anwenders):** Es gibt kein Overlay und keine Tonsignale.
/// Deshalb bleibt bei **jedem** Fehlschlag die Zwischenablage unangetastet — dann liefert ⌘V
/// wenigstens den alten Inhalt statt Leere.
@MainActor
@Observable
public final class DictationCoordinator {
    public private(set) var session: SessionState = .idle

    private let hotkey: HotkeyMonitor
    private let recorder: AudioRecorder
    private let client: SidecarClient
    private let pasteboard: Pasteboard

    /// 300 ms bei 16 kHz. Darunter war es ein versehentliches Antippen, kein Diktat.
    private let minimumSampleCount: Int

    private var hotkeyTask: Task<Void, Never>?
    /// Laufende Verarbeitungen. Der Nutzer darf sofort neu aufnehmen — die alte Verarbeitung
    /// läuft dann im Hintergrund weiter und schreibt ihr Ergebnis, wenn sie fertig ist.
    private var verarbeitungen: [UUID: Task<Void, Never>] = [:]

    public init(hotkey: HotkeyMonitor,
                recorder: AudioRecorder,
                client: SidecarClient,
                pasteboard: Pasteboard,
                minimumSampleCount: Int = 4_800) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.client = client
        self.pasteboard = pasteboard
        self.minimumSampleCount = minimumSampleCount
    }

    // MARK: - Lebenszyklus

    public func start() async {
        stopHotkey()
        do {
            let stream = try hotkey.start()
            hotkeyTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    switch event {
                    case .pressed: await self.handlePressed()
                    case .released: await self.handleReleased()
                    }
                }
            }
        } catch {
            session = .failed("Hotkey inaktiv — Eingabeüberwachung fehlt")
        }
    }

    public func stop() async {
        stopHotkey()

        // Eine noch laufende Aufnahme darf hier nicht einfach ignoriert werden: Ohne dieses
        // `stop()` bliebe das Mikrofon nach dem Beenden des Koordinators für immer offen — es
        // kommt ja kein `.released`-Ereignis mehr an, das die Aufnahme regulär beenden würde
        // (derselbe Fehlerklasse wie das "Mikrofon endlos offen"-Finding aus Task 2). Das
        // Ergebnis wird bewusst verworfen: Wir beenden gerade den Koordinator, es gibt niemanden
        // mehr, der ein Diktat entgegennehmen würde.
        if session == .recording {
            _ = try? await recorder.stop()
        }

        // Laufende Verarbeitungen zu Ende bringen: Ein fertig gesprochenes Diktat wegzuwerfen
        // wäre das Schlimmste, was wir tun könnten.
        for task in verarbeitungen.values { await task.value }
        verarbeitungen.removeAll()
        session = .idle
    }

    private func stopHotkey() {
        hotkeyTask?.cancel()
        hotkeyTask = nil
        hotkey.stop()
    }

    // MARK: - Tastendruck

    private func handlePressed() async {
        do {
            try await recorder.start()
        } catch AudioRecorderError.microphoneDenied {
            session = .failed("Mikrofonzugriff verweigert")
            return
        } catch {
            session = .failed("Aufnahme nicht möglich: \(error)")
            return
        }

        // Beschleunigung, kein Muss: Das Sprachmodell lädt, während der Nutzer noch spricht.
        // Scheitert das, lädt `/process` notfalls selbst nach — ein Diktat darf daran nie
        // scheitern. Deshalb wird der Fehler bewusst verworfen.
        Task { [client] in try? await client.preload() }

        session = .recording
    }

    private func handleReleased() async {
        guard session == .recording else { return }

        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
        } catch {
            session = .failed("Aufnahme fehlgeschlagen: \(error)")
            return
        }

        let samples = recording.werte

        // Versehentliches Antippen: kommentarlos verwerfen. Kein Fehler, keine Anzeige.
        guard samples.count >= minimumSampleCount else {
            session = .idle
            return
        }

        // `verloreneHaeppchen` zählt Mikrofon-Häppchen, deren Umrechnung fehlschlug und die
        // deshalb NICHT in `samples` stecken (s. ``AudioRecording``). Ohne diese Prüfung würde
        // ein Diktat still um Wörter kürzer — der Zähler existiert genau dafür, dass das nicht
        // mehr unbemerkt passiert. Deshalb geht so eine Aufnahme nicht mehr an die Engine,
        // sondern wird als Fehlschlag gemeldet wie jeder andere auch.
        guard recording.verloreneHaeppchen == 0 else {
            session = .failed("Teile der Aufnahme gingen verloren — bitte erneut versuchen")
            return
        }

        // Der einzige Fehlerfall, den der Nutzer ohne Overlay und ohne Ton sonst erst beim
        // Einfügen bemerkt — nach 30 Sekunden Sprechen in ein stummes Mikrofon.
        guard !SilenceDetector.isSilent(samples) else {
            session = .failed("Kein Ton aufgenommen — Mikrofon prüfen")
            return
        }

        session = .processing
        verarbeite(samples)
    }

    // MARK: - Verarbeitung

    private func verarbeite(_ samples: [Float]) {
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        // Die Task über eine Kennung verwalten, nicht über sich selbst: Eine lokale Variable,
        // die ihre eigene Closure einfängt, ist unter strict concurrency nicht erlaubt.
        let id = UUID()

        let task = Task { [weak self, client, pasteboard] in
            do {
                let ergebnis = try await client.process(pcm: pcm, mode: .diktat, language: nil)

                // `refined: false` heißt: Das LLM ist ausgefallen, der Text ist trotzdem da.
                // Das ist KEIN Fehler (M2-Vertrag) — ein Diktat geht nie verloren.
                pasteboard.write(ergebnis.finalText)
                // Kein `await`: Diese Task übernimmt bei ihrer Erzeugung die MainActor-Isolation
                // von `verarbeite(_:)` — wir sind hier bereits auf dem MainActor, der Aufruf ist
                // synchron (`beendeVerarbeitung` ist bewusst nicht `async`).
                self?.beendeVerarbeitung(id: id, fehler: nil)
            } catch {
                // Zwischenablage bleibt unangetastet: Der alte Inhalt ist besser als Leere.
                self?.beendeVerarbeitung(id: id, fehler: Self.beschreibe(error))
            }
        }
        verarbeitungen[id] = task
    }

    /// Setzt den Zustand nach einer Verarbeitung — aber **nur**, wenn der Nutzer nicht
    /// inzwischen schon wieder aufnimmt. Sonst würde ein spät eintreffendes Ergebnis die
    /// laufende Aufnahme wegblenden.
    private func beendeVerarbeitung(id: UUID, fehler: String?) {
        verarbeitungen[id] = nil
        guard session == .processing else { return }
        session = fehler.map { .failed($0) } ?? .idle
    }

    static func beschreibe(_ error: Error) -> String {
        guard let error = error as? SidecarError else { return "Unerwarteter Fehler: \(error)" }
        switch error {
        case .unreachable: return "Engine nicht erreichbar"
        case .timedOut: return "Die Engine antwortet gerade nicht"
        case let .notReady(grund): return grund
        case let .processingFailed(grund): return grund
        case let .badRequest(grund): return grund
        case .malformedResponse: return "Unverständliche Antwort der Engine"
        }
    }
}
