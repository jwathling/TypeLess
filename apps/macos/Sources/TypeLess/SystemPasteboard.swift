import AppKit
import TypeLessCore

/// Die echte Zwischenablage. Liegt bewusst in der App-Schicht, damit AppKit nicht in die
/// UI-freie Bibliothek ``TypeLessCore`` sickert.
///
/// Voll qualifiziert als `TypeLessCore.Pasteboard`: `AppKit` bringt transitiv
/// `ApplicationServices` mit, das selbst einen Typ namens `Pasteboard` definiert (die alte
/// Carbon-Pasteboard-API) — ein unqualifiziertes `Pasteboard` ist an dieser Stelle mehrdeutig.
struct SystemPasteboard: TypeLessCore.Pasteboard {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
