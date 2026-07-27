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
    /// Hält den ZULETZT registrierten Callback fest, unabhängig von `gibFrei()` (I3, Abschluss-
    /// Review). Anders als `beiDruck`, das `gibFrei()` weiterhin nullt: Ohne dieses Feld ließe
    /// sich ein VERSPÄTETER Carbon-Callback nicht nachstellen — genau das Szenario, vor dem der
    /// `session == .processing`-Guard in `DictationCoordinator.brichAb()` schützt (die Closure aus
    /// `synchronisiereAbbruchHotkey()` springt über `Task { @MainActor in … }`, und in diesem
    /// Sprung kann `session` längst weitergezogen sein — s. `druckeVerspaetet()`).
    private var letzteClosure: (@Sendable () -> Void)?
    private var _registrierungen = 0
    private var _freigaben = 0

    var istRegistriert: Bool { lock.lock(); defer { lock.unlock() }; return beiDruck != nil }
    var registrierungen: Int { lock.lock(); defer { lock.unlock() }; return _registrierungen }
    var freigaben: Int { lock.lock(); defer { lock.unlock() }; return _freigaben }

    func registriere(_ beiDruck: @escaping @Sendable () -> Void) {
        lock.lock()
        self.beiDruck = beiDruck
        letzteClosure = beiDruck
        _registrierungen += 1
        lock.unlock()
    }

    func gibFrei() {
        lock.lock(); beiDruck = nil; _freigaben += 1; lock.unlock()
    }

    /// Der Test drückt Escape. Folgenlos, wenn nicht registriert — genau wie beim echten Hotkey.
    func druecke() {
        lock.lock(); let cb = beiDruck; lock.unlock()
        cb?()
    }

    /// Simuliert einen Carbon-Callback, der TROTZ eines zwischenzeitlichen `gibFrei()` noch
    /// unterwegs ist — ruft den ZULETZT registrierten Callback unabhängig vom aktuellen
    /// Registrierungsstatus. Am echten Hotkey entspricht das einem Escape, dessen
    /// `kEventHotKeyPressed` schon lief, bevor `UnregisterEventHotKey` griff, dessen Auswertung
    /// (der `Task { @MainActor in … }`-Sprung) aber erst NACH der Freigabe zum Zug kommt.
    func druckeVerspaetet() {
        lock.lock(); let cb = letzteClosure; lock.unlock()
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

@Test
func druckeVerspaetetRuftDenLetztenCallbackAuchNachDerFreigabeAuf() {
    // Die Kehrseite von `einDruckOhneRegistrierungIstFolgenlos` oben: `druckeVerspaetet()` MUSS,
    // anders als `druecke()`, den Callback auch nach `gibFrei()` noch erreichen — sonst würden die
    // Koordinator-Proben, die sich darauf stützen (I3, Abschluss-Review), gar nichts Reales prüfen.
    let hotkey = FakeAbbruchHotkey()
    nonisolated(unsafe) var gerufen = 0
    hotkey.registriere { gerufen += 1 }
    hotkey.gibFrei()

    hotkey.druckeVerspaetet()

    #expect(gerufen == 1,
            "druckeVerspaetet() simuliert einen Carbon-Callback, der TROTZ gibFrei() noch unterwegs war")
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
