@preconcurrency import Carbon
import Foundation
import Testing
@testable import TypeLessCore

/// Steuerbarer Abbruch-Hotkey: Der Test entscheidet, wann „Escape" gedrückt wird.
///
/// Bewusst eine Attrappe und **nie** `SystemAbbruchHotkey` in Koordinator-Proben: Der echte Typ
/// meldet einen systemweiten Hotkey an — ein Testlauf würde dem ganzen Rechner Escape wegnehmen.
final class FakeAbbruchHotkey: AbbruchHotkey, @unchecked Sendable {
    private let lock = NSLock()
    private var beiDruck: (@Sendable () -> Void)?
    private var _registrierungen = 0
    private var _freigaben = 0

    var istRegistriert: Bool { lock.lock(); defer { lock.unlock() }; return beiDruck != nil }
    var registrierungen: Int { lock.lock(); defer { lock.unlock() }; return _registrierungen }
    var freigaben: Int { lock.lock(); defer { lock.unlock() }; return _freigaben }

    func registriere(_ beiDruck: @escaping @Sendable () -> Void) {
        lock.lock(); self.beiDruck = beiDruck; _registrierungen += 1; lock.unlock()
    }

    func gibFrei() {
        lock.lock(); beiDruck = nil; _freigaben += 1; lock.unlock()
    }

    /// Der Test drückt Escape. Folgenlos, wenn nicht registriert — genau wie beim echten Hotkey.
    func druecke() {
        lock.lock(); let cb = beiDruck; lock.unlock()
        cb?()
    }
}

@Test
func dieAttrappeMeldetIhrenRegistrierungszustand() {
    let hotkey = FakeAbbruchHotkey()
    #expect(hotkey.istRegistriert == false)

    hotkey.registriere {}
    #expect(hotkey.istRegistriert)
    #expect(hotkey.registrierungen == 1)

    hotkey.gibFrei()
    #expect(hotkey.istRegistriert == false)
    #expect(hotkey.freigaben == 1)
}

@Test
func einDruckOhneRegistrierungIstFolgenlos() {
    // Wichtig für die Koordinator-Proben: Escape außerhalb einer Verarbeitung darf nichts tun.
    // Die Attrappe muss sich hier genauso verhalten wie der echte Hotkey, sonst prüfen die
    // Proben eine Eigenschaft, die es in der Produktion nicht gibt.
    let hotkey = FakeAbbruchHotkey()
    // `@Sendable`-Closure: `registriere()` verlangt den Typ, weil der echte Hotkey aus einem
    // Carbon-Callback heraus ruft — hier in der Probe ruft `druecke()` ihn aber synchron auf
    // demselben Thread (kein echter Thread-Wechsel), genau wie beim `AVAudioConverterInputBlock`
    // in `AudioResampler.append(_:)`. `nonisolated(unsafe)` dokumentiert diesen Fehlalarm bewusst,
    // statt die Prüfung pauschal zu unterdrücken.
    nonisolated(unsafe) var gerufen = 0
    hotkey.registriere { gerufen += 1 }
    hotkey.gibFrei()

    hotkey.druecke()

    #expect(gerufen == 0, "nach der Freigabe darf der Callback nicht mehr laufen")
}

// MARK: - I2 (Abschluss-Review): Handler erkennt fremde Hotkeys

/// `SystemAbbruchHotkey.gehoertZuDieserRegistrierung` ist bewusst als reine Werttypen-Funktion aus
/// dem C-Callback herausgezogen (s. dort) — genau damit sie HIER, ohne jede echte
/// `RegisterEventHotKey`-Anmeldung, geprüft werden kann. `EventHotKeyID`/`OSStatus` sind reine
/// Structs/Int32-Aliase; ihre Erzeugung nimmt dem Testrechner keine Taste weg.
@Test
func derHandlerErkenntNurDieEigeneKombination() {
    let eigene = EventHotKeyID(signature: SystemAbbruchHotkey.eigeneSignatur,
                               id: SystemAbbruchHotkey.eigeneId)
    #expect(SystemAbbruchHotkey.gehoertZuDieserRegistrierung(status: noErr, empfangeneId: eigene),
            "die eigene Kombination muss erkannt werden")

    let fremdeId = EventHotKeyID(signature: SystemAbbruchHotkey.eigeneSignatur, id: 2)
    #expect(!SystemAbbruchHotkey.gehoertZuDieserRegistrierung(status: noErr, empfangeneId: fremdeId),
            "gleiche Signatur, andere ID darf nicht als eigene erkannt werden")

    let fremdeSignatur = EventHotKeyID(signature: OSType(0), id: SystemAbbruchHotkey.eigeneId)
    #expect(!SystemAbbruchHotkey.gehoertZuDieserRegistrierung(status: noErr,
                                                               empfangeneId: fremdeSignatur),
            "gleiche ID, andere Signatur (z. B. ein fremder KeyboardShortcuts-Hotkey) darf nicht durchgehen")

    // Fail-safe: Scheitert schon das Lesen der ID, wird NICHT ausgelöst — lieber ein verpasster
    // Abbruch als ein fremder Hotkey, der ein laufendes Diktat verwirft.
    #expect(!SystemAbbruchHotkey.gehoertZuDieserRegistrierung(status: OSStatus(paramErr),
                                                               empfangeneId: eigene),
            "ein Fehler beim Lesen der ID darf nicht als eigene Kombination durchgehen")
}
