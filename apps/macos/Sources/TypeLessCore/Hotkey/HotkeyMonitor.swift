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
///
/// `start()` ist bewusst NICHT `throws` (I3, Review M4, Important, aufgeräumt): Der einzige
/// reale Fehlerfall (fehlende Eingabeüberwachung) lässt sich bei einem `CGEventTap` erst auf
/// einem eigenen Thread mit laufendem RunLoop feststellen, s. ``FnKeyMonitor``. Ein `throws`
/// hier wäre für die einzige Produktionsimplementierung eine Lüge gewesen — sie warf nie, der
/// entsprechende `catch`-Zweig im Aufrufer war toter Code. Ein Fehlschlag zeigt sich stattdessen
/// darin, dass der gelieferte Stream endet, ohne je ein Ereignis geliefert zu haben — der
/// Aufrufer (``DictationCoordinator``) muss das auswerten.
public protocol HotkeyMonitor: Sendable {
    func start() -> AsyncStream<HotkeyEvent>
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
    private var runLoopQuelle: CFRunLoopSource?
    /// Der RunLoop des Hotkey-Threads, gesetzt in ``installTap(generation:)``. `stop()` braucht
    /// diese Referenz, um den Thread zuverlässig zu beenden (s. dort).
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var continuation: AsyncStream<HotkeyEvent>.Continuation?

    /// Zählt jeden `start()`/`stop()`-Übergang hoch. Löst zwei Race-Fenster, die sonst einen
    /// Thread für immer hängen lassen könnten (Aufgabenstellung: „kein weiterlaufender
    /// Thread"):
    /// 1. Ein zweiter `start()`, während der erste Tap noch installiert wird — ohne Zähler
    ///    würden zwei Taps parallel laufen.
    /// 2. Ein `stop()`, das ankommt, während `installTap(generation:)` noch mitten im
    ///    (blockierenden) `CGEvent.tapCreate`-Aufruf hängt — zu dem Zeitpunkt kennt `stop()`
    ///    weder `tap` noch `runLoop` und kann nichts abräumen. Der Installationsversuch prüft
    ///    nach getaner Arbeit, ob er noch aktuell ist, und räumt sich sonst selbst ab, statt
    ///    `CFRunLoopRun()` zu betreten.
    private var generation: UInt64 = 0

    public init() {}

    public func start() -> AsyncStream<HotkeyEvent> {
        // Ein doppelter start() darf keinen zweiten Tap installieren (Vorbild:
        // AppState.startPolling(), das ebenso erst den alten Lauf beendet). stop() ist
        // idempotent — harmlos, falls noch gar nichts lief.
        stop()

        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()

        lock.lock()
        generation += 1
        let meineGeneration = generation
        self.continuation = continuation
        lock.unlock()

        // Der Tap braucht einen laufenden RunLoop. Ein eigener Thread hält den Main-Thread
        // frei — der Callback darf das System nicht aufhalten. installTap() muss auf genau
        // diesem Thread laufen: CFRunLoopGetCurrent() darin liefert den RunLoop, den
        // CFRunLoopRun() gleich danach (auf demselben Thread) abarbeitet.
        let thread = Thread { [weak self] in
            guard let self else { return }
            do {
                try self.installTap(generation: meineGeneration)
            } catch {
                // Keine Berechtigung — CGEvent.tapCreate lieferte nil. Der Stream endet leer
                // statt eines synchronen throws, weil der Tap erst hier auf dem eigenen
                // Thread tatsächlich angelegt wird (s. fnKeyOpensEmojiPicker()-Kommentar oben:
                // in Task 5 von Hand verifiziert).
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
        // Entwertet einen eventuell noch laufenden installTap()-Versuch (s. Kommentar bei
        // `generation`), BEVOR wir unten prüfen, was es schon abzuräumen gibt.
        generation += 1
        let tap = self.tap
        let quelle = self.runLoopQuelle
        let runLoop = self.runLoop
        continuation?.finish()
        continuation = nil
        self.tap = nil
        self.runLoopQuelle = nil
        self.runLoop = nil
        self.thread = nil
        lock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let quelle { CFRunLoopSourceInvalidate(quelle) }
        // CFRunLoopRun() kehrt nur zurück, wenn der RunLoop explizit gestoppt wird — bloßes
        // Invalidieren der Quelle weckt einen RunLoop, der gerade blockiert auf dem Mach-Port
        // des Tap wartet, nicht zuverlässig auf. Ohne diesen Aufruf bliebe der Hotkey-Thread
        // für immer hängen: genau das in der Aufgabe benannte Risiko.
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    private func installTap(generation meineGeneration: UInt64) throws {
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

        guard let quelle = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            throw HotkeyError.inputMonitoringDenied
        }

        lock.lock()
        // Zwischenzeitlich kann ein stop() (oder ein überholender start()) diesen Versuch
        // bereits für ungültig erklärt haben, während CGEvent.tapCreate oben lief (echtes
        // Round-Trip zum WindowServer, kann dauern). Dann NICHT CFRunLoopRun() betreten,
        // sonst bliebe dieser Thread für immer hängen, weil niemand mehr von ihm weiß.
        guard generation == meineGeneration else {
            lock.unlock()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopSourceInvalidate(quelle)
            return
        }
        self.tap = tap
        self.runLoopQuelle = quelle
        self.runLoop = CFRunLoopGetCurrent()
        lock.unlock()

        CFRunLoopAddSource(CFRunLoopGetCurrent(), quelle, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        CFRunLoopRun()
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
