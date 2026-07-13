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
