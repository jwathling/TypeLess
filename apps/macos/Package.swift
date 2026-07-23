// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeLess",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Selbst-Update außerhalb des App Store. Nur an das App-Target gebunden — TypeLessCore
        // bleibt framework-frei und ohne Fenster testbar.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Bibliothek ohne jede UI — deshalb vollständig testbar, ohne ein Fenster zu öffnen.
        .target(name: "TypeLessCore"),
        // Die SwiftUI-Hülle. Bewusst dünn: zeigt nur an, was AppState sagt.
        .executableTarget(
            name: "TypeLess",
            dependencies: ["TypeLessCore", .product(name: "Sparkle", package: "Sparkle")],
            // Das eingebettete Framework liegt im .app unter Contents/Frameworks; der Loader muss
            // es relativ zum Executable finden (build-app.sh kopiert es dorthin).
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .testTarget(name: "TypeLessCoreTests", dependencies: ["TypeLessCore"]),
    ]
)
