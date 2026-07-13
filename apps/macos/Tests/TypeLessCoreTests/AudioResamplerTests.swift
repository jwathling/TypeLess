import AVFoundation
import Testing
@testable import TypeLessCore

/// Erzeugt einen Sinuston als PCM-Puffer — unsere Referenz, gegen die wir messen.
private func sinusPuffer(frequenz: Double, sekunden: Double,
                         rate: Double, kanaele: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                               channels: kanaele, interleaved: false)!
    let frames = AVAudioFrameCount(rate * sekunden)
    let puffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    puffer.frameLength = frames
    for kanal in 0..<Int(kanaele) {
        let daten = puffer.floatChannelData![kanal]
        for i in 0..<Int(frames) {
            daten[i] = Float(sin(2.0 * .pi * frequenz * Double(i) / rate))
        }
    }
    return puffer
}

/// Misst die dominante Frequenz über die Nulldurchgänge — ein voller Zyklus hat zwei.
private func gemesseneFrequenz(_ samples: [Float], rate: Double) -> Double {
    var nulldurchgaenge = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
        nulldurchgaenge += 1
    }
    return Double(nulldurchgaenge) / 2.0 / (Double(samples.count) / rate)
}

@Test func rechnetStereoAufMonoUndSenktDieAbtastrate() throws {
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 1.0, rate: 48_000, kanaele: 2)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    let samples = try resampler.append(eingabe)

    // 1 s bei 16 kHz = 16000 Werte. Der Konverter darf um ein paar Frames danebenliegen.
    #expect(abs(samples.count - 16_000) < 100)
}

@Test func erhaeltDieTonhoehe() throws {
    // Der eigentliche Test: Eine falsche Abtastraten-Umrechnung verschiebt die Tonhöhe —
    // das stürzt nicht ab, es macht nur die Transkription still schlechter.
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 1.0, rate: 48_000, kanaele: 2)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    let samples = try resampler.append(eingabe)

    let gemessen = gemesseneFrequenz(samples, rate: AudioResampler.targetSampleRate)
    #expect(abs(gemessen - 440.0) < 5.0, "Tonhöhe verschoben: \(gemessen) Hz statt 440 Hz")
}

@Test func verarbeitetMehrereTeilpufferNacheinander() throws {
    // Das Mikrofon liefert die Aufnahme in kleinen Häppchen, nicht am Stück.
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                               channels: 2, interleaved: false)!
    let resampler = try AudioResampler(inputFormat: format)

    var alle: [Float] = []
    for _ in 0..<10 {
        let haeppchen = sinusPuffer(frequenz: 440, sekunden: 0.1, rate: 48_000, kanaele: 2)
        alle += try resampler.append(haeppchen)
    }

    #expect(abs(alle.count - 16_000) < 200, "10 × 0,1 s müssen ~1 s bei 16 kHz ergeben")
}

@Test func kommtMitMonoQuelleZurecht() throws {
    // Manche Mikrofone liefern direkt mono.
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 0.5, rate: 44_100, kanaele: 1)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    let samples = try resampler.append(eingabe)

    #expect(abs(samples.count - 8_000) < 100)
    #expect(abs(gemesseneFrequenz(samples, rate: 16_000) - 440.0) < 5.0)
}
