import AVFoundation

public enum AudioRecorderError: Error, Equatable {
    case microphoneDenied
    case notRecording
    case engineFailed(String)
}

/// Ergebnis einer Aufnahme.
///
/// `verloreneHaeppchen` zählt Mikrofon-Häppchen, deren Umrechnung fehlschlug und die deshalb
/// **nicht** in `werte` enthalten sind (Review-Finding 3 zu Task 2: ein Umrechnungsfehler darf
/// nie stillschweigend Diktat-Inhalt verschlucken — vorher hat `try?` im Audio-Callback genau
/// das getan). Im Normalfall `0`. Was der Aufrufer daraus macht (Fehler anzeigen, Aufnahme
/// verwerfen, nur loggen), ist bewusst nicht hier entschieden — aber er kann es nicht mehr
/// *nicht wissen*.
public struct AudioRecording: Sendable, Equatable {
    public let werte: [Float]
    public let verloreneHaeppchen: Int

    public init(werte: [Float], verloreneHaeppchen: Int = 0) {
        self.werte = werte
        self.verloreneHaeppchen = verloreneHaeppchen
    }
}

/// Nimmt Ton auf und liefert ihn im Format der Engine: 16 kHz, mono, Float32.
public protocol AudioRecorder: Sendable {
    func start() async throws
    /// Beendet die Aufnahme und liefert die gesammelten Werte (s. ``AudioRecording``).
    func stop() async throws -> AudioRecording
}

