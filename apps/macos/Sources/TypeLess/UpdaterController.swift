import AppKit
import Sparkle

/// Kapselt Sparkles Updater. Bewusst in der App-Schicht (nicht in TypeLessCore) — Sparkle ist ein
/// UI-Framework. Betriebsart „automatisch prüfen, aber vor Download/Installation fragen" steckt in
/// der Info.plist (SUEnableAutomaticChecks / SUScheduledCheckInterval, kein Auto-Download).
@MainActor
final class UpdaterController: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // userDriverDelegate: self → wir werden vor dem Anzeigen eines Update-Dialogs gefragt und
        // holen die (dock-lose LSUIElement-)App dann in den Vordergrund.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Manueller Auslöser aus dem Menü. `NSApp.activate` bringt den Dialog vor — ohne das bliebe er
    /// bei einer Hintergrund-App (LSUIElement) unsichtbar hinter anderen Fenstern.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // SPUStandardUserDriverDelegate: auch der automatische Fund soll sichtbar nach vorn kommen.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
