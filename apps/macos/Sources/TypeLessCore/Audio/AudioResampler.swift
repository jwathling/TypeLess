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
/// Nicht `Sendable`: Wird ausschließlich aus dem Audio-Callback benutzt, der seriell ist.
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
    public func append(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        // Großzügig dimensionieren: Der Konverter kann durch seinen internen Puffer mehr
        // Frames liefern, als die reine Rechnung erwarten ließe.
        let kapazitaet = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let ausgabe = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                             frameCapacity: kapazitaet) else {
            throw AudioResamplerError.converterUnavailable
        }

        // Jeder Aufruf von `append` behandelt seinen Puffer als vollständige, in sich
        // geschlossene Umrechnung — nicht als Ausschnitt eines fortlaufenden Streams. Ohne
        // `reset()` würde der Konverter Zustand (Filter-Verzögerungsleitung) vom vorherigen
        // Aufruf mitschleppen; ohne `.endOfStream` beim zweiten Block-Aufruf hält der Konverter
        // die letzten ~1000 von 16000 Samples zurück, weil er annimmt, es könnte noch mehr
        // Eingabe für dasselbe Fenster kommen (`.noDataNow` bedeutet „gerade nichts da, aber
        // vielleicht später" — das genaue Gegenteil dessen, was wir hier wollen). Gemessen:
        // Mit `.noDataNow` allein liefert ein einzelner 1-s-Puffer nur 15013 statt 16000 Werte.
        converter.reset()

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
                // Der Puffer ist die gesamte Eingabe für diesen Aufruf — `.endOfStream` zwingt
                // den Konverter, seine intern zurückgehaltenen Restsamples jetzt auszugeben,
                // statt auf einen (hier nie kommenden) nächsten Block zu warten.
                outStatus.pointee = .endOfStream
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
}