/// Die echte Aufnahme über ``AVAudioEngine``.
///
/// Der Audio-Callback läuft auf einem Echtzeit-Thread: Er darf **nichts** Langsames tun (keine
/// Sperren, keine Speicheranforderungen, wenn vermeidbar). Deshalb sammelt er nur, die
/// Umrechnung passiert im selben Zug über den ``AudioResampler`` (reine Rechnung, kein I/O),
/// und alles Weitere geschieht erst nach ``stop()``.
public actor AVAudioEngineRecorder: AudioRecorder {
    private let engine = AVAudioEngine()
    private var resampler: AudioResampler?

    /// Zustand des Recorders. `.startet` ist bewusst von `.laeuft` unterschieden: Er markiert
    /// das Fenster zwischen „reserviert" und „Tap tatsächlich installiert" — s. `start()`.
    private enum Zustand: Equatable {
        case gestoppt
        case startet
        case laeuft
    }
    private var zustand: Zustand = .gestoppt

    /// Mikrofon-Berechtigungsprüfung. Für Tests überschreibbar (Default: die echte TCC-Abfrage
    /// über `AVCaptureDevice`) — genau der `await`, der laut Review-Finding 1 zu Task 2 das
    /// Reentrancy-Fenster in `start()` öffnet, wenn man ihn *vor* der Zustandsreservierung
    /// aufruft. Die Injektion erlaubt, diese Absicherung ohne echtes Mikrofon zu prüfen (s.
    /// `AudioRecorderTests`).
    private let mikrofonPruefung: @Sendable () async -> Bool

    /// Geteilter Zwischenspeicher zwischen Audio-Thread und Actor. Zählt zusätzlich Häppchen,
    /// deren Umrechnung fehlschlug (Review-Finding 3 zu Task 2) — `stop()` meldet das über
    /// ``AudioRecording/verloreneHaeppchen``, statt es wie zuvor stillschweigend zu verwerfen.
    /// `internal` (nicht `private`), damit `AudioRecorderTests` die Threadsicherheit von
    /// `append`/`fehlerVermerken` direkt prüfen kann, ohne echte Hardware zu benötigen.
    final class Sammler: @unchecked Sendable {
        private let lock = NSLock()
        private var werte: [Float] = []
        private var haeppchenFehler = 0

        func append(_ neue: [Float]) {
            lock.lock(); werte += neue; lock.unlock()
        }

        /// Vermerkt ein Häppchen, dessen Umrechnung fehlschlug. Threadsicher über denselben
        /// Lock wie `append`, absichtlich ohne jede Fehlerdetail-Erfassung: Der Echtzeit-Thread
        /// darf hierfür nichts Langsames tun (keine Allokation, kein String, kein Logging).
        func fehlerVermerken() {
            lock.lock(); haeppchenFehler += 1; lock.unlock()
        }

        func leeren() -> (werte: [Float], haeppchenFehler: Int) {
            lock.lock()
            defer { werte = []; haeppchenFehler = 0; lock.unlock() }
            return (werte, haeppchenFehler)
        }
    }
    private let sammler = Sammler()

    public init() {
        mikrofonPruefung = Self.mikrofonErlaubt
    }

    /// Nur für Tests: erlaubt, die Berechtigungsprüfung durch eine Attrappe zu ersetzen, ohne
    /// echte Hardware oder TCC-Dialoge anzufassen (s. `AudioRecorderTests`).
    init(mikrofonPruefung: @escaping @Sendable () async -> Bool) {
        self.mikrofonPruefung = mikrofonPruefung
    }

    public func start() async throws {
        guard zustand == .gestoppt else { return }

        // Reservierung *vor* dem ersten `await` (Review-Finding 1 zu Task 2): Zwischen der
        // Prüfung oben und dieser Zeile liegt kein Suspension-Punkt, der Actor kann also nicht
        // dazwischen zu einem zweiten, überlappenden `start()`-Aufruf umschalten. Würde
        // `zustand` erst nach der Berechtigungsprüfung gesetzt (wie ursprünglich), könnte ein
        // zweiter Aufruf denselben obersten Guard ebenfalls passieren, während der erste noch in
        // `await mikrofonPruefung()` hängt — jedes `await` auf eine nichtisolierte Funktion
        // verlässt den Actor-Executor, auch im schnellen `.authorized`-Pfad. Beide Aufrufe
        // würden dann am Ende `installTap(onBus: 0, …)` auf demselben Bus aufrufen; das lässt
        // `AVAudioEngine` nicht zu und quittiert es mit einem Laufzeitabbruch (kein fangbarer
        // Swift-Fehler). `.startet` ist bewusst von `.laeuft` unterschieden: Ein `stop()` in
        // diesem Fenster (Tap noch nicht installiert) soll sauber `.notRecording` werfen, statt
        // eine halb aufgebaute Aufnahme abzureißen.
        zustand = .startet

        do {
            // Berechtigung: Ohne sie liefert das Mikrofon nur Stille — wir wollen den echten Grund.
            guard await mikrofonPruefung() else {
                throw AudioRecorderError.microphoneDenied
            }

            _ = sammler.leeren()

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw AudioRecorderError.engineFailed("Kein Eingabegerät verfügbar")
            }

            // Pro Aufnahme ein frischer Resampler: Er behält seinen Konverter-Zustand
            // (Filter-Verzögerungsleitung) über die gesamte Aufnahme hinweg und ist nach dem
            // `finish()` in `stop()` verbraucht. Über zwei Aufnahmen hinweg wiederverwendet
            // würde die zweite still leer bleiben.
            let resampler: AudioResampler
            do {
                resampler = try AudioResampler(inputFormat: format)
            } catch {
                throw AudioRecorderError.engineFailed("Format nicht umrechenbar: \(format)")
            }
            self.resampler = resampler

            let sammler = self.sammler
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { puffer, _ in
                // Läuft auf dem Audio-Thread. Nur rechnen und anhängen — sonst nichts.
                // Ein Umrechnungsfehler wird nicht mehr stillschweigend verschluckt
                // (Review-Finding 3 zu Task 2, vorher `try?`): er wird threadsicher gezählt und
                // von `stop()` über `AudioRecording.verloreneHaeppchen` gemeldet, damit ein
                // Diktat nie unbemerkt kürzer wird.
                do {
                    let neue = try resampler.append(puffer)
                    sammler.append(neue)
                } catch {
                    sammler.fehlerVermerken()
                }
            }

            do {
                engine.prepare()
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw AudioRecorderError.engineFailed(error.localizedDescription)
            }

            zustand = .laeuft
        } catch {
            // Jeder Fehlerpfad oben lässt den Recorder wieder startbar zurück, statt
            // dauerhaft in `.startet` verklemmt zu bleiben.
            zustand = .gestoppt
            throw error
        }
    }

    public func stop() async throws -> AudioRecording {
        guard zustand == .laeuft else { throw AudioRecorderError.notRecording }
        zustand = .gestoppt

        // Reihenfolge ist hier sicherheitsrelevant (Review-Finding 2 zu Task 2): `AudioResampler`
        // ist dokumentiert nicht threadsicher — `append` oben läuft ausschließlich im seriellen
        // Audio-Callback, `finish()` unten dagegen im Actor-Kontext. Sicher ist das nur, weil
        // beides hier nacheinander passiert, nicht nebenläufig: `removeTap` entfernt den Tap aus
        // dem Rendergraphen, und `engine.stop()` stoppt laut Header-Dokumentation „the audio
        // hardware and the engine" — das ist der synchrone Stopp des Core-Audio-I/O-Threads,
        // auf dem der Tap-Block läuft. Erst *danach*, garantiert ohne einen noch laufenden oder
        // folgenden Callback, wird unten `finish()` gerufen. Diese Reihenfolge (Tap entfernen →
        // Engine stoppen → erst dann `finish()`) darf nicht vertauscht werden.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let (gesammelt, haeppchenFehler) = sammler.leeren()
        var ergebnis = gesammelt

        // Der Konverter hält am Ende der Aufnahme noch Restsamples in seiner internen
        // Filter-Verzögerungsleitung zurück (siehe `AudioResampler`-Dokumentation). Ohne
        // diesen Flush fehlen die letzten Millisekunden jeder Aufnahme — `finish()` muss
        // deshalb genau einmal hier aufgerufen werden, danach ist der Resampler verbraucht.
        if let resampler {
            do {
                ergebnis += try resampler.finish()
            } catch {
                throw AudioRecorderError.engineFailed("Restsamples konnten nicht verarbeitet werden: \(error)")
            }
        }
        self.resampler = nil

        return AudioRecording(werte: ergebnis, verloreneHaeppchen: haeppchenFehler)
    }

    private static func mikrofonErlaubt() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Beim ersten Mal zeigt macOS hier seinen Dialog.
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
