# TypeLess — macOS-App (Platzhalter)

Die native SwiftUI-Shell wird ab **M3** aufgebaut. Sie wird hier nicht im Linux-Remote
entwickelt (Swift/Xcode + MLX benötigen macOS/Apple Silicon), sondern auf dem Mac.

Geplante Struktur (siehe Projektplan):

```
TypeLess/
├── App/            # MenuBarExtra (LSUIElement, kein Dock-Icon), Einstiegspunkt
├── Presentation/   # SwiftUI: Overlay-Panel, Settings-Window
├── Coordination/   # RecordingCoordinator (Zustandsautomat)
├── Services/       # Protokolle + Impls: Hotkey, Audio, Transcriber, TextRefiner,
│                   #   TextInserter (CGEvent/AX/Clipboard), Permissions, Settings
└── IPC/            # SidecarClient (Unix-Domain-Socket zur Python-Engine)
```

Kommunikation mit der Engine (`../../engine`): Unix-Domain-Socket, JSON.
Endpunkte: `/health`, `/preload`, `/process`, `/unload` (ab M2).
