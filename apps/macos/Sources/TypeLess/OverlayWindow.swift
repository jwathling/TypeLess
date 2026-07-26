import AppKit
import SwiftUI
import TypeLessCore

/// Die Anzeige des Diktat-Overlays. Rein darstellend — liest ``DictationCoordinator/overlay`` und
/// rendert die aktuelle Phase. macOS-HUD-Stil: kleines, dunkles, abgerundetes Panel.
struct OverlayView: View {
    let coordinator: DictationCoordinator

    var body: some View {
        Group {
            switch coordinator.overlay {
            case .aus:
                EmptyView()
            case let .hoertZu(pegel):
                zeile { Pegelbalken(pegel: pegel) } text: { Text("Hört zu …") }
            case .verarbeitet:
                zeile { ProgressView().controlSize(.small) } text: { Text("Verarbeitet …") }
            case .eingefuegt:
                zeile { Image(systemName: "checkmark").foregroundStyle(.green) } text: { Text("Eingefügt") }
            case .abgebrochen:
                // Bewusst `.secondary` statt der orangen Warnfarbe von `.fehler`: Ein Abbruch ist
                // kein Fehlschlag, sondern eine bestätigte Absicht des Anwenders.
                zeile { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                    text: { Text("Abgebrochen") }
            case let .zwischenablage(vorschau):
                VStack(alignment: .leading, spacing: 5) {
                    zeile { Image(systemName: "doc.on.clipboard") } text: { Text("Fertig · ⌘V") }
                    Text(vorschau).font(.system(size: 12)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
                }
            case let .fehler(grund):
                zeile { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } text: { Text(grund) }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .foregroundStyle(.white.opacity(0.94))
        .fixedSize()
    }

    private func zeile<L: View, T: View>(@ViewBuilder leading: () -> L, @ViewBuilder text: () -> T) -> some View {
        HStack(spacing: 9) { leading(); text().font(.system(size: 12.5, weight: .medium)).lineLimit(1) }
    }
}

/// Fünf kleine Balken, die den Live-Pegel zeigen. Rein dekorativ; bei Pegel 0 eine ruhige Ruhelage.
private struct Pegelbalken: View {
    let pegel: Float
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let hoehe = balkenHoehe(i)
                Capsule().fill(Color(red: 0.36, green: 0.62, blue: 1.0))
                    .frame(width: 2.5, height: hoehe)
            }
        }
        .frame(height: 13)
        .animation(.easeOut(duration: 0.08), value: pegel)
    }
    private func balkenHoehe(_ i: Int) -> CGFloat {
        // Mittlere Balken schlagen stärker aus; Pegel 0…1 auf 3…13 pt abbilden.
        let gewicht: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        let p = CGFloat(max(0, min(1, pegel)))
        return 3 + p * 10 * gewicht[i]
    }
}

/// Baut das passive Overlay-Panel. **Bindend (M5):** übernimmt nie den Tastaturfokus, ist
/// klick-durchlässig, schwebt über allem, auf allen Spaces — sonst bräche das direkte Einfügen.
@MainActor
func macheOverlayPanel(inhalt: NSView) -> NSPanel {
    let panel = PassivesPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.ignoresMouseEvents = true                 // klick-durchlässig
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.contentView = inhalt
    return panel
}

/// `NSPanel`-Unterklasse, die den Fokus GARANTIERT nie nimmt — die härteste Zusicherung gegen
/// das Stehlen des Tastaturfokus (über die Style-Maske hinaus).
final class PassivesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
