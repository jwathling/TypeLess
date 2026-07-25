import AppKit

/// Weckt den Bedienungshilfen-Baum jeder App, zu der der Anwender wechselt — Electron/Chromium
/// bauen ihn erst auf Anforderung auf (s. Design). So ist er schon wach, bevor Fn gedrückt wird,
/// und die Fokus-/Identitätsprüfung greift beim ERSTEN Diktat. Bei nativen Apps folgenlos.
///
/// Bewusst schlank und ohne Unit-Test: reine Verdrahtung von `NSWorkspace` auf
/// ``InsertionTarget/weckeBedienungshilfen(fuer:)`` — der echte Effekt ist Handprobe.
@MainActor
public final class BedienungshilfenAufwecker {
    private let target: InsertionTarget
    private var beobachter: NSObjectProtocol?

    public init(target: InsertionTarget) { self.target = target }

    public func starte() {
        beobachter = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.target.weckeBedienungshilfen(fuer: pid) }
        }
    }

    isolated deinit {
        if let beobachter {
            NSWorkspace.shared.notificationCenter.removeObserver(beobachter)
        }
    }
}
