import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Die drei Berechtigungen, die TypeLess braucht.
public enum Permission: Sendable, CaseIterable {
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

/// Liest den Ist-Zustand der Berechtigungen. Fragt **nichts** aktiv an — macOS zeigt seinen
/// Dialog ohnehin erst beim ersten echten Zugriff. M3 zeigt nur an, was fehlt.
public protocol PermissionsService: Sendable {
    func status() -> PermissionStatus
    func openSettings(for permission: Permission)
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
}
