import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Die drei Berechtigungen, die TypeLess braucht.
///
/// `Hashable`: Wird für `ForEach(Permission.allCases, id: \.self)` im Menü (M3) gebraucht — ohne
/// diese Konformität kompiliert `id: \.self` nicht.
public enum Permission: Sendable, CaseIterable, Hashable {
    /// Für die Aufnahme (ab M4).
    case microphone
    /// Für das Text-Einfügen an der Cursorposition (ab M5).
    case accessibility
    /// Für den globalen Hotkey (ab M4).
    case inputMonitoring

    public var title: String {
        switch self {
        case .microphone: "Mikrofon"
        case .accessibility: "Bedienungshilfen"
        case .inputMonitoring: "Eingabeüberwachung"
        }
    }

    /// Wofür TypeLess das Recht braucht — für die Anzeige im Menü.
    public var purpose: String {
        switch self {
        case .microphone: "Aufnahme (ab M4)"
        case .accessibility: "Text einfügen (ab M5)"
        case .inputMonitoring: "Globaler Hotkey (ab M4)"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public struct PermissionStatus: Sendable, Equatable {
    public let microphone: Bool
    public let accessibility: Bool
    public let inputMonitoring: Bool

    public init(microphone: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }
}

/// Liest den Ist-Zustand der Berechtigungen — und fordert die **Eingabeüberwachung** aktiv an.
///
/// Die anderen beiden fordert TypeLess nicht selbst an: Das Mikrofon erfragt der `AudioRecorder`
/// vor der ersten Aufnahme (`AVCaptureDevice.requestAccess`), die Bedienungshilfen braucht erst
/// M5. Die Eingabeüberwachung ist der Sonderfall — s. `requestInputMonitoring()`.
public protocol PermissionsService: Sendable {
    func status() -> PermissionStatus
    func openSettings(for permission: Permission)

    /// Fordert die Eingabeüberwachung an — **muss beim Programmstart aufgerufen werden**.
    ///
    /// Ohne diesen Aufruf gibt es keinen Systemdialog und TypeLess erscheint unter Umständen
    /// nicht einmal in der Liste unter Systemeinstellungen → Datenschutz → Eingabeüberwachung —
    /// der Anwender hat dann gar keinen Schalter, den er umlegen könnte.
    ///
    /// Der eigentliche Grund, warum das nicht optional ist: Ein `CGEventTap` lässt sich auch
    /// OHNE dieses Recht anlegen. `CGEvent.tapCreate` liefert brav einen Tap zurück, es gibt
    /// keinen Fehler und keine Ausnahme — der Tap bekommt im Hintergrund nur nie ein Ereignis
    /// zu sehen. Ist TypeLess dagegen gerade die **aktive** App (z. B. weil sein Menü offen
    /// steht), sieht er die Tastendrücke sehr wohl, denn eine aktive App darf ihre eigenen
    /// Ereignisse ohne Sonderrecht empfangen.
    ///
    /// Das ergibt das denkbar verwirrendste Fehlerbild, und es ist in der Handprobe zu M4 genau
    /// so aufgetreten: „Diktieren geht nur, solange ich das Menü offen habe." Der Rückgabewert
    /// sagt, ob das Recht (jetzt) da ist.
    @discardableResult
    func requestInputMonitoring() -> Bool
}

public struct SystemPermissionsService: PermissionsService {
    public init() {}

    public func status() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    @discardableResult
    public func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
