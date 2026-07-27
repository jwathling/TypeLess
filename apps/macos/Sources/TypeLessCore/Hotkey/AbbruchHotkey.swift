@preconcurrency import Carbon
import Foundation

/// Meldet eine **einzelne** Tastenkombination beim System an und ruft zurück, wenn sie gedrückt
/// wird — der Auslöser für den Abbruch eines laufenden Diktats.
///
/// **Warum nicht über den bestehenden `CGEventTap`:** Der Tap müsste dafür `.keyDown` mitlesen,
/// also **jeden** Tastendruck des Anwenders sehen. Das ist ein Datenschutzbruch und durch die
/// M4-Regel ausgeschlossen (die Maske bleibt ausschließlich `.flagsChanged`). `RegisterEventHotKey`
/// ist das Gegenteil: Es sieht ausschließlich die angemeldete Kombination, alle anderen
/// Tastendrücke bleiben unsichtbar.
///
/// Als Protokoll, damit der ``DictationCoordinator`` ohne echte systemweite Registrierung prüfbar
/// bleibt — gleiche Bauart wie ``Pasteboard``, ``TextInserter``, ``InsertionTarget``.
public protocol AbbruchHotkey: Sendable {
    /// Meldet die Kombination an. Mehrfach aufrufbar: Eine bereits bestehende Registrierung wird
    /// dabei ersetzt, nicht verdoppelt.
    func registriere(_ beiDruck: @escaping @Sendable () -> Void)

    /// Gibt die Kombination wieder frei. Mehrfach aufrufbar und ohne bestehende Registrierung
    /// folgenlos — der Aufrufer synchronisiert nach Zustand, nicht nach Übergängen.
    func gibFrei()
}

/// Die echte Umsetzung über Carbon: **Escape**.
///
/// **Warum nur zeitweise registriert:** Solange die Kombination angemeldet ist, bekommt **keine**
/// andere App Escape zu sehen. Ein dauerhaft registriertes Escape würde den Rechner unbenutzbar
/// machen (jeder Dialog, jedes Sheet). Deshalb registriert der ``DictationCoordinator`` nur für die
/// Dauer einer laufenden Verarbeitung — s. dort.
///
/// **Nicht unit-getestet, bewusst:** Ein Test würde dem ganzen Rechner Escape wegnehmen. Geprüft
/// wird der Vertrag an ``FakeAbbruchHotkey``; diese Umsetzung ist Handprobe (gleiche Abwägung wie
/// bei ``CGEventTextInserter``).
public final class SystemAbbruchHotkey: AbbruchHotkey, @unchecked Sendable {
    /// Virtueller Tastencode von Escape (`kVK_Escape`). Als benannte Konstante, damit der Wert
    /// nicht als magische Zahl im Registrierungsaufruf steht.
    private static let escapeKeycode: UInt32 = 53

    /// Eigene Kennung dieser Registrierung. Dient zwei Zwecken: verhindert eine Kollision mit
    /// einer fremden Anmeldung (schon immer so) UND lässt den Handler unten (I2, Abschluss-Review)
    /// prüfen, ob ein empfangenes `kEventHotKeyPressed` wirklich ihm gehört. Bewusst NICHT
    /// `private`: ``gehoertZuDieserRegistrierung(status:empfangeneId:)`` muss ohne echte
    /// Carbon-Registrierung testbar bleiben (`@testable import` macht `internal` für Proben
    /// sichtbar, `private` bliebe ihnen verschlossen).
    static let eigeneSignatur = OSType(0x544C_4553 /* "TLES" */)
    static let eigeneId: UInt32 = 1

    private let lock = NSLock()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var beiDruck: (@Sendable () -> Void)?

    public init() {}

    /// Erzwingt jetzt tatsächlich, was der Kommentar bei `passUnretained` oben zusagt (I1,
    /// Abschluss-Review): Ohne dieses `deinit` war die Garantie „`gibFrei()` läuft vor der
    /// Freigabe" nur eine Konvention an der EINEN Aufrufstelle in `TypeLessApp.swift`, nicht eine
    /// Eigenschaft dieses Typs — `TypeLessCore` ist eine Bibliothek mit `public init()`, jeder
    /// künftige Besitzer könnte die Konvention brechen. Dann bliebe im PROZESSGLOBALEN
    /// Carbon-Handler ein `passUnretained`-Zeiger auf freigegebenen Speicher stehen, den das
    /// nächste Escape dereferenziert — Use-after-free, nicht bloß ein hängender Hotkey.
    ///
    /// **Sicher aus `deinit` aufrufbar:** `gibFrei()` ist nicht actor-isoliert (die Klasse ist
    /// `@unchecked Sendable`, kein `@MainActor`), sperrt nur ``lock`` (ein einfaches `NSLock`) und
    /// ruft ausschließlich Carbon-Funktionen sowie `beiDruck = nil` — nichts davon verlangt einen
    /// bestimmten Thread oder Ausführungskontext. Zum Zeitpunkt von `deinit` ist der Referenzzähler
    /// bereits auf null: Es kann keine zweite, gleichzeitig laufende `registriere`-/`gibFrei`-
    /// Aufrufstelle mehr geben, die um denselben Lock konkurrierte — kein Deadlock-, kein
    /// Reentranz-Risiko.
    deinit { gibFrei() }

