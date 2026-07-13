# M4 — Audio, Hotkey und Diktat-Ablauf: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fn-Taste halten, sprechen, loslassen — der fertige Text liegt in der Zwischenablage.

**Architecture:** Vier neue Bausteine in `TypeLessCore`, jeder hinter einem Protokoll: Tastatur-Hook, Aufnahme, Zwischenablage, Koordinator. Der Koordinator ist der Zustandsautomat und wird vollständig mit Attrappen getestet — ohne Mikrofon, ohne Tastatur, ohne Sidecar. Die hardwarenahen Implementierungen sind dünn und werden von Hand verifiziert.

**Tech Stack:** Swift 6.3, AVFoundation (`AVAudioEngine`, `AVAudioConverter`), CoreGraphics (`CGEventTap`), AppKit (`NSPasteboard`, nur in der App-Schicht), Observation, swift-testing.

## Verifizierte Vorbedingungen

Am Zielrechner **gemessen** — nicht erneut in Frage stellen:

- Ein `CGEventTap` (`.cgSessionEventTap`, `.listenOnly`) sieht die Fn-Taste als `flagsChanged` mit `keyCode == 63`; Drücken und Loslassen kommen getrennt (`CGEventFlags.maskSecondaryFn` gesetzt / nicht gesetzt).
- `AppleFnUsageType` steht auf `0` („Keine Aktion"). Die Fn-Taste öffnet **keinen** Emoji-Picker. **Folge: Der Tap liest nur mit und verschluckt nichts** — alle Fn-Kombinationen (Fn+Pfeil, Fn+Entf) bleiben unangetastet.
- `AVAudioConverter` rechnet 48 kHz Stereo → 16 kHz Mono Float32 korrekt um (440-Hz-Sinus gemessen: 439,5 Hz, exakte Länge, Spitzenpegel 1,0). Das Muster `convert(to:error:withInputFrom:)` funktioniert.

## Global Constraints

- Swift 6.3, `swift-tools-version: 6.0`, macOS 14+, strict concurrency. Build **ohne Warnungen**.
- Kommentare und Docstrings auf **Deutsch**.
- `TypeLessCore` importiert **niemals SwiftUI**. AVFoundation/CoreGraphics sind erlaubt; **AppKit nicht** — `NSPasteboard` lebt in `Sources/TypeLess/`.
- Jede austauschbare Komponente steckt hinter einem Protokoll. Die einzige Stelle, die konkrete Typen kennt, ist die Komposition in `TypeLessApp.swift`.
- Keine festen Wartezeiten (`sleep`) in Tests. Harte Obergrenze über `.timeLimit(...)`.
- Die bestehenden **46 Tests** müssen grün bleiben.
- **Sidecar-Vertrag (M2), unverhandelbar:** `refined: false` ist **kein** Fehler — der Text geht trotzdem in die Zwischenablage. Ein Diktat darf nie verloren gehen.
- **Entscheidung des Anwenders, unverhandelbar:** Kein Overlay, keine Töne. Daraus folgt: **Bei jedem Fehlschlag bleibt die Zwischenablage unangetastet** — der Nutzer bekommt dann beim ⌘V seinen alten Inhalt statt Leere.

## File Structure

| Datei | Verantwortung |
|---|---|
| `Sources/TypeLessCore/Audio/AudioResampler.swift` | 48 kHz Stereo → 16 kHz Mono Float32. Reine Rechnung, keine Hardware. |
| `Sources/TypeLessCore/Audio/SilenceDetector.swift` | Spitzenpegel prüfen: Ist die Aufnahme faktisch tonlos? |
| `Sources/TypeLessCore/Audio/AudioRecorder.swift` | Protokoll + `AVAudioEngineRecorder` (echtes Mikrofon) |
| `Sources/TypeLessCore/Hotkey/HotkeyMonitor.swift` | Protokoll + `FnKeyMonitor` (CGEventTap, nur mitlesend, macht sich selbst wieder scharf) |
| `Sources/TypeLessCore/Dictation/Pasteboard.swift` | Protokoll (Implementierung in der App-Schicht) |
| `Sources/TypeLessCore/Dictation/DictationCoordinator.swift` | Der Zustandsautomat. Das Herzstück. |
| `Sources/TypeLess/SystemPasteboard.swift` | `NSPasteboard` — hält AppKit aus der Bibliothek |
| `Sources/TypeLess/MenuContent.swift` | erweitert: Symbol und Text aus **beiden** Zustandsachsen |
| `Sources/TypeLess/TypeLessApp.swift` | erweitert: Komposition des Koordinators |

---

### Task 1: Audio-Umrechnung und Stille-Erkennung

Die stillste Fehlerquelle des Meilensteins: Ein Fehler hier stürzt nicht ab, er liefert nur
schlechtere Transkription. Deshalb zuerst, und mit einem echten Messtest.

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Audio/AudioResampler.swift`
- Create: `apps/macos/Sources/TypeLessCore/Audio/SilenceDetector.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/AudioResamplerTests.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/SilenceDetectorTests.swift`

**Interfaces:**
- Consumes: nichts.
- Produces:
  - `final class AudioResampler` mit `init(inputFormat: AVAudioFormat) throws`, `func append(_ buffer: AVAudioPCMBuffer) throws -> [Float]`, `static let targetSampleRate: Double = 16_000`
  - `enum AudioResamplerError: Error, Equatable { case converterUnavailable, conversionFailed(String) }`
  - `enum SilenceDetector { static let thresholdDBFS: Float = -50; static func peak(_ samples: [Float]) -> Float; static func isSilent(_ samples: [Float]) -> Bool }`

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/AudioResamplerTests.swift`:

```swift
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
```

`apps/macos/Tests/TypeLessCoreTests/SilenceDetectorTests.swift`:

```swift
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
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'AudioResampler' in scope"

- [ ] **Step 3: Resampler implementieren**

`apps/macos/Sources/TypeLessCore/Audio/AudioResampler.swift`:

```swift
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

        var geliefert = false
        var fehler: NSError?
        let status = converter.convert(to: ausgabe, error: &fehler) { _, outStatus in
            if geliefert {
                // Kein weiteres Material: Der Konverter soll nur ausgeben, was er schon hat.
                outStatus.pointee = .noDataNow
                return nil
            }
            geliefert = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw AudioResamplerError.conversionFailed(fehler?.localizedDescription ?? "unbekannt")
        }

        guard let daten = ausgabe.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: daten, count: Int(ausgabe.frameLength)))
    }
}
```

- [ ] **Step 4: Stille-Erkennung implementieren**

`apps/macos/Sources/TypeLessCore/Audio/SilenceDetector.swift`:

```swift
import Foundation

