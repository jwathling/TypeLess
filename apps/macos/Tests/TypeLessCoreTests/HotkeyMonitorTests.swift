import Foundation
import Testing
@testable import TypeLessCore

/// Attrappe: erlaubt dem Test, Tastendrücke zu erfinden. Wird von Task 4 wiederverwendet.
///
/// `start()` ist bewusst NICHT `throws` (I3, Review M4, Important) — das bildet den echten
/// `FnKeyMonitor` jetzt korrekt nach: Der reale Fehlerfall (fehlende Eingabeüberwachung) endet
/// nicht synchron, sondern lässt den Stream ohne ein einziges Ereignis enden (s.
/// `stirbtSofort` und `beendeStreamUnerwartet()`).
final class FakeHotkey: HotkeyMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    private var stirbtSofort: Bool
    private(set) var gestoppt = false

    /// `stirbtSofort`: bildet den echten Fehlerfall nach — der Stream endet, OHNE je ein
    /// Ereignis zu liefern (I3, Review M4). Ersetzt den früheren `fehler`-Parameter, der
    /// (fälschlich) einen synchronen `throw` simulierte.
    init(stirbtSofort: Bool = false) { self.stirbtSofort = stirbtSofort }

    func start() -> AsyncStream<HotkeyEvent> {
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        if stirbtSofort {
            continuation.finish()
            return stream
        }
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

    /// Simuliert das UNERWARTETE Ende des Streams (I3, Review M4, Important) — z. B. weil dem
    /// echten `FnKeyMonitor` die Berechtigung fehlt und `installTap()` scheitert, NACHDEM
    /// `start()` schon zurückgekehrt ist. Anders als `stop()` wird `gestoppt` hier NICHT
    /// gesetzt — der Koordinator hat diesen Streamabbruch nicht selbst veranlasst.
    func beendeStreamUnerwartet() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
    }
}

@Test func attrappeLiefertEreignisse() async throws {
    let hotkey = FakeHotkey()
    let stream = hotkey.start()

    hotkey.send(.pressed)
    hotkey.send(.released)
    hotkey.stop()

    var empfangen: [HotkeyEvent] = []
    for await event in stream { empfangen.append(event) }

    #expect(empfangen == [.pressed, .released])
}

@Test func fehlendeBerechtigungBeendetDenStreamOhneEinEinzigesEreignis() async throws {
    // I3 (Review M4, Important): Der echte FnKeyMonitor wirft bei fehlender Berechtigung NICHT
    // synchron (s. Kommentar dort) — er beendet nur den Stream, auf einem anderen Thread, ohne
    // je ein Ereignis zu liefern. Die Attrappe bildet das jetzt nach, statt (wie zuvor) einen
    // synchronen `throw` vorzutäuschen, den es in der Realität nie gibt.
    let hotkey = FakeHotkey(stirbtSofort: true)
    let stream = hotkey.start()

    var empfangen: [HotkeyEvent] = []
    for await event in stream { empfangen.append(event) }

    #expect(empfangen.isEmpty)
}

@Test func erkenntObFnDenEmojiPickerOeffnet() {
    // Reine Systemabfrage — der Test belegt nur, dass sie nicht abstürzt und einen
    // Wert liefert. Auf diesem Rechner steht die Einstellung auf "Keine Aktion".
    _ = FnKeyMonitor.fnKeyOpensEmojiPicker()
}
