import AVFoundation

public enum AudioRecorderError: Error, Equatable {
    case microphoneDenied
    case notRecording
    case engineFailed(String)
}

/// Nimmt Ton auf und liefert ihn im Format der Engine: 16 kHz, mono, Float32.
public protocol AudioRecorder: Sendable {
    func start() async throws
    /// Beendet die Aufnahme und liefert die gesammelten Werte.
    func stop() async throws -> [Float]
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
    private var laeuft = false

    /// Geteilter Zwischenspeicher zwischen Audio-Thread und Actor.
    private final class Sammler: @unchecked Sendable {
        private let lock = NSLock()
        private var werte: [Float] = []

        func append(_ neue: [Float]) {
            lock.lock(); werte += neue; lock.unlock()
        }

        func leeren() -> [Float] {
            lock.lock(); defer { werte = []; lock.unlock() }
            return werte
        }
    }
    private let sammler = Sammler()

    public init() {}

    public func start() async throws {
        guard !laeuft else { return }

        // Berechtigung: Ohne sie liefert das Mikrofon nur Stille — wir wollen den echten Grund.
        guard await Self.mikrofonErlaubt() else {
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
            if let neue = try? resampler.append(puffer) {
                sammler.append(neue)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }
        laeuft = true
    }

    public func stop() async throws -> [Float] {
        guard laeuft else { throw AudioRecorderError.notRecording }
        laeuft = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        var ergebnis = sammler.leeren()

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
        resampler = nil

        return ergebnis
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
