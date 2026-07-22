import SwiftUI
import TypeLessCore

/// Einmaliges Einrichtungs-Fenster beim ersten Start: zeigt den Modell-Download-Fortschritt bzw.
/// einen Fehler mit „Erneut versuchen". Reine Anzeige — die Logik liegt in ``AppState/setup``.
struct SetupWindow: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("TypeLess wird eingerichtet")
                .font(.headline)
            switch state.setup {
            case .downloading(let fraction, let downloaded, let total):
                ProgressView(value: fraction) {
                    Text("Sprachmodelle werden geladen …")
                } currentValueLabel: {
                    Text("\(gib(downloaded)) von \(gib(total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Das passiert nur beim ersten Start. Danach läuft alles lokal.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let grund):
                Text("Der Download ist fehlgeschlagen.").foregroundStyle(.red)
                Text(grund).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Erneut versuchen") { Task { await state.retryModelDownload() } }
            case .hidden:
                // Erscheint nicht — das Fenster wird in diesem Zustand geschlossen (TypeLessApp).
                EmptyView()
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    /// GB mit einer Nachkommastelle.
    private func gib(_ bytes: Int) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
