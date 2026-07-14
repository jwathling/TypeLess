import AVFoundation

public enum AudioResamplerError: Error, Equatable {
    case converterUnavailable
    case conversionFailed(String)
}

/// Rechnet das Format des Mikrofons in das Format um, das die Engine erwartet:
/// **16 kHz, mono, Float32** (siehe M2, `/process`).
///
/// Das Eingabegerät liefert üblicherweise 44,1 oder 48 kHz, oft stereo. Ein Fehler in dieser
/// Umrechnung stürzt nicht ab — er verschiebt die Tonhöhe und macht die Transkription
/// stillschweigend schlechter. Deshalb ist sie mit einem Messtest abgesichert.
///
/// **Streaming-Kontrakt:** `append` wird für jedes Mikrofon-Häppchen (typisch 4096 Frames)
/// aufgerufen und **erhält den Konverter-Zustand über Aufrufe hinweg** — die interne
/// Filter-Verzögerungsleitung von `AVAudioConverter` bleibt zwischen zwei Häppchen bestehen.
/// Ein Reset oder erzwungenes Flushen pro Häppchen würde diese Kontinuität an jeder
/// Häppchengrenze zerstören (gemessen: lokales SNR bricht von 52 dB auf 25 dB ein — siehe
/// `AudioResamplerTests`). Erst `finish()` am echten Ende der Aufnahme flusht einmalig.
///
/// Nicht `Sendable`: `append` läuft ausschließlich im seriellen Audio-Callback. `finish()`
/// wird genau einmal von einem anderen Kontext gerufen (dem Actor, in
/// `AVAudioEngineRecorder.stop()`) — sicher ist das nur, weil der Aufrufer zu diesem Zeitpunkt
/// bereits den Tap entfernt **und** die Engine gestoppt hat, bevor er `finish()` ruft (s.
/// Kommentar dort). Vor oder parallel zu dieser Reihenfolge darf `finish()` nicht aufgerufen
/// werden — sonst griffen Audio-Thread und Aufrufer gleichzeitig auf denselben
/// `AVAudioConverter` zu.
public final class AudioResampler {
    public static let targetSampleRate: Double = 16_000

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    public init(inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioResamplerError.converterUnavailable
        }
        self.converter = converter
        self.outputFormat = outputFormat
        ratio = Self.targetSampleRate / inputFormat.sampleRate
    }

    /// Nimmt ein Häppchen vom Mikrofon und liefert die daraus entstandenen 16-kHz-Mono-Werte.
    ///
    /// Rechnet nur das um, was der Konverter aus **diesem** Häppchen sofort liefern kann;
    /// zurückgehaltene Restsamples (Filter-Verzögerungsleitung) bleiben im Konverter und
    /// erscheinen entweder im nächsten `append`-Aufruf oder bei `finish()`. Das ist beabsichtigt
    /// — siehe Typ-Dokumentation.
    public func append(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        // Großzügig dimensionieren: Der Konverter kann durch seinen internen Puffer mehr
        // Frames liefern, als die reine Rechnung erwarten ließe.
        let kapazitaet = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let ausgabe = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: kapazitaet) else {
            throw AudioResamplerError.converterUnavailable
        }

        // Kein `converter.reset()` und kein `.endOfStream` hier: Beides würde die interne
        // Filter-Verzögerungsleitung des Konverters kappen, als wäre dieses Häppchen die
        // gesamte Aufnahme. `.noDataNow` beim zweiten Block-Aufruf sagt dem Konverter korrekt
        // „für jetzt nichts mehr, aber der Strom geht weiter" — er darf Restsamples intern
        // zurückhalten, statt sie mit Klicks an der Häppchengrenze zu erzwingen.
        //
        // `AVAudioConverterInputBlock` ist als `@Sendable` deklariert, wird von `convert` aber
        // synchron auf dem aufrufenden Thread aufgerufen (kein echter Thread-Wechsel) — daher
        // ist die Sendable-Prüfung des Compilers hier ein Fehlalarm. `nonisolated(unsafe)`
        // dokumentiert das bewusst, statt die Warnung mit `@preconcurrency` pauschal zu
        // unterdrücken.
        nonisolated(unsafe) var geliefert = false
        nonisolated(unsafe) let eingabe = buffer
        var fehler: NSError?
        let status = converter.convert(to: ausgabe, error: &fehler) { _, outStatus in
            if geliefert {
                outStatus.pointee = .noDataNow
                return nil
            }
            geliefert = true
            outStatus.pointee = .haveData
            return eingabe
        }

        if status == .error {
            throw AudioResamplerError.conversionFailed(fehler?.localizedDescription ?? "unbekannt")
        }

        guard let daten = ausgabe.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: daten, count: Int(ausgabe.frameLength)))
    }

    /// Flusht den Konverter einmalig am echten Ende der Aufnahme und liefert die dabei
    /// zurückgehaltenen Restsamples. Nach diesem Aufruf ist der Resampler verbraucht — ein
    /// weiterer `append`- oder `finish()`-Aufruf ist nicht vorgesehen (der Konverter selbst
    /// befindet sich danach im Endzustand seines Eingabestroms).
    public func finish() throws -> [Float] {
        // Der Rest kann über mehrere Blockaufrufe verteilt sein, deshalb in einer Schleife
        // abholen, bis der Konverter selbst `.endOfStream` meldet oder nichts mehr liefert.
        var alle: [Float] = []
        let kapazitaet: AVAudioFrameCount = 4_096
        var beendet = false

        while !beendet {
            guard let ausgabe = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                 frameCapacity: kapazitaet) else {
                throw AudioResamplerError.converterUnavailable
            }

            var fehler: NSError?
            let status = converter.convert(to: ausgabe, error: &fehler) { _, outStatus in
                // Es gibt keine neue Eingabe mehr — `.endOfStream` sofort beim ersten
                // Blockaufruf zwingt den Konverter, alle verbliebenen Restsamples auszugeben.
                outStatus.pointee = .endOfStream
                return nil
            }

            if status == .error {
                throw AudioResamplerError.conversionFailed(fehler?.localizedDescription ?? "unbekannt")
            }

            if let daten = ausgabe.floatChannelData?[0], ausgabe.frameLength > 0 {
                alle += Array(UnsafeBufferPointer(start: daten, count: Int(ausgabe.frameLength)))
            }

            beendet = status == .endOfStream || ausgabe.frameLength == 0
        }

        return alle
    }
}
