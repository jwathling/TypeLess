// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeLess",
    platforms: [.macOS(.v14)],
    targets: [
        // Bibliothek ohne jede UI — deshalb vollständig testbar, ohne ein Fenster zu öffnen.
        .target(name: "TypeLessCore"),
        // Die SwiftUI-Hülle. Bewusst dünn: zeigt nur an, was AppState sagt.
        .executableTarget(name: "TypeLess", dependencies: ["TypeLessCore"]),
        .testTarget(name: "TypeLessCoreTests", dependencies: ["TypeLessCore"]),
    ]
)
