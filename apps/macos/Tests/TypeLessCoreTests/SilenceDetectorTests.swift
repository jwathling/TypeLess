import Foundation
import Testing
@testable import TypeLessCore

@Test func digitaleNullIstStille() {
    #expect(SilenceDetector.isSilent([Float](repeating: 0, count: 16_000)))
}

@Test func leeresSignalIstStille() {
    #expect(SilenceDetector.isSilent([]))
}

@Test func normaleSprachlautstaerkeIstKeineStille() {
    // Sprache liegt typisch bei -20 bis -6 dBFS. 0,1 ≈ -20 dBFS.
    let samples = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.1 }
    #expect(!SilenceDetector.isSilent(samples))
}

@Test func sehrLeisesSprechenIstKeineStille() {
    // Der Schwellwert darf leises Sprechen NICHT verwerfen. 0,01 ≈ -40 dBFS,
    // deutlich über der Schwelle von -50 dBFS.
    let samples = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.01 }
    #expect(!SilenceDetector.isSilent(samples), "leises Sprechen darf nicht als Stille gelten")
}

@Test func mikrofonrauschenIstStille() {
    // Ein stummgeschaltetes Mikrofon liefert nicht exakt null, sondern winziges Rauschen.
    var generator = SystemRandomNumberGenerator()
    let samples = (0..<16_000).map { _ in Float.random(in: -0.0005...0.0005, using: &generator) }
    #expect(SilenceDetector.isSilent(samples))
}

@Test func einzelnerKnacksIstKeineStille() {
    // Spitzenpegel, nicht Durchschnitt: Ein einzelner lauter Wert genügt.
    var samples = [Float](repeating: 0, count: 16_000)
    samples[5_000] = 0.5
    #expect(!SilenceDetector.isSilent(samples))
}