/// Beantwortet die Frage: Ist bei dieser Aufnahme überhaupt Ton angekommen?
///
/// Ohne Overlay und ohne Tonsignal (Entscheidung des Anwenders) ist das der einzige
/// Fehlerfall, den der Nutzer sonst erst beim Einfügen bemerkt — nachdem er 30 Sekunden in
/// ein stummgeschaltetes Mikrofon gesprochen hat.
public enum SilenceDetector {
    /// −50 dBFS ≈ 0,00316 in Float32.
    ///
    /// Bewusst niedrig: Ein stummes Mikrofon liefert winziges Rauschen (deutlich darunter),
    /// leises Sprechen dagegen liegt bei etwa −40 dBFS (0,01) — also klar darüber. Der
    /// Schwellwert trennt „nichts angekommen" von „leise gesprochen", nicht „leise" von „laut".
    public static let thresholdDBFS: Float = -50

    private static var thresholdAmplitude: Float {
        pow(10, thresholdDBFS / 20)
    }

    /// Spitzenpegel, **nicht** Durchschnitt: Eine Aufnahme mit einem einzelnen lauten Wort und
    /// viel Pause ist nicht tonlos.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    public static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < thresholdAmplitude
    }
}
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (56 Tests: 46 bestehende + 10 neue)

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "M4: Audio-Umrechnung (16 kHz mono) und Stille-Erkennung"
```

---

### Task 2: Aufnahme

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Audio/AudioRecorder.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/AudioRecorderTests.swift`

**Interfaces:**
- Consumes: `AudioResampler` (Task 1).
- Produces:
  - `protocol AudioRecorder: Sendable { func start() async throws; func stop() async throws -> [Float] }`
  - `enum AudioRecorderError: Error, Equatable { case microphoneDenied, notRecording, engineFailed(String) }`
  - `actor AVAudioEngineRecorder: AudioRecorder` mit `init()`
  - Test-Attrappe `FakeRecorder` (in den Tests), die Task 4 wiederverwendet.

**Was getestet wird und was nicht:** `AVAudioEngineRecorder` fasst echte Hardware an — er wird
**von Hand** verifiziert (Task 5), nicht per Unit-Test. Getestet wird hier nur der Vertrag:
`stop()` ohne `start()` muss sauber scheitern, und die Attrappe muss sich wie das Original
verhalten. Der Wert dieser Task liegt im **Protokoll** — es macht Task 4 vollständig testbar.

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/AudioRecorderTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: liefert vorgegebene Werte, ohne je ein Mikrofon anzufassen.
/// Wird von den Koordinator-Tests (Task 4) wiederverwendet.
actor FakeRecorder: AudioRecorder {
    private var samples: [Float]
    private var fehlerBeimStart: AudioRecorderError?
    private(set) var laeuft = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(samples: [Float] = [], fehlerBeimStart: AudioRecorderError? = nil) {
        self.samples = samples
        self.fehlerBeimStart = fehlerBeimStart
    }

    func setSamples(_ neue: [Float]) { samples = neue }

    func start() async throws {
        startCount += 1
        if let fehlerBeimStart { throw fehlerBeimStart }
        laeuft = true
    }

    func stop() async throws -> [Float] {
        stopCount += 1
        guard laeuft else { throw AudioRecorderError.notRecording }
        laeuft = false
        return samples
    }
}

@Test func stopOhneStartScheitertSauber() async throws {
    let recorder = FakeRecorder()

    await #expect(throws: AudioRecorderError.notRecording) {
        _ = try await recorder.stop()
    }
}

