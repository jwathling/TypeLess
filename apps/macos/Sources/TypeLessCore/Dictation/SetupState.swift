import Foundation

/// UI-Zustand des einmaligen Einrichtungs-Fensters, abgeleitet aus dem ``ModelsStatus`` der Engine.
///
/// Sichtbar sind bewusst NUR ``downloading`` und ``failed``: Bei vorhandenen Modellen läuft der
/// Status ``missing`` → ``ready`` durch, ohne je ``downloading`` zu erreichen — dann erscheint kein
/// Fenster. Das ``missing`` beim allerersten Anlauf (Metadaten werden geladen) ist bewusst ebenfalls
/// ``hidden``: sonst blitzte das Fenster bei jedem Start kurz auf.
public enum SetupState: Sendable, Equatable {
    case hidden
    case downloading(fraction: Double, downloadedBytes: Int, totalBytes: Int)
    case failed(String)

    public init(models: ModelsStatus) {
        switch models.state {
        case "downloading":
            let fraction = models.totalBytes > 0
                ? Double(models.downloadedBytes) / Double(models.totalBytes)
                : 0.0
            self = .downloading(fraction: fraction, downloadedBytes: models.downloadedBytes,
                                totalBytes: models.totalBytes)
        case "failed":
            self = .failed(models.error ?? "Der Modell-Download ist fehlgeschlagen.")
        default:  // "ready", "missing" und alles Unerwartete: kein Fenster
            self = .hidden
        }
    }
}
