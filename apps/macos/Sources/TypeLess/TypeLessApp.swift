import SwiftUI
import TypeLessCore

@main
struct TypeLessApp: App {
    var body: some Scene {
        MenuBarExtra("TypeLess", systemImage: "mic") {
            Text("TypeLess \(coreVersion)")
            Divider()
            Button("TypeLess beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
