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
