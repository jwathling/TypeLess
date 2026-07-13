# TypeLess — macOS-App

Native SwiftUI-Shell (Menüleisten-App, `LSUIElement`, kein Dock-Icon). Drei Ziele:

1. **`TypeLessCore`** — Bibliothek ohne jede UI (kein SwiftUI-, kein AppKit-UI-Import),
   deshalb vollständig testbar ohne ein Fenster zu öffnen. Enthält später Zustandsautomat,
   Services (Hotkey, Audio, Transcriber, TextInserter, …) und den `SidecarClient`.
2. **`TypeLess`** — die eigentliche App: dünne SwiftUI-Hülle, die nur anzeigt, was
   `TypeLessCore` vorgibt.
3. **Ein echtes `.app`-Bundle** — macOS vergibt Mikrofon- und Accessibility-Rechte an eine
   Bundle-Identität, nicht an ein nacktes Binary.

Kommunikation mit der Engine (`../../engine`): Unix-Domain-Socket, JSON.
Endpunkte: `/health`, `/preload`, `/process`, `/unload` (ab M2).

## Entwickeln & testen

```bash
cd apps/macos
swift build
swift test
```

## App-Bundle bauen

```bash
bash ../../scripts/build-app.sh
open TypeLess.app
```

Erzeugt `apps/macos/TypeLess.app` (Debug-Build per Default; `bash ../../scripts/build-app.sh
release` für Release). Das Bundle wird **ad-hoc signiert** (`codesign --sign -`) — für den
persönlichen Gebrauch ausreichend, aber die Signatur-Identität ändert sich bei jedem
Neubau. macOS kann deshalb nach einem Neubau **erneut** nach Mikrofon-/Accessibility-
Rechten fragen. Ein echtes Zertifikat gibt es erst in M8.