    public func registriere(_ beiDruck: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Idempotent: Eine bestehende Registrierung zuerst abbauen. Ohne das sammelte jeder
        // Aufruf einen weiteren Handler an, und `gibFrei()` räumte nur den letzten weg.
        gibFreiOhneLock()
        self.beiDruck = beiDruck

        var eventTyp = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        // `Unmanaged` als Brücke in den C-Callback: Carbon kennt keine Swift-Closures. Die
        // Referenz wird NICHT retained (`passUnretained`) — das ist nur sicher, WEIL `deinit`
        // unten `gibFrei()` erzwingt (I1, Abschluss-Review): Der Handler im PROZESSGLOBALEN
        // Carbon-Event-Target wird garantiert VOR der Freigabe dieses Objekts abgebaut, nie
        // danach. Ohne diese Garantie bliebe bei einer dealloziierten, aber noch registrierten
        // Instanz ein Zeiger auf freigegebenen Speicher im Handler stehen — das nächste Escape
        // wäre ein Use-after-free, nicht bloß ein hängender Hotkey.
        let selbst = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, nutzerdaten in
            // I2 (Abschluss-Review, Important): Dieser Handler hängt am APPLICATION-Event-Target
            // und bekäme ohne diese Prüfung JEDES `kEventHotKeyPressed` des Prozesses zu sehen —
            // nicht nur das eigene. Heute folgenlos (nur diese Datei ruft `RegisterEventHotKey`),
            // aber CLAUDE.md nennt `KeyboardShortcuts` als verbindliche Hotkey-Bibliothek für M6/
            // M7, und die nutzt intern ebenfalls `RegisterEventHotKey`: Ab dann würde JEDER
            // Anwender-Shortcut, der während der ~6 s Verarbeitung gedrückt wird, das Diktat
            // kommentarlos abbrechen. Die eigentliche Prüfung steckt in
            // `gehoertZuDieserRegistrierung` — rein werttypenbasiert und damit ohne echte
            // Carbon-Registrierung testbar.
            guard let event else { return OSStatus(eventNotHandledErr) }
            var empfangeneId = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &empfangeneId)
            guard SystemAbbruchHotkey.gehoertZuDieserRegistrierung(status: status,
                                                                    empfangeneId: empfangeneId)
            else {
                // NICHT `noErr`: Das würde das Ereignis HIER verschlucken, obwohl es einem
                // fremden Hotkey gehört — dessen eigentlicher Empfänger bekäme es dann nie zu
                // sehen. `eventNotHandledErr` lässt es für die weitere Handler-Kette laufen.
                return OSStatus(eventNotHandledErr)
            }
            guard let nutzerdaten else { return OSStatus(eventNotHandledErr) }
            let ich = Unmanaged<SystemAbbruchHotkey>.fromOpaque(nutzerdaten).takeUnretainedValue()
            ich.ausloesen()
            return noErr
        }, 1, &eventTyp, selbst, &handlerRef)

        let kennung = EventHotKeyID(signature: Self.eigeneSignatur, id: Self.eigeneId)
        RegisterEventHotKey(Self.escapeKeycode, 0, kennung,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Rein logische Prüfung, OB ein empfangenes `kEventHotKeyPressed` DIESER Registrierung
    /// gehört — aus dem C-Callback herausgezogen, damit sie ohne echte Carbon-Registrierung
    /// testbar ist (I2, Abschluss-Review): `OSStatus`/`EventHotKeyID` sind reine Werttypen, ihre
    /// Erzeugung nimmt dem Testrechner keine Taste weg.
    ///
    /// **Fail-safe, nicht fail-open:** Scheitert schon das Lesen der ID (`status != noErr`), wird
    /// NICHT ausgelöst — lieber ein verpasster Abbruch als ein fremder Hotkey, der ein laufendes
    /// Diktat verwirft.
    static func gehoertZuDieserRegistrierung(status: OSStatus, empfangeneId: EventHotKeyID) -> Bool {
        status == noErr && empfangeneId.signature == eigeneSignatur && empfangeneId.id == eigeneId
    }

    public func gibFrei() {
        lock.lock()
        defer { lock.unlock() }
        gibFreiOhneLock()
    }

    /// Setzt voraus, dass ``lock`` gehalten wird (aus ``registriere`` und ``gibFrei``).
    private func gibFreiOhneLock() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        beiDruck = nil
    }

    /// Aus dem Carbon-Callback gerufen. Liest die Closure unter dem Lock, ruft sie aber
    /// **außerhalb** — sonst liefe der Abbruch (der wieder `gibFrei()` auslöst) in einen Deadlock.
    private func ausloesen() {
        lock.lock()
        let cb = beiDruck
        lock.unlock()
        cb?()
    }
}
