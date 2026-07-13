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

/// Zerlegt einen Puffer in aufeinanderfolgende Häppchen fester Größe (das letzte ggf.
/// kleiner) — simuliert, wie das Mikrofon in der echten App Audio blockweise liefert
/// (typisch 4096 Frames ≈ 85 ms).
private func inHaeppchenZerlegt(_ puffer: AVAudioPCMBuffer,
                                groesse: AVAudioFrameCount) -> [AVAudioPCMBuffer] {
    var haeppchen: [AVAudioPCMBuffer] = []
    let gesamt = puffer.frameLength
    var start: AVAudioFrameCount = 0
    while start < gesamt {
        let laenge = min(groesse, gesamt - start)
        let teil = AVAudioPCMBuffer(pcmFormat: puffer.format, frameCapacity: laenge)!
        teil.frameLength = laenge
        for kanal in 0..<Int(puffer.format.channelCount) {
            let quelle = puffer.floatChannelData![kanal]
            let ziel = teil.floatChannelData![kanal]
            for i in 0..<Int(laenge) {
                ziel[i] = quelle[Int(start) + i]
            }
        }
        haeppchen.append(teil)
        start += laenge
    }
    return haeppchen
}

/// Misst die dominante Frequenz über die Nulldurchgänge — ein voller Zyklus hat zwei.
private func gemesseneFrequenz(_ samples: [Float], rate: Double) -> Double {
    var nulldurchgaenge = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
        nulldurchgaenge += 1
    }
    return Double(nulldurchgaenge) / 2.0 / (Double(samples.count) / rate)
}

/// Lokales Signal-Rausch-Verhältnis in nicht überlappenden Fenstern fester Größe — deckt
/// Einbrüche auf, die ein einziger globaler SNR-Wert über das gesamte Signal wegmitteln würde
/// (genau das, was an Häppchengrenzen passiert, wenn die Filter-Kontinuität verloren geht).
/// Liefert das Minimum über alle Fenster.
private func minimalesLokalesSNR(_ ist: [Float], _ soll: [Float], fenster: Int) -> Double {
    precondition(ist.count == soll.count, "Längen müssen für einen Sample-für-Sample-Vergleich übereinstimmen")
    var minSNR = Double.infinity
    var start = 0
    while start < soll.count {
        let ende = min(start + fenster, soll.count)
        var signalEnergie = 0.0
        var fehlerEnergie = 0.0
        for i in start..<ende {
            let s = Double(soll[i])
            let f = Double(ist[i]) - s
            signalEnergie += s * s
            fehlerEnergie += f * f
        }
        if fehlerEnergie > 0 {
            let snr = 10.0 * log10(signalEnergie / fehlerEnergie)
            minSNR = min(minSNR, snr)
        }
        start = ende
    }
    return minSNR
}

@Test func rechnetStereoAufMonoUndSenktDieAbtastrate() throws {
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 1.0, rate: 48_000, kanaele: 2)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    // Ein Häppchen ist keine ganze Aufnahme mehr: `append` liefert nur, was der Konverter
    // sofort hergibt, den Rest holt `finish()` am (hier sofortigen) Aufnahmeende.
    var samples = try resampler.append(eingabe)
    samples += try resampler.finish()

    // 1 s bei 16 kHz = 16000 Werte. Der Konverter darf um ein paar Frames danebenliegen.
    #expect(abs(samples.count - 16_000) < 100)
}

@Test func erhaeltDieTonhoehe() throws {
    // Der eigentliche Test: Eine falsche Abtastraten-Umrechnung verschiebt die Tonhöhe —
    // das stürzt nicht ab, es macht nur die Transkription still schlechter.
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 1.0, rate: 48_000, kanaele: 2)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    var samples = try resampler.append(eingabe)
    samples += try resampler.finish()

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
    alle += try resampler.finish()

    #expect(abs(alle.count - 16_000) < 200, "10 × 0,1 s müssen ~1 s bei 16 kHz ergeben")
}

@Test func kommtMitMonoQuelleZurecht() throws {
    // Manche Mikrofone liefern direkt mono.
    let eingabe = sinusPuffer(frequenz: 440, sekunden: 0.5, rate: 44_100, kanaele: 1)
    let resampler = try AudioResampler(inputFormat: eingabe.format)

    var samples = try resampler.append(eingabe)
    samples += try resampler.finish()

    #expect(abs(samples.count - 8_000) < 100)
    #expect(abs(gemesseneFrequenz(samples, rate: 16_000) - 440.0) < 5.0)
}

@Test func erhaeltFilterKontinuitaetUeberHaeppchengrenzenHinweg() throws {
    // Regressionstest für den vom Reviewer empirisch gemessenen Fund: Wenn `append()` den
    // Konverter bei jedem Aufruf zurücksetzt und zwangsweise flusht, geht die Kontinuität der
    // Filter-Verzögerungsleitung an jeder Häppchengrenze verloren — messbar als Einbruch des
    // lokalen SNR (gemessen: 25,3 dB statt 52,3 dB bei einem 3-s-Ton in 4096-Frame-Häppchen,
    // 48 kHz Stereo). Referenz: dasselbe Signal in einem einzigen `append()`-Aufruf.
    let vollstaendig = sinusPuffer(frequenz: 440, sekunden: 3.0, rate: 48_000, kanaele: 2)

    let referenzResampler = try AudioResampler(inputFormat: vollstaendig.format)
    var referenz = try referenzResampler.append(vollstaendig)
    referenz += try referenzResampler.finish()

    let haeppchenResampler = try AudioResampler(inputFormat: vollstaendig.format)
    var haeppchenweise: [Float] = []
    for haeppchen in inHaeppchenZerlegt(vollstaendig, groesse: 4_096) {
        haeppchenweise += try haeppchenResampler.append(haeppchen)
    }
    haeppchenweise += try haeppchenResampler.finish()

    #expect(haeppchenweise.count == referenz.count,
            "Häppchenweise Umrechnung liefert \(haeppchenweise.count) statt \(referenz.count) Samples — sollte mit erhaltenem Konverter-Zustand exakt übereinstimmen")

    // Auf gemeinsame Länge kürzen, bevor wir vergleichen: Eine kaputte Implementierung kann
    // (wie oben belegt) auch eine andere Sample-Anzahl liefern — das SNR soll trotzdem ohne
    // Programmabsturz messbar bleiben, nicht an einer Längenprüfung hart scheitern.
    let vergleichslaenge = min(haeppchenweise.count, referenz.count)

    // Fenster von 400 Samples (25 ms bei 16 kHz) ≈ 11 Zyklen bei 440 Hz — groß genug, dass kein
    // Fenster nahe der Signal-Energie null liegt, klein genug, um Einbrüche an den ca. alle
    // 1365 Samples liegenden Häppchengrenzen (4096 Frames × 16000/48000) aufzulösen.
    let minSNR = minimalesLokalesSNR(Array(haeppchenweise.prefix(vergleichslaenge)),
                                     Array(referenz.prefix(vergleichslaenge)), fenster: 400)

    // Schwelle bewusst zwischen der defekten (25,3 dB) und der korrekten Variante (52,3 dB)
    // gesetzt: Die alte Implementierung (reset() + .endOfStream je append()) muss hier
    // durchfallen, die korrekte klar bestehen.
    #expect(minSNR > 35.0,
            "Lokales SNR bricht ein: \(minSNR) dB (erwartet: nahe der Referenz, > 35 dB) — Hinweis auf verlorene Filter-Kontinuität an Häppchengrenzen")
}
