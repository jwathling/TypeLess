import Sparkle

/// Kapselt Sparkles Updater. Bewusst in der App-Schicht (nicht in TypeLessCore) — Sparkle ist ein
/// UI-Framework. In diesem Task nur instanziiert, damit das eingebettete Framework beim Start
/// tatsächlich geladen wird (Einbettungs-Beweis); die Betriebsart (automatisch prüfen, vorher
/// fragen) und der Menü-Auslöser kommen in Task 4.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → der Updater startet mit; ohne Feed-URL/Key (Task 4) prüft er
        // nichts, stürzt aber auch nicht ab. Kein Delegate nötig für die reine Instanziierung.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}