@Test func liefertDieAufgenommenenWerte() async throws {
    let recorder = FakeRecorder(samples: [0.1, 0.2, 0.3])

    try await recorder.start()
    let samples = try await recorder.stop()

    #expect(samples == [0.1, 0.2, 0.3])
    #expect(await recorder.startCount == 1)
    #expect(await recorder.stopCount == 1)
}

@Test func echterRecorderLaesstSichErzeugen() {
    // Mehr geht ohne Mikrofon-Berechtigung nicht — die Handprobe in Task 5 ist der echte Test.
    _ = AVAudioEngineRecorder()
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find type 'AudioRecorder' in scope"

- [ ] **Step 3: Implementieren**

`apps/macos/Sources/TypeLessCore/Audio/AudioRecorder.swift`:

```swift
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
    private var samples: [Float] = []
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
        samples = []

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AudioRecorderError.engineFailed("Kein Eingabegerät verfügbar")
        }

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
        resampler = nil

        return sammler.leeren()
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
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (59 Tests)

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "M4: Audioaufnahme über AVAudioEngine"
```

---

### Task 3: Der Fn-Tastatur-Hook

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Hotkey/HotkeyMonitor.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: nichts.
- Produces:
  - `enum HotkeyEvent: Sendable, Equatable { case pressed, released }`
  - `enum HotkeyError: Error, Equatable { case inputMonitoringDenied }`
  - `protocol HotkeyMonitor: Sendable { func start() throws -> AsyncStream<HotkeyEvent>; func stop() }`
  - `final class FnKeyMonitor: HotkeyMonitor` mit `init()`
  - `static func fnKeyOpensEmojiPicker() -> Bool` (liest `AppleFnUsageType`)
  - Test-Attrappe `FakeHotkey` (in den Tests), die Task 4 wiederverwendet.

**Die zwei Dinge, die hier stillschweigend kaputtgehen können:**
1. **macOS schaltet den Tap eigenmächtig ab** (`.tapDisabledByTimeout`, wenn der Callback zu langsam war; `.tapDisabledByUserInput`). Passiert das unbemerkt, drückt der Nutzer Fn und **nichts geschieht** — für immer. Der Callback muss beide Fälle behandeln und den Tap sofort wieder scharf machen.
2. **Der Callback läuft im Ereignispfad des Systems.** Er darf nichts Langsames tun. Er reicht das Ereignis nur an einen `AsyncStream` weiter — kein Netzwerk, kein Dateizugriff, keine Sperre, die blockieren könnte.

**Der Tap liest nur mit** (`.listenOnly`) und verschluckt nichts — deshalb bleiben Fn+Pfeil und Fn+Entf unangetastet. Das ist nur möglich, weil `AppleFnUsageType == 0` ist (verifiziert).

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/HotkeyMonitorTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: erlaubt dem Test, Tastendrücke zu erfinden. Wird von Task 4 wiederverwendet.
final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    private var fehler: HotkeyError?
    private(set) var gestoppt = false

    init(fehler: HotkeyError? = nil) { self.fehler = fehler }

    func start() throws -> AsyncStream<HotkeyEvent> {
        if let fehler { throw fehler }
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        lock.lock(); self.continuation = continuation; lock.unlock()
        return stream
    }

    func stop() {
        lock.lock()
        gestoppt = true
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    /// Der Test drückt die Taste.
    func send(_ event: HotkeyEvent) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(event)
    }
}

@Test func attrappeLiefertEreignisse() async throws {
    let hotkey = FakeHotkey()
    let stream = try hotkey.start()

    hotkey.send(.pressed)
    hotkey.send(.released)
    hotkey.stop()

    var empfangen: [HotkeyEvent] = []
    for await event in stream { empfangen.append(event) }

    #expect(empfangen == [.pressed, .released])
}

@Test func fehlendeBerechtigungWirdGemeldet() throws {
    let hotkey = FakeHotkey(fehler: .inputMonitoringDenied)

    #expect(throws: HotkeyError.inputMonitoringDenied) {
        _ = try hotkey.start()
    }
}

@Test func erkenntObFnDenEmojiPickerOeffnet() {
    // Reine Systemabfrage — der Test belegt nur, dass sie nicht abstürzt und einen
    // Wert liefert. Auf diesem Rechner steht die Einstellung auf "Keine Aktion".
    _ = FnKeyMonitor.fnKeyOpensEmojiPicker()
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find type 'HotkeyMonitor' in scope"

- [ ] **Step 3: Implementieren**

`apps/macos/Sources/TypeLessCore/Hotkey/HotkeyMonitor.swift`:

```swift
import CoreGraphics
import Foundation

public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released
}

public enum HotkeyError: Error, Equatable {
    /// Ohne „Eingabeüberwachung" liefert ``CGEvent.tapCreate`` nil — der Hotkey ist dann tot.
    case inputMonitoringDenied
}

/// Meldet, wann die Diktat-Taste gedrückt und losgelassen wird.
public protocol HotkeyMonitor: Sendable {
    func start() throws -> AsyncStream<HotkeyEvent>
    func stop()
}

/// Der echte Hook auf die Fn-Taste (🌐), über einen ``CGEventTap``.
///
/// **Nur mitlesend** (`.listenOnly`): Wir verschlucken keine Ereignisse. Deshalb funktionieren
/// Fn+Pfeil, Fn+Entf und alle anderen Fn-Kombinationen völlig unverändert weiter. Das setzt
/// voraus, dass „Beim Drücken der 🌐-Taste" auf „Keine Aktion" steht — sonst öffnet macOS bei
/// jedem Diktat den Emoji-Picker. ``fnKeyOpensEmojiPicker()`` prüft das, die App weist im Menü
/// darauf hin.
public final class FnKeyMonitor: HotkeyMonitor, @unchecked Sendable {
    /// Die Fn-Taste meldet sich als flagsChanged mit diesem Code (gemessen).
    private static let fnKeyCode: Int64 = 63

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?

    public init() {}

    public func start() throws -> AsyncStream<HotkeyEvent> {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        lock.lock(); self.continuation = continuation; lock.unlock()

        // Der Tap braucht einen laufenden RunLoop. Ein eigener Thread hält den Main-Thread
        // frei — der Callback darf das System nicht aufhalten.
        let thread = Thread { [weak self] in
            guard let self else { return }
            do {
                try self.installTap()
                CFRunLoopRun()
            } catch {
                continuation.finish()
            }
        }
        thread.name = "de.typeless.hotkey"
        lock.lock(); self.thread = thread; lock.unlock()
        thread.start()

        return stream
    }

    public func stop() {
        lock.lock()
        let tap = self.tap
        let source = self.runLoopSource
        continuation?.finish()
        continuation = nil
        self.tap = nil
        runLoopSource = nil
        lock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopSourceInvalidate(source) }
        thread = nil
    }

    private func installTap() throws {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let selbst = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,        // wir verschlucken NICHTS
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selbst
        ) else {
            throw HotkeyError.inputMonitoringDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock(); self.tap = tap; runLoopSource = source; lock.unlock()
    }

    /// Läuft im Ereignispfad des Systems — hier darf **nichts** Langsames passieren.
    private func handle(type: CGEventType, event: CGEvent) {
        // macOS schaltet den Tap eigenmächtig ab, wenn der Callback zu langsam war. Merkt man
        // das nicht, klemmt der Hotkey ab da still und für immer. Also sofort wieder scharf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = self.tap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else {
            return
        }

        let gedrueckt = event.flags.contains(.maskSecondaryFn)
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(gedrueckt ? .pressed : .released)
    }

    /// Öffnet ein Druck auf die Fn-Taste den Emoji-Picker (oder etwas anderes)?
    ///
    /// `AppleFnUsageType`: 0 = keine Aktion, 1 = Eingabequelle wechseln, 2 = Emoji-Picker,
    /// 3 = Systemdiktat. Nur bei 0 stört die Taste unser Diktat nicht. Die App **ändert**
    /// diese Einstellung nicht — sie weist im Menü darauf hin.
    public static func fnKeyOpensEmojiPicker() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        guard let wert = defaults?.object(forKey: "AppleFnUsageType") as? Int else {
            return false   // nicht gesetzt = Standard, stört nicht
        }
        return wert != 0
    }
}
```

- [ ] **Step 4: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (62 Tests)

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "M4: Fn-Tastatur-Hook (mitlesend, macht sich nach Abschaltung selbst wieder scharf)"
```

---

### Task 4: Der Diktat-Koordinator

Das Herzstück. Hier wird der Vertrag eingelöst, den der Anwender gewählt hat.

**Files:**
- Create: `apps/macos/Sources/TypeLessCore/Dictation/Pasteboard.swift`
- Create: `apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`
- Create: `apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `HotkeyMonitor`, `HotkeyEvent`, `HotkeyError` (Task 3); `AudioRecorder`, `AudioRecorderError` (Task 2); `SilenceDetector` (Task 1); `SidecarClient`, `SidecarError`, `Mode`, `ProcessResult` (M3).
- Produces:
  - `protocol Pasteboard: Sendable { func write(_ text: String) }`
  - `enum SessionState: Sendable, Equatable { case idle, recording, processing, failed(String) }`
  - `@MainActor @Observable final class DictationCoordinator` mit
    `init(hotkey: HotkeyMonitor, recorder: AudioRecorder, client: SidecarClient, pasteboard: Pasteboard, minimumSampleCount: Int = 4_800)`,
    `var session: SessionState` (nur lesbar), `func start() async`, `func stop() async`

**Die Regeln, die die Tests festnageln müssen:**
- Drücken startet Aufnahme **und** `/preload` (nebenläufig). Ein **gescheiterter Preload verhindert das Diktat nicht**.
- Zu kurz (< 300 ms ≙ 4800 Werte bei 16 kHz): kommentarlos verwerfen. Kein Zustandswechsel nach `failed`.
- Stille: `.failed(…)`, und die **Zwischenablage bleibt unangetastet**.
- Jeder Fehler: Zwischenablage **unangetastet**. (Folge aus „keine Töne, kein Overlay".)
- `refined: false`: **kein Fehler** — der Text wird geschrieben. Ein Diktat geht nie verloren.
- Erneutes Drücken während der Verarbeitung: neue Aufnahme startet **sofort**, die alte Verarbeitung läuft weiter und darf den Zustand `.recording` **nicht** überschreiben.

- [ ] **Step 1: Tests schreiben**

`apps/macos/Tests/TypeLessCoreTests/DictationCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import TypeLessCore

// MARK: - Attrappen

final class SpyPasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var texte: [String] = []

    var geschrieben: [String] {
        lock.lock(); defer { lock.unlock() }
        return texte
    }

    func write(_ text: String) {
        lock.lock(); texte.append(text); lock.unlock()
    }
}

/// Client, dessen `process`-Antwort der Test vorgibt und dessen Aufrufe er zählt.
final class DictationClient: SidecarClient, @unchecked Sendable {
    private let lock = NSLock()
    private var ergebnis: Result<ProcessResult, SidecarError>
    private var preloadFehler: SidecarError?
    private(set) var preloadCount = 0
    private(set) var processCount = 0
    /// Meldet, sobald `process` aufgerufen wurde — damit Tests ohne Wartezeit synchronisieren.
    let processGestartet: AsyncStream<Void>
    private let processGestartetC: AsyncStream<Void>.Continuation

    init(ergebnis: Result<ProcessResult, SidecarError>, preloadFehler: SidecarError? = nil) {
        self.ergebnis = ergebnis
        self.preloadFehler = preloadFehler
        (processGestartet, processGestartetC) = AsyncStream<Void>.makeStream()
    }

    private func naechstes() throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        return try ergebnis.get()
    }

    func health() async throws -> HealthState {
        HealthState(status: "ready", sttLoaded: true, llmLoaded: true, busy: false,
                    sttModel: "w", llmModel: "q", error: nil)
    }

    func preload() async throws {
        lock.lock(); preloadCount += 1; let fehler = preloadFehler; lock.unlock()
        if let fehler { throw fehler }
    }

    func unload() async throws {}

    func process(pcm: Data, mode: Mode, language: String?) async throws -> ProcessResult {
        lock.lock(); processCount += 1; lock.unlock()
        processGestartetC.yield()
        return try naechstes()
    }
}

func ergebnis(_ text: String, refined: Bool = true,
              fallbackReason: String? = nil) -> ProcessResult {
    ProcessResult(finalText: text, rawText: text, dictionaryText: text, mode: "diktat",
                  language: "de", refined: refined, fallbackReason: fallbackReason,
                  timingsMs: [:])
}

/// Sprache: 1 s bei 16 kHz, deutlich über der Stilleschwelle.
func sprache(sekunden: Double = 1.0) -> [Float] {
    let n = Int(16_000 * sekunden)
    return (0..<n).map { Float(sin(Double($0) * 0.1)) * 0.2 }
}

/// Stille: 1 s bei 16 kHz, faktisch tonlos.
func stille(sekunden: Double = 1.0) -> [Float] {
    [Float](repeating: 0.0001, count: Int(16_000 * sekunden))
}

@MainActor
func makeCoordinator(hotkey: FakeHotkey, recorder: FakeRecorder,
                     client: DictationClient, pasteboard: SpyPasteboard) -> DictationCoordinator {
    DictationCoordinator(hotkey: hotkey, recorder: recorder, client: client, pasteboard: pasteboard)
}

/// Wartet ohne feste Wartezeit, bis eine Bedingung eintritt.
@MainActor
func warteBis(_ bedingung: () -> Bool) async {
    for _ in 0..<10_000 {
        if bedingung() { return }
        await Task.yield()
    }
}

// MARK: - Tests

@MainActor
@Test(.timeLimit(.minutes(1)))
func druckStartetAufnahmeUndPreload() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("Hallo")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }

    #expect(coordinator.session == .recording)
    #expect(await recorder.startCount == 1)
    // Der Preload läuft nebenläufig — er lädt das Sprachmodell, während der Nutzer noch spricht.
    await warteBis { client.preloadCount == 1 }
    #expect(client.preloadCount == 1)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func loslassenVerarbeitetUndSchreibtInDieZwischenablage() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let coordinator = makeCoordinator(
        hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
        client: DictationClient(ergebnis: .success(ergebnis("Guten Morgen."))),
        pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["Guten Morgen."])
    #expect(coordinator.session == .idle)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func gescheiterterPreloadVerhindertDasDiktatNicht() async throws {
    // Der Preload ist reine Beschleunigung. /process lädt notfalls selbst nach.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("Trotzdem da.")),
                                 preloadFehler: .notReady("LLM lädt noch"))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["Trotzdem da."])

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func zuKurzesAntippenWirdKommentarlosVerworfen() async throws {
    // 100 ms bei 16 kHz = 1600 Werte, unter der Schwelle von 4800.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(hotkey: hotkey,
                                      recorder: FakeRecorder(samples: sprache(sekunden: 0.1)),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(client.processCount == 0, "ein Versehen darf die Engine gar nicht erst behelligen")
    #expect(pasteboard.geschrieben.isEmpty)
    #expect(coordinator.session == .idle, "ein Versehen ist kein Fehler")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func stilleMeldetMikrofonproblemUndLaesstDieZwischenablageInRuhe() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(ergebnis("darf nicht kommen")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: stille()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Kein Ton aufgenommen — Mikrofon prüfen"))
    #expect(client.processCount == 0)
    #expect(pasteboard.geschrieben.isEmpty, "die Zwischenablage darf nie überschrieben werden")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func unpolierterTextGehtTrotzdemInDieZwischenablage() async throws {
    // M2-Vertrag: refined == false heißt "LLM ausgefallen, Rohtext ist da". KEIN Fehler.
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .success(
        ergebnis("roher text", refined: false, fallbackReason: "LLM nicht geladen")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { coordinator.session == .idle }

    #expect(pasteboard.geschrieben == ["roher text"], "ein Diktat darf nie verloren gehen")
    #expect(coordinator.session == .idle, "unpoliert ist kein Fehler")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func fehlerLaesstDieZwischenablageUnangetastet() async throws {
    let hotkey = FakeHotkey()
    let pasteboard = SpyPasteboard()
    let client = DictationClient(ergebnis: .failure(.processingFailed("STT kaputt")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: FakeRecorder(samples: sprache()),
                                      client: client, pasteboard: pasteboard)
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(pasteboard.geschrieben.isEmpty,
            "ohne Ton und Overlay ist der alte Inhalt besser als Leere")

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func erneutesDrueckenWaehrendDerVerarbeitungStartetSofortEineNeueAufnahme() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(samples: sprache())
    let client = DictationClient(ergebnis: .success(ergebnis("erstes")))
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: client, pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { coordinator.session == .recording }
    hotkey.send(.released)

    // Sobald die Verarbeitung läuft, drücken wir erneut.
    var iterator = client.processGestartet.makeAsyncIterator()
    _ = await iterator.next()
    hotkey.send(.pressed)

    await warteBis { coordinator.session == .recording }
    #expect(coordinator.session == .recording, "der Nutzer wird nie ausgebremst")
    #expect(await recorder.startCount == 2)

    await coordinator.stop()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func verweigertesMikrofonWirdGemeldet() async throws {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder(fehlerBeimStart: .microphoneDenied)
    let coordinator = makeCoordinator(hotkey: hotkey, recorder: recorder,
                                      client: DictationClient(ergebnis: .success(ergebnis("x"))),
                                      pasteboard: SpyPasteboard())
    await coordinator.start()

    hotkey.send(.pressed)
    await warteBis { if case .failed = coordinator.session { return true }; return false }

    #expect(coordinator.session == .failed("Mikrofonzugriff verweigert"))

    await coordinator.stop()
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `cd apps/macos && swift test`
Expected: FAIL — „cannot find 'DictationCoordinator' in scope"

- [ ] **Step 3: Pasteboard-Protokoll**

`apps/macos/Sources/TypeLessCore/Dictation/Pasteboard.swift`:

```swift
import Foundation

/// Schreibt Text in die Zwischenablage.
///
/// Als Protokoll, damit der Koordinator ohne AppKit testbar bleibt — die Umsetzung mit
/// ``NSPasteboard`` liegt in der App-Schicht (`Sources/TypeLess/`).
public protocol Pasteboard: Sendable {
    func write(_ text: String)
}
```

- [ ] **Step 4: Koordinator implementieren**

`apps/macos/Sources/TypeLessCore/Dictation/DictationCoordinator.swift`:

```swift
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

        let samples: [Float]
        do {
            samples = try await recorder.stop()
        } catch {
            session = .failed("Aufnahme fehlgeschlagen: \(error)")
            return
        }

        // Versehentliches Antippen: kommentarlos verwerfen. Kein Fehler, keine Anzeige.
        guard samples.count >= minimumSampleCount else {
            session = .idle
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
                await self?.beendeVerarbeitung(id: id, fehler: nil)
            } catch {
                // Zwischenablage bleibt unangetastet: Der alte Inhalt ist besser als Leere.
                await self?.beendeVerarbeitung(id: id, fehler: Self.beschreibe(error))
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
```

- [ ] **Step 5: Tests laufen lassen**

Run: `cd apps/macos && swift test`
Expected: PASS (71 Tests)

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "M4: Diktat-Koordinator (Zustandsautomat Aufnahme → Verarbeitung → Zwischenablage)"
```

---

### Task 5: Verdrahtung, Oberfläche und Handprobe

**Files:**
- Create: `apps/macos/Sources/TypeLess/SystemPasteboard.swift`
- Modify: `apps/macos/Sources/TypeLess/TypeLessApp.swift` (Komposition + Lebenszyklus)
- Modify: `apps/macos/Sources/TypeLess/MenuContent.swift` (Symbol und Text aus beiden Achsen)
- Modify: `CLAUDE.md` (M4 abhaken)

**Interfaces:**
- Consumes: `DictationCoordinator`, `SessionState`, `Pasteboard` (Task 4); `FnKeyMonitor` (Task 3); `AVAudioEngineRecorder` (Task 2); `AppState`, `EngineState` (M3).
- Produces: nichts für spätere Tasks — dies ist die letzte.

- [ ] **Step 1: Zwischenablage implementieren**

`apps/macos/Sources/TypeLess/SystemPasteboard.swift`:

```swift
import AppKit
import TypeLessCore

/// Die echte Zwischenablage. Liegt bewusst in der App-Schicht, damit AppKit nicht in die
/// UI-freie Bibliothek ``TypeLessCore`` sickert.
struct SystemPasteboard: Pasteboard {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Menü erweitern**

`apps/macos/Sources/TypeLess/MenuContent.swift` — den bestehenden Inhalt so ändern, dass er
**beide** Zustandsachsen zeigt. Der Diktat-Zustand hat Vorrang vor dem Engine-Zustand:

```swift
import SwiftUI
import TypeLessCore

/// Der Inhalt des Menüleisten-Menüs. Zeigt nur an, was ``AppState`` und
/// ``DictationCoordinator`` sagen — keine Logik.
struct MenuContent: View {
    let state: AppState
    let dictation: DictationCoordinator

    var body: some View {
        Text(statusText)

        Divider()

        // Der Hotkey ist nutzlos, wenn macOS die Fn-Taste selbst belegt. Das sagen wir,
        // statt den Nutzer rätseln zu lassen, warum ständig Emojis aufpoppen.
        if FnKeyMonitor.fnKeyOpensEmojiPicker() {
            Text("⚠ Fn öffnet den Emoji-Picker")
            Text("   Tastatur-Einstellungen → „Beim Drücken der 🌐-Taste“ → „Keine Aktion“")
            Divider()
        }

        ForEach(Permission.allCases, id: \.self) { permission in
            Button {
                state.openSettings(for: permission)
            } label: {
                let granted = state.permissions.isGranted(permission)
                Text("\(granted ? "✓" : "⚠") \(permission.title) — \(permission.purpose)")
            }
        }

        Divider()

        Button("Engine neu starten") {
            Task { await state.restart() }
        }

        Button("TypeLess beenden") {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Der Diktat-Zustand hat Vorrang: Während der Aufnahme interessiert die Engine nicht.
    private var statusText: String {
        switch dictation.session {
        case .recording: "🔴 Nimmt auf …"
        case .processing: "Verarbeite …"
        case let .failed(grund): "Fehler: \(grund)"
        case .idle:
            switch state.engine {
            case .ready: "Bereit — Fn halten zum Diktieren"
            case .starting: "Engine startet …"
            case .stopped: "Engine: gestoppt"
            case let .failed(grund): "Engine-Fehler: \(grund)"
            }
        }
    }
}
```

- [ ] **Step 3: App verdrahten**

`apps/macos/Sources/TypeLess/TypeLessApp.swift` — den Koordinator in die Komposition aufnehmen.
Der bestehende `AppDelegate`-Pfad (`applicationDidFinishLaunching` /
`applicationShouldTerminate`) bleibt unangetastet; der Koordinator wird dort mit gestartet und
mit beendet:

```swift
import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState
    @State private var dictation: DictationCoordinator

    init() {
        // Die einzige Stelle, die konkrete Typen kennt (Komposition).
        let settings = UserDefaultsSettingsStore()
        let client = HTTPSidecarClient(socketPath: settings.socketPath)
        let lifecycle = DefaultSidecarLifecycle(
            client: client,
            runner: FoundationProcessRunner(),
            engineDirectory: settings.engineDirectory,
            uvPath: settings.uvPath)

        let state = AppState(lifecycle: lifecycle, client: client,
                             permissions: SystemPermissionsService())
        let dictation = DictationCoordinator(
            hotkey: FnKeyMonitor(),
            recorder: AVAudioEngineRecorder(),
            client: client,
            pasteboard: SystemPasteboard())

        _state = State(wrappedValue: state)
        _dictation = State(wrappedValue: dictation)
        appDelegate.state = state
        appDelegate.dictation = dictation
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state, dictation: dictation)
        } label: {
            Image(systemName: symbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// Das Symbol zeigt den Diktat-Zustand, solange einer läuft — sonst den der Engine.
    /// Ohne Overlay ist es die einzige sichtbare Rückmeldung (Entscheidung des Anwenders).
    private var symbol: String {
        switch dictation.session {
        case .recording: "mic.circle.fill"
        case .processing: "ellipsis.circle"
        case .failed: "exclamationmark.circle"
        case .idle:
            switch state.engine {
            case .ready: "mic.fill"
            case .starting, .stopped: "mic"
            case .failed: "mic.slash"
            }
        }
    }
}

/// Start und Ende laufen bewusst über den AppDelegate — siehe die ausführliche Begründung
/// unten: `applicationDidFinishLaunching` feuert garantiert genau einmal, und
/// `applicationShouldTerminate` fängt Menü-Button, Cmd+Q und Dock gleichermaßen ab.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    var dictation: DictationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await state?.start()
            await dictation?.start()
        }
    }

    /// `.terminateLater`: Die Aufräumarbeit ist asynchron (Poll-Task beenden, selbst
    /// gestarteten Sidecar beenden, laufende Verarbeitungen zu Ende bringen). Ein blockierendes
    /// Warten würde hier mit dem `@MainActor` in einen Deadlock laufen.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            // Erst das Diktat: Ein fertig gesprochenes, noch laufendes Diktat wird zu Ende
            // verarbeitet, bevor die Engine unter ihm weggezogen wird.
            await dictation?.stop()
            await state?.shutdown()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

- [ ] **Step 4: Bauen und Tests**

Run: `cd apps/macos && swift build && swift test`
Expected: Build ohne Warnungen, 71 Tests grün.

- [ ] **Step 5: Handprobe — das erste echte Diktat**

```bash
bash scripts/build-app.sh
open apps/macos/TypeLess.app
```

Beim ersten Start fragt macOS nach **Mikrofon** und **Eingabeüberwachung** — beides erteilen.
(Nach einem Neubau kann die Frage erneut kommen: Die Ad-hoc-Signatur wechselt bei jedem Bau.)

Dann, sobald das Menü „Bereit — Fn halten zum Diktieren" zeigt:

1. In ein Textfeld klicken (z. B. TextEdit).
2. **Fn halten**, einen Satz sprechen, **loslassen**.
3. Erwartung: Das Symbol wechselt auf Aufnahme, dann auf Verarbeitung, dann zurück.
4. **⌘V** — der Satz steht da, mit Groß-/Kleinschreibung und Satzzeichen.

- [ ] **Step 6: Handprobe — die Fehlerfälle**

Jeden einzeln prüfen und im Bericht belegen:

- **Kurz antippen**: Fn antippen und sofort loslassen → nichts passiert, **kein** Emoji-Picker,
  die Zwischenablage bleibt unverändert.
- **Fn-Kombinationen**: Fn+Pfeil links/rechts und Fn+Entf in einem Textfeld → funktionieren
  unverändert (der Tap liest nur mit, er verschluckt nichts).
- **Stummes Mikrofon**: Systemeinstellungen → Ton → Eingabelautstärke auf 0, dann diktieren →
  Menü zeigt „Kein Ton aufgenommen — Mikrofon prüfen", **die Zwischenablage bleibt unverändert**
  (⌘V liefert weiterhin den alten Inhalt). Danach zurückstellen.
- **Zweites Diktat während der Verarbeitung**: diktieren, loslassen, sofort wieder Fn drücken →
  die neue Aufnahme startet sofort; beide Texte kommen an (der zweite überschreibt den ersten in
  der Zwischenablage — das ist so gewollt).
- **Beenden während der Verarbeitung**: diktieren, loslassen, sofort „TypeLess beenden" →
  die App wartet, bis die Verarbeitung fertig ist; kein verwaister Sidecar
  (`pgrep -fl typeless_engine.server` findet danach nichts).

- [ ] **Step 7: CLAUDE.md aktualisieren**

M4 abhaken. Die neuen Bausteine unter `apps/macos/Sources/TypeLessCore/` in der Strukturübersicht
ergänzen (`Audio/`, `Hotkey/`, `Dictation/`). Festhalten: **Fn halten zum Diktieren**, Text landet
in der **Zwischenablage** (automatisches Einfügen kommt in M5), **kein Overlay und keine Töne**
(bewusste Entscheidung des Anwenders), und die Voraussetzung „Beim Drücken der 🌐-Taste" =
„Keine Aktion". Testzahl aktualisieren.

- [ ] **Step 8: Commit**

```bash
git add apps/macos CLAUDE.md
git commit -m "M4: Fn-Diktat verdrahtet, gegen echte Hardware verifiziert"
```

---

## Offene Risiken

- **`AVAudioEngine.inputNode` ohne Mikrofon-Berechtigung**: Wird der Tap installiert, bevor die
  Berechtigung erteilt ist, liefert das Eingabegerät stumme Puffer (oder die Engine startet gar
  nicht). Der Recorder fragt deshalb **vor** dem Start ab. Ob macOS den Dialog dabei zuverlässig
  zeigt, muss die Handprobe zeigen — beim allerersten Start mit frisch gebautem Bundle.
- **Latenz**: Nach dem Loslassen vergehen laut Messung aus M1 etwa 6 s für ein 15-s-Diktat
  (2,6 s Transkription + 3,5 s Sprachmodell). Ohne Overlay sieht der Nutzer in dieser Zeit nur
  das Menüleisten-Symbol. Das ist die bewusste Entscheidung des Anwenders; die Optimierung
  steht in M8.
- **Der Tap läuft auf einem eigenen Thread mit eigenem RunLoop.** Wird `stop()` gerufen, während
  der Thread gerade im Callback steckt, muss das sauber auseinandergehen. Die Tests decken den
  Thread nicht ab (die Attrappe hat keinen) — hier ist die Handprobe die einzige Absicherung.
  Beim Beenden der App gezielt darauf achten, dass kein Absturz auftritt.
